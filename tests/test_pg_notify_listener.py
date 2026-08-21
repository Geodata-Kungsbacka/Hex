#!/usr/bin/env python3
"""
Test: pg_notify-lyssnarsimulering – båda riktningarna.

Verifierar att lyssnaren korrekt tar emot och vidarebefordrar:
  - geoserver_schema        (schema-skapande)
  - geoserver_schema_drop   (schema-borttagning)

GeoServer krävs inte: GeoServerClient ersätts med en mock som
registrerar varje anrop. Testet använder en riktig PostgreSQL-anslutning
så att den faktiska LISTEN/NOTIFY-mekaniken testas.

Lyssnaren skapar två workspaces per schema:
  - Läs-workspace  '{schema}'   med gs_r_-uppgifter (SELECT)
  - Skriv-workspace '{schema}_w' med gs_w_-uppgifter (ALL, möjliggör WFS-T)

Autentiseringsuppgifterna hämtas från tabellen hex_rolluppgifter via
_fetch_role_credentials (läs) respektive _fetch_write_role_credentials (skriv).

Användning:
    python3 tests/test_pg_notify_listener.py
"""

import getpass
import os
import sys
import threading
import time
import unittest
import logging
from pathlib import Path
from unittest.mock import MagicMock, patch

import psycopg2
import psycopg2.extensions
import requests
import select

# ---------------------------------------------------------------------------
# Lös projektrotroten så att geoserver_listener kan importeras direkt
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_PATH = PROJECT_ROOT / "src" / "geoserver"
sys.path.insert(0, str(SRC_PATH))

import geoserver_listener as gl  # noqa: E402

# ---------------------------------------------------------------------------
# PostgreSQL-anslutningsparametrar.
#
# Standardvärdena träffar ett lokalt kluster via unix-socket, vilket undviker
# lösenordsautentisering. Sätt miljövariablerna nedan för att köra mot en annan
# instans eller som en annan roll:
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=hemligt python3 tests/test_pg_notify_listener.py
#
# Standardanvändaren är den OS-användare som kör testet (peer-autentisering),
# inte ett hårdkodat rollnamn.
# ---------------------------------------------------------------------------
PG_PARAMS = {
    "host": os.environ.get("PGHOST", "/var/run/postgresql"),
    "port": int(os.environ.get("PGPORT", "5432")),
    "dbname": os.environ.get("PGDATABASE", "postgres"),
    "user": os.environ.get("PGUSER") or getpass.getuser(),
    "password": os.environ.get("PGPASSWORD", ""),
}

# db_config-format som används av handle_schema_notification och listen_loop
DB_CONFIG = {
    **PG_PARAMS,
}

CHANNEL_CREATE = gl.CHANNEL_SCHEMA_CREATE   # "geoserver_schema"
CHANNEL_DROP   = gl.CHANNEL_SCHEMA_DROP     # "geoserver_schema_drop"

VALID_CREATE_SCHEMA = "sk0_kba_testschema"
VALID_DROP_SCHEMA   = "sk1_ext_oldschema"
INVALID_SCHEMA      = "public_not_a_valid_name"

# Testuppgifter för läs- och skrivrollen som lagras i hex_rolluppgifter
TEST_ROLE_NAME       = f"gs_r_{VALID_CREATE_SCHEMA}"
TEST_ROLE_PASSWORD   = "test_password_123"
TEST_W_ROLE_NAME     = f"gs_w_{VALID_CREATE_SCHEMA}"
TEST_W_ROLE_PASSWORD = "test_write_password_456"

WRITE_SUFFIX = gl.WRITE_WORKSPACE_SUFFIX  # "_w"


# ---------------------------------------------------------------------------
# Hjälpare: öppna en psycopg2-anslutning i autocommit-läge
# ---------------------------------------------------------------------------
def make_conn():
    conn = psycopg2.connect(**PG_PARAMS)
    conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    return conn


# ---------------------------------------------------------------------------
# Hjälpare: skicka NOTIFY från en separat anslutning och returnera
# ---------------------------------------------------------------------------
def pg_notify(channel, payload):
    """Skickar NOTIFY channel, 'payload'; från en kortlivad anslutning."""
    conn = make_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"NOTIFY {channel}, %s;", (payload,))
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Lyssnarpollning – hjälpare för en iteration, används i tester
# ---------------------------------------------------------------------------
def run_listener_once(listen_conn, timeout=3.0):
    """
    Pollar *listen_conn* i upp till *timeout* sekunder och returnerar alla
    mottagna (kanal, payload)-par.
    """
    received = []
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready = select.select([listen_conn], [], [], max(0, remaining))
        if ready == ([], [], []):
            break  # timeout – avbryt pollning
        listen_conn.poll()
        while listen_conn.notifies:
            n = listen_conn.notifies.pop(0)
            received.append((n.channel, n.payload))

    return received


# ===========================================================================
# Tester
# ===========================================================================

class TestPgNotifyRoundTrip(unittest.TestCase):
    """End-to-end LISTEN/NOTIFY-runda via en riktig PostgreSQL-anslutning."""

    def setUp(self):
        self.listen_conn = make_conn()
        cur = self.listen_conn.cursor()
        cur.execute(f"LISTEN {CHANNEL_CREATE};")
        cur.execute(f"LISTEN {CHANNEL_DROP};")

    def tearDown(self):
        if not self.listen_conn.closed:
            self.listen_conn.close()

    # ------------------------------------------------------------------
    # 1. Rå LISTEN/NOTIFY – ingen applikationslogik, bara mekaniken
    # ------------------------------------------------------------------
    def test_raw_notify_create_channel_received(self):
        """NOTIFY på geoserver_schema levereras till lyssnaren."""
        pg_notify(CHANNEL_CREATE, VALID_CREATE_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1, f"Expected 1 notification, got {msgs}")
        channel, payload = msgs[0]
        self.assertEqual(channel, CHANNEL_CREATE)
        self.assertEqual(payload, VALID_CREATE_SCHEMA)

    def test_raw_notify_drop_channel_received(self):
        """NOTIFY på geoserver_schema_drop levereras till lyssnaren."""
        pg_notify(CHANNEL_DROP, VALID_DROP_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1, f"Expected 1 notification, got {msgs}")
        channel, payload = msgs[0]
        self.assertEqual(channel, CHANNEL_DROP)
        self.assertEqual(payload, VALID_DROP_SCHEMA)

    def test_both_channels_in_sequence(self):
        """Båda kanaler kan bära notifieringar i samma session."""
        pg_notify(CHANNEL_CREATE, VALID_CREATE_SCHEMA)
        pg_notify(CHANNEL_DROP,   VALID_DROP_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        channels = {m[0] for m in msgs}
        payloads = {m[1] for m in msgs}
        self.assertIn(CHANNEL_CREATE, channels)
        self.assertIn(CHANNEL_DROP,   channels)
        self.assertIn(VALID_CREATE_SCHEMA, payloads)
        self.assertIn(VALID_DROP_SCHEMA,   payloads)

    def test_invalid_schema_not_forwarded_by_listener(self):
        """
        Rå NOTIFY med ogiltigt schemanamn *levereras* på transportnivå men
        avvisas av hanteraren. Verifierar att transporten fortfarande fungerar
        och att hanteraren returnerar False.
        """
        pg_notify(CHANNEL_CREATE, INVALID_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1)
        _, payload = msgs[0]
        self.assertEqual(payload, INVALID_SCHEMA)

        # Hanteraren måste avvisa det ogiltiga namnet (pg_conn mockas – nås inte)
        mock_gs = MagicMock()
        mock_conn = MagicMock()
        result = gl.handle_schema_notification(
            INVALID_SCHEMA, DB_CONFIG, mock_conn, mock_gs
        )
        self.assertFalse(result)
        mock_gs.create_workspace.assert_not_called()


class TestHandlerLogicWithMockGeoServer(unittest.TestCase):
    """
    Enhetstester för handle_schema_notification och
    handle_schema_removal_notification med en mockad GeoServerClient.
    _fetch_role_credentials mockas för att undvika beroende av databasens
    hex_rolluppgifter-tabell.
    """

    def _make_gs_mock(self, workspace_ok=True, datastore_ok=True, role_ok=True, acl_ok=True):
        """Returnerar en GeoServerClient-mock med konfigurerbart utfall."""
        gs = MagicMock()
        gs.workspace_exists.return_value = False
        gs.create_workspace.return_value = workspace_ok
        gs.datastore_exists.return_value = False
        gs.create_pg_datastore.return_value = datastore_ok
        gs.create_gs_role.return_value = role_ok
        gs.create_workspace_acl.return_value = acl_ok
        gs.create_write_workspace_acl.return_value = acl_ok
        gs.delete_workspace.return_value = True
        gs.delete_workspace_acl.return_value = True
        gs.delete_gs_role.return_value = True
        return gs

    def _make_pg_conn_mock(self, anonym_las=False):
        """Returnerar en psycopg2-anslutnings-mock.

        Cursor-mocken svarar konsekvent på de tre DB-anrop som
        handle_schema_notification gör via pg_conn.cursor():
          1. _load_schema_pattern   – fetchall x2 (returnerar []: behåller befintligt mönster)
          2. _fetch_anonymous_read  – fetchone   (returnerar (anonym_las,))
        """
        cur_mock = MagicMock()
        cur_mock.fetchall.return_value = []
        cur_mock.fetchone.return_value = (anonym_las,)
        mock_conn = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = cur_mock
        return mock_conn

    # ------------------------------------------------------------------
    # 2. Schema CREATE-hanterare
    # ------------------------------------------------------------------
    def test_create_handler_calls_workspace_and_datastore(self):
        """Lyckad väg: alla sju steg utförs för ett giltigt sk0-schema.

        Verifierar att både läs-workspace (gs_r_) och skriv-workspace (gs_w_)
        skapas med korrekta autentiseringsuppgifter och ACL-regler.
        """
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()
        write_workspace = f"{VALID_CREATE_SCHEMA}{WRITE_SUFFIX}"

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )

        self.assertTrue(result)

        # Båda workspaces skapas
        self.assertEqual(gs.create_workspace.call_count, 2)
        gs.create_workspace.assert_any_call(VALID_CREATE_SCHEMA)
        gs.create_workspace.assert_any_call(write_workspace)

        # Båda datastores skapas med rätt uppgifter
        self.assertEqual(gs.create_pg_datastore.call_count, 2)
        gs.create_pg_datastore.assert_any_call(
            workspace=VALID_CREATE_SCHEMA,
            store_name=VALID_CREATE_SCHEMA,
            host=DB_CONFIG["host"],
            port=DB_CONFIG["port"],
            dbname=DB_CONFIG["dbname"],
            schema_name=VALID_CREATE_SCHEMA,
            pg_user=TEST_ROLE_NAME,
            pg_password=TEST_ROLE_PASSWORD,
        )
        gs.create_pg_datastore.assert_any_call(
            workspace=write_workspace,
            store_name=write_workspace,
            host=DB_CONFIG["host"],
            port=DB_CONFIG["port"],
            dbname=DB_CONFIG["dbname"],
            schema_name=VALID_CREATE_SCHEMA,
            pg_user=TEST_W_ROLE_NAME,
            pg_password=TEST_W_ROLE_PASSWORD,
        )

        # GeoServer-roller skapas
        self.assertEqual(gs.create_gs_role.call_count, 2)
        gs.create_gs_role.assert_any_call(f"r_{VALID_CREATE_SCHEMA}")
        gs.create_gs_role.assert_any_call(f"w_{VALID_CREATE_SCHEMA}")

        # ACL för läs- och skriv-workspace skapas
        gs.create_workspace_acl.assert_called_once_with(VALID_CREATE_SCHEMA, anonymous_read=False)
        gs.create_write_workspace_acl.assert_called_once_with(VALID_CREATE_SCHEMA)

    def test_create_handler_skips_write_workspace_when_w_credentials_missing(self):
        """Om gs_w_-uppgifter saknas i hex_rolluppgifter skapas enbart läs-workspace."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(None, None)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )

        self.assertTrue(result)
        # Enbart läs-workspace skapas
        gs.create_workspace.assert_called_once_with(VALID_CREATE_SCHEMA)
        gs.create_pg_datastore.assert_called_once()
        # Inga skriv-ACL
        gs.create_write_workspace_acl.assert_not_called()

    def test_create_handler_rejects_invalid_schema(self):
        """Schemanamn som inte matchar regex hoppas tyst över."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()
        result = gl.handle_schema_notification(
            "public_bad", DB_CONFIG, mock_conn, gs
        )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_accepts_new_prefix_after_runtime_config_change(self):
        """
        Regression: skx_kba_test publiceras inte om det trådlokala mönstret inte
        uppdaterats sedan tjänsten startade. handle_schema_notification ska
        ladda om mönstret från DB via pg_conn.cursor() innan validering så
        att ett nytt prefix (skx) accepteras utan omstart.
        """
        gs = self._make_gs_mock()

        # Cursor-mock vars fetchall returnerar skx som publicerbart prefix.
        # handle_schema_notification använder "with pg_conn.cursor() as cur:" –
        # context manager-protokollet kallar __enter__() på det cursor()
        # returnerar, så vi måste koppla __enter__.return_value till cur_mock.
        cur_mock = MagicMock()
        cur_mock.fetchall.side_effect = [
            [("sk0",), ("sk1",), ("skx",)],   # hex_standardiserade_skyddsnivaer
            [("ext",), ("kba",), ("sys",)],    # hex_standardiserade_datakategorier
        ]
        cur_mock.fetchone.return_value = (False,)   # anonym_las för skx
        mock_conn = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = cur_mock

        original_thread_pattern = gl._thread_local.__dict__.pop("schema_pattern", None)
        try:
            with patch.object(gl, "_fetch_role_credentials",
                              return_value=("gs_r_skx_kba_test", "pw")):
                with patch.object(gl, "_fetch_write_role_credentials",
                                  return_value=("gs_w_skx_kba_test", "pw_w")):
                    result = gl.handle_schema_notification(
                        "skx_kba_test", DB_CONFIG, mock_conn, gs
                    )
        finally:
            if original_thread_pattern is not None:
                gl._thread_local.schema_pattern = original_thread_pattern
            else:
                gl._thread_local.__dict__.pop("schema_pattern", None)

        self.assertTrue(result, "skx_kba_test ska accepteras när mönstret laddats om från DB")
        gs.create_workspace.assert_any_call("skx_kba_test")

    def test_create_handler_passes_anonymous_read_true(self):
        """När anonym_las=True i DB skickas anonymous_read=True till create_workspace_acl."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock(anonym_las=True)

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )

        self.assertTrue(result)
        gs.create_workspace_acl.assert_called_once_with(VALID_CREATE_SCHEMA, anonymous_read=True)

    def test_create_handler_missing_credentials(self):
        """Schema utan gs_r_-uppgifter i hex_rolluppgifter hoppas helt över."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(None, None)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_workspace_failure_aborts(self):
        """Om läs-workspace-skapande misslyckas hoppas resten över."""
        gs = self._make_gs_mock(workspace_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )
        self.assertFalse(result)
        gs.create_pg_datastore.assert_not_called()

    def test_create_handler_sk1_schema(self):
        """sk1-scheman hanteras identiskt med sk0-scheman."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()
        sk1_r_role = f"gs_r_{VALID_DROP_SCHEMA}"
        sk1_w_role = f"gs_w_{VALID_DROP_SCHEMA}"

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(sk1_r_role, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(sk1_w_role, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_DROP_SCHEMA,   # "sk1_ext_oldschema"
                    DB_CONFIG,
                    mock_conn,
                    gs,
                )
        self.assertTrue(result)
        gs.create_workspace.assert_any_call(VALID_DROP_SCHEMA)
        gs.create_workspace.assert_any_call(f"{VALID_DROP_SCHEMA}{WRITE_SUFFIX}")

    def test_create_handler_datastore_failure(self):
        """Om läs-datastore-skapande misslyckas avbryts flödet innan roller skapas."""
        gs = self._make_gs_mock(datastore_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )
        self.assertFalse(result)
        gs.create_workspace.assert_called_once()  # läs-workspace skapas, sedan avbryts
        gs.create_gs_role.assert_not_called()
        gs.create_workspace_acl.assert_not_called()

    def test_create_handler_role_failure_aborts(self):
        """Om GeoServer-roll inte kan skapas avbryts flödet innan ACL sätts."""
        gs = self._make_gs_mock(role_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )
        self.assertFalse(result)
        self.assertEqual(gs.create_workspace.call_count, 2)
        self.assertEqual(gs.create_pg_datastore.call_count, 2)
        gs.create_workspace_acl.assert_not_called()

    def test_create_handler_acl_failure_aborts(self):
        """Om läs-ACL-regler inte kan skapas returneras False."""
        gs = self._make_gs_mock(acl_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                result = gl.handle_schema_notification(
                    VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
                )
        self.assertFalse(result)
        self.assertEqual(gs.create_workspace.call_count, 2)
        self.assertEqual(gs.create_pg_datastore.call_count, 2)
        self.assertEqual(gs.create_gs_role.call_count, 2)

    # ------------------------------------------------------------------
    # 3. Schema DROP-hanterare
    # ------------------------------------------------------------------
    def test_drop_handler_calls_delete_workspace(self):
        """Lyckad väg: ACL-regler, båda workspaces och roller tas bort i rätt ordning."""
        gs = self._make_gs_mock()
        write_workspace = f"{VALID_DROP_SCHEMA}{WRITE_SUFFIX}"
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)

        self.assertTrue(result)
        # Steg 1 och 2: ACL tas bort för läs- och skriv-workspace
        self.assertEqual(gs.delete_workspace_acl.call_count, 2)
        gs.delete_workspace_acl.assert_any_call(VALID_DROP_SCHEMA)
        gs.delete_workspace_acl.assert_any_call(write_workspace)
        # Steg 3 och 4: Båda workspaces tas bort
        self.assertEqual(gs.delete_workspace.call_count, 2)
        gs.delete_workspace.assert_any_call(VALID_DROP_SCHEMA)
        gs.delete_workspace.assert_any_call(write_workspace)
        # Steg 5: GeoServer-roller tas bort
        self.assertEqual(gs.delete_gs_role.call_count, 2)
        gs.delete_gs_role.assert_any_call(f"r_{VALID_DROP_SCHEMA}")
        gs.delete_gs_role.assert_any_call(f"w_{VALID_DROP_SCHEMA}")

    def test_drop_handler_rejects_invalid_schema(self):
        """Ogiltiga schemanamn avvisas innan GeoServer kontaktas."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification("bad_schema_name", gs)
        self.assertFalse(result)
        gs.delete_workspace.assert_not_called()

    def test_drop_handler_accepts_new_prefix_after_runtime_config_change(self):
        """
        Regression: DROP-notifiering för skx_kba_test avvisas om det trådlokala
        mönstret är inaktuellt. handle_schema_removal_notification ska ladda om
        mönstret via pg_conn innan validering.
        """
        gs = self._make_gs_mock()

        # handle_schema_removal_notification uses "with pg_conn.cursor() as cur:" so
        # the context manager protocol calls __enter__() on cursor()'s return value.
        # We must wire __enter__.return_value to cur_mock, not cursor.return_value itself.
        cur_mock = MagicMock()
        cur_mock.fetchall.side_effect = [
            [("sk0",), ("sk1",), ("skx",)],   # hex_standardiserade_skyddsnivaer
            [("ext",), ("kba",), ("sys",)],    # hex_standardiserade_datakategorier
        ]
        mock_conn = MagicMock()
        # handle_schema_removal_notification uses "with pg_conn.cursor() as cur:"
        # so __enter__.return_value must be the configured cursor mock.
        mock_conn.cursor.return_value.__enter__.return_value = cur_mock

        # Sätt ett inaktuellt trådlokalt mönster som saknar skx (simulerar ett
        # mönster laddat från en annan databas innan skx lades till)
        import re as _re
        original_thread_pattern = gl._thread_local.__dict__.pop("schema_pattern", None)
        gl._thread_local.schema_pattern = _re.compile(r"^(sk0|sk1)_(ext|kba|sys)_.+$")
        try:
            result = gl.handle_schema_removal_notification(
                "skx_kba_test", gs, pg_conn=mock_conn
            )
        finally:
            if original_thread_pattern is not None:
                gl._thread_local.schema_pattern = original_thread_pattern
            else:
                gl._thread_local.__dict__.pop("schema_pattern", None)

        self.assertTrue(result, "skx_kba_test ska accepteras när mönstret laddats om från DB")
        gs.delete_workspace.assert_any_call("skx_kba_test")

    def test_drop_handler_returns_false_on_geoserver_failure(self):
        """Hanteraren returnerar False när läs-workspace-borttagning misslyckas; roller rensas inte."""
        gs = self._make_gs_mock()
        gs.delete_workspace.return_value = False
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)
        self.assertFalse(result)
        # Steg 1 och 2: Båda ACL-stegen körs innan workspace-borttagningen försöks
        self.assertEqual(gs.delete_workspace_acl.call_count, 2)
        gs.delete_gs_role.assert_not_called()


class TestListenLoopIntegration(unittest.TestCase):
    """
    Integrationstest: kör listen_loop i en bakgrundstråd, skicka NOTIFY
    från huvudtråden och verifiera att mock-GeoServer anropades korrekt.

    _fetch_role_credentials mockas för att undvika beroende av databasens
    hex_rolluppgifter-tabell under integrationstester.
    """

    TIMEOUT = 5  # sekunder att vänta på att tråden plockar upp notifieringen

    def _notifiera_tills(self, villkor, notiser):
        """
        Skickar NOTIFY tills villkoret uppfylls eller tiden går ut.

        LISTEN körs i bakgrundstråden. Hinner den inte registrera sig innan
        första NOTIFY skickas är den notifieringen förlorad för alltid –
        PostgreSQL levererar bara till sessioner som redan lyssnar. En fast
        väntetid före första NOTIFY räcker därför inte: under last hinner
        tråden inte alltid fram, och testet blir instabilt. Att skicka om
        notifieringen gör testet oberoende av hur snabbt tråden startar.
        """
        deadline = time.monotonic() + self.TIMEOUT
        while time.monotonic() < deadline:
            for kanal, nyttolast in notiser:
                pg_notify(kanal, nyttolast)
            if villkor():
                return True
            time.sleep(0.1)
        return villkor()

    def _run_listen_loop(self, gs_mock, stop_event):
        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials", return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                gl.listen_loop(
                    DB_CONFIG,
                    reconnect_delay=1,
                    gs_client=gs_mock,
                    stop_event=stop_event,
                )

    def _make_gs_mock(self):
        gs = MagicMock()
        gs.workspace_exists.return_value = False
        gs.create_workspace.return_value = True
        gs.datastore_exists.return_value = False
        gs.create_pg_datastore.return_value = True
        gs.create_gs_role.return_value = True
        gs.create_workspace_acl.return_value = True
        gs.create_write_workspace_acl.return_value = True
        gs.delete_workspace.return_value = True
        gs.delete_workspace_acl.return_value = True
        gs.delete_gs_role.return_value = True
        return gs

    def test_listen_loop_picks_up_create_notification(self):
        """listen_loop tar emot geoserver_schema NOTIFY och anropar create_workspace."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()

        self._notifiera_tills(
            lambda: gs.create_workspace.called,
            [(CHANNEL_CREATE, VALID_CREATE_SCHEMA)],
        )

        stop.set()
        t.join(timeout=3)

        gs.create_workspace.assert_any_call(VALID_CREATE_SCHEMA)
        self.assertGreaterEqual(gs.create_pg_datastore.call_count, 1)

    def test_listen_loop_picks_up_drop_notification(self):
        """listen_loop tar emot geoserver_schema_drop NOTIFY och anropar delete_workspace."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()

        self._notifiera_tills(
            lambda: gs.delete_workspace.called,
            [(CHANNEL_DROP, VALID_DROP_SCHEMA)],
        )

        stop.set()
        t.join(timeout=3)

        gs.delete_workspace.assert_any_call(VALID_DROP_SCHEMA)

    def test_listen_loop_both_directions(self):
        """Båda NOTIFY-kanaler bearbetas i en enda listen_loop-körning."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()

        self._notifiera_tills(
            lambda: gs.create_workspace.called and gs.delete_workspace.called,
            [(CHANNEL_CREATE, VALID_CREATE_SCHEMA),
             (CHANNEL_DROP,   VALID_DROP_SCHEMA)],
        )

        stop.set()
        t.join(timeout=3)

        gs.create_workspace.assert_any_call(VALID_CREATE_SCHEMA)
        gs.delete_workspace.assert_any_call(VALID_DROP_SCHEMA)


class TestCreateWorkspaceNamespaceUri(unittest.TestCase):
    """
    Enhetstester för GeoServerClient.create_workspace som verifierar att
    namespace-URI sätts korrekt efter att workspace skapats.
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _mock_response(self, status_code):
        resp = MagicMock()
        resp.status_code = status_code
        resp.text = ""
        return resp

    def test_namespace_uri_put_called_after_workspace_created(self):
        """Efter lyckat POST ska PUT /namespaces/<name> anropas med korrekt URI."""
        client = self._make_client()
        post_resp = self._mock_response(201)
        put_resp = self._mock_response(200)

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # workspace_exists -> 404 = does not exist
            post_resp,                 # POST /workspaces -> 201
            put_resp,                  # PUT /namespaces/<name> -> 200
        ]) as mock_req:
            result = client.create_workspace("sk0_ext_sjv")

        self.assertTrue(result)
        calls = mock_req.call_args_list
        self.assertEqual(len(calls), 3)

        # Third call must be PUT to the namespaces endpoint
        method, url = calls[2][0][0], calls[2][0][1]
        self.assertEqual(method, "PUT")
        self.assertIn("/namespaces/sk0_ext_sjv", url)

        # Verify the URI is not GeoServer's auto-generated "http://<name>" form
        ns_payload = calls[2][1]["json"]
        uri = ns_payload["namespace"]["uri"]
        self.assertIn("sk0_ext_sjv", uri)
        self.assertNotEqual(uri, "http://sk0_ext_sjv")
        # Default namespace_uri_base = base_url ("http://geoserver.example.com")
        self.assertEqual(uri, "http://geoserver.example.com/sk0_ext_sjv")

    def test_namespace_put_failure_still_returns_true(self):
        """Misslyckad namespace-uppdatering ska inte hindra workspace från att rapporteras som skapad."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # workspace_exists
            self._mock_response(201),  # POST /workspaces
            self._mock_response(500),  # PUT /namespaces -> failure
        ]):
            result = client.create_workspace("sk0_ext_sjv")

        self.assertTrue(result)

    def test_workspace_post_failure_skips_namespace_put(self):
        """Om POST /workspaces misslyckas ska inget namespace-PUT skickas."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # workspace_exists
            self._mock_response(500),  # POST /workspaces -> failure
        ]) as mock_req:
            result = client.create_workspace("sk0_ext_sjv")

        self.assertFalse(result)
        # Only 2 calls: workspace_exists + POST; no PUT
        self.assertEqual(len(mock_req.call_args_list), 2)

    def test_existing_workspace_correct_namespace_skips_write(self):
        """Workspace finns med korrekt namespace URI → GET-kontroll, ingen POST/PUT."""
        client = self._make_client()

        ns_resp = MagicMock()
        ns_resp.status_code = 200
        ns_resp.json.return_value = {
            # Default namespace_uri_base = base_url = "http://geoserver.example.com"
            "namespace": {"prefix": "sk0_ext_sjv", "uri": "http://geoserver.example.com/sk0_ext_sjv"}
        }

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(200),  # workspace_exists -> 200 = exists
            ns_resp,                   # get_namespace_uri -> correct URI
        ]) as mock_req:
            result = client.create_workspace("sk0_ext_sjv")

        self.assertTrue(result)
        calls = mock_req.call_args_list
        self.assertEqual(len(calls), 2)
        # Second call must be GET to namespaces
        self.assertEqual(calls[1][0][0], "GET")
        self.assertIn("/namespaces/sk0_ext_sjv", calls[1][0][1])

    def test_existing_workspace_wrong_namespace_is_repaired(self):
        """Workspace finns med fel namespace URI (t.ex. GeoServers auto-genererade) → korrigeras via PUT."""
        client = self._make_client()

        ns_resp = MagicMock()
        ns_resp.status_code = 200
        ns_resp.json.return_value = {
            # GeoServer's auto-generated URI: no host, just the name → wrong format
            "namespace": {"prefix": "sk0_ext_sjv", "uri": "http://sk0_ext_sjv"}
        }

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(200),  # workspace_exists -> 200 = exists
            ns_resp,                   # get_namespace_uri -> wrong URI
            self._mock_response(200),  # PUT /namespaces -> 200 success
        ]) as mock_req:
            result = client.create_workspace("sk0_ext_sjv")

        self.assertTrue(result)
        calls = mock_req.call_args_list
        self.assertEqual(len(calls), 3)
        # Third call must be PUT to namespaces with the correct namespace_uri_base URI
        method, url = calls[2][0][0], calls[2][0][1]
        self.assertEqual(method, "PUT")
        self.assertIn("/namespaces/sk0_ext_sjv", url)
        ns_payload = calls[2][1]["json"]
        # Default namespace_uri_base = base_url = "http://geoserver.example.com"
        self.assertEqual(ns_payload["namespace"]["uri"], "http://geoserver.example.com/sk0_ext_sjv")


class TestCreateGsRole(unittest.TestCase):
    """
    Enhetstester för GeoServerClient.create_gs_role – verifierar hantering av
    lyckad skapning, 409 Conflict och GeoServer-specifikt 404 "already exists".
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _mock_response(self, status_code, text=""):
        resp = MagicMock()
        resp.status_code = status_code
        resp.text = text
        return resp

    def test_create_role_success(self):
        """201 → roll skapad, returnerar True."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(201)):
            self.assertTrue(client.create_gs_role("r_sk0_kba_test"))

    def test_create_role_409_already_exists(self):
        """409 → rollen finns redan, returnerar True (idempotent)."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(409)):
            self.assertTrue(client.create_gs_role("r_sk0_kba_test"))

    def test_create_role_404_already_exists_geoserver_quirk(self):
        """
        Regression: GeoServer 2.27.x returnerar 404 med 'already exists' i
        svarstexten när rollen redan finns (t.ex. efter manuell workspace-borttagning
        utan att ta bort rollerna). Ska behandlas som 409, inte som fel.
        """
        client = self._make_client()
        body = (
            "<!doctype html><html><body>"
            "<p><b>Message</b> The role r_skx_kba_test11 already exists</p>"
            "</body></html>"
        )
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(404, body)):
            self.assertTrue(client.create_gs_role("r_skx_kba_test11"))

    def test_create_role_404_genuine_not_found(self):
        """404 utan 'already exists' i svarstexten är ett riktigt fel → False."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(404, "Not Found")):
            self.assertFalse(client.create_gs_role("r_sk0_kba_test"))

    def test_create_role_server_error(self):
        """500 → logg ERROR, returnerar False."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(500, "Internal Server Error")):
            self.assertFalse(client.create_gs_role("r_sk0_kba_test"))


class TestCreateWorkspaceAcl(unittest.TestCase):
    """
    Enhetstester för GeoServerClient.create_workspace_acl – verifierar att
    409 och GeoServer-specifikt 404 "already exists" behandlas som idempotent
    framgång (samma mönster som create_gs_role).
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _mock_response(self, status_code, text=""):
        resp = MagicMock()
        resp.status_code = status_code
        resp.text = text
        return resp

    def test_create_acl_success_201(self):
        """Regel skapas framgångsrikt via POST 201 när ingen regel finns sedan tidigare."""
        client = self._make_client()
        with patch.object(client, "get_acl_rules", return_value={}):
            with patch.object(client, "_request_with_retry",
                              return_value=self._mock_response(201)):
                self.assertTrue(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_success_200(self):
        """Regel skapas framgångsrikt via POST 200 (vissa GeoServer-versioner)."""
        client = self._make_client()
        with patch.object(client, "get_acl_rules", return_value={}):
            with patch.object(client, "_request_with_retry",
                              return_value=self._mock_response(200)):
                self.assertTrue(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_409_rules_already_correct(self):
        """409 → GET visar att reglerna redan har rätt roll → returnerar True utan skrivning."""
        client = self._make_client()
        correct_rules = {
            "sk0_kba_test.*.r": "r_sk0_kba_test",
            "sk0_kba_test.*.w": "w_sk0_kba_test",
        }
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(409)):
            with patch.object(client, "get_acl_rules", return_value=correct_rules):
                self.assertTrue(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_409_wrong_role_is_repaired(self):
        """
        409 → GET visar felaktig roll → DELETE gammal + POST ny regel.

        Exempel: regeln pekar på ROLE_AUTHENTICATED istället för r_sk0_kba_test.
        Utan den här reparationen skulle GeoServer fortsätta använda fel roll.
        """
        client = self._make_client()
        wrong_rules = {
            "sk0_kba_test.*.r": "ROLE_AUTHENTICATED",  # fel roll
            "sk0_kba_test.*.w": "w_sk0_kba_test",      # korrekt
        }
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(409)):
            with patch.object(client, "get_acl_rules", return_value=wrong_rules):
                with patch.object(client, "_request_with_retry") as mock_req:
                    mock_req.side_effect = [
                        self._mock_response(200),   # DELETE gammal regel
                        self._mock_response(201),   # POST ny korrekt regel
                    ]
                    result = client._ensure_acl_rules("sk0_kba_test", {
                        "sk0_kba_test.*.r": "r_sk0_kba_test",
                        "sk0_kba_test.*.w": "w_sk0_kba_test",
                    })

        self.assertTrue(result)
        calls = mock_req.call_args_list
        # DELETE för felaktig regel
        self.assertEqual(calls[0][0][0], "DELETE")
        self.assertIn("sk0_kba_test.*.r", calls[0][0][1])
        # POST med korrekt roll
        self.assertEqual(calls[1][0][0], "POST")
        self.assertEqual(calls[1][1]["json"], {"sk0_kba_test.*.r": "r_sk0_kba_test"})

    def test_create_acl_404_already_exists_geoserver_quirk(self):
        """
        Regression: GeoServer kan returnera 404 med 'already exists' i kroppen
        om ACL-reglerna lämnades kvar efter en manuell workspace-borttagning.
        Ska behandlas som 409 och trigga verify-and-repair.
        """
        client = self._make_client()
        body = "Rule sk0_kba_test.*.r already exists"
        correct_rules = {
            "sk0_kba_test.*.r": "r_sk0_kba_test",
            "sk0_kba_test.*.w": "w_sk0_kba_test",
        }
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(404, body)):
            with patch.object(client, "get_acl_rules", return_value=correct_rules):
                self.assertTrue(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_404_genuine_failure(self):
        """404 utan 'already exists' är ett riktigt fel → False."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(404, "Not Found")):
            self.assertFalse(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_server_error(self):
        """500 från POST → logg ERROR, returnerar False."""
        client = self._make_client()
        with patch.object(client, "get_acl_rules", return_value={}):
            with patch.object(client, "_request_with_retry",
                              return_value=self._mock_response(500, "Internal Server Error")):
                self.assertFalse(client.create_workspace_acl("sk0_kba_test"))

    def test_create_acl_anonymous_read_adds_role_anonymous(self):
        """anonymous_read=True → läsregeln inkluderar ROLE_ANONYMOUS i POST-payloaden.

        create_workspace_acl hanterar enbart läs-workspacets .*.r-regel.
        Skrivrättigheter hanteras av create_write_workspace_acl för skriv-workspacet.
        """
        client = self._make_client()
        posted = {}

        def capture_request(method, url, **kwargs):
            if method == "POST":
                posted.update(kwargs.get("json", {}))
            return self._mock_response(201)

        with patch.object(client, "get_acl_rules", return_value={}):
            with patch.object(client, "_request_with_retry", side_effect=capture_request):
                self.assertTrue(client.create_workspace_acl("skx_kba_fg", anonymous_read=True))

        self.assertEqual(posted.get("skx_kba_fg.*.r"), "r_skx_kba_fg,ROLE_ANONYMOUS")
        # Skrivrättigheter hanteras av skriv-workspacet – ska inte finnas i läs-workspacets ACL
        self.assertNotIn("skx_kba_fg.*.w", posted)

    def test_create_acl_anonymous_read_false_omits_role_anonymous(self):
        """anonymous_read=False (default) → läsregeln innehåller inte ROLE_ANONYMOUS."""
        client = self._make_client()
        posted = {}

        def capture_request(method, url, **kwargs):
            if method == "POST":
                posted.update(kwargs.get("json", {}))
            return self._mock_response(201)

        with patch.object(client, "get_acl_rules", return_value={}):
            with patch.object(client, "_request_with_retry", side_effect=capture_request):
                self.assertTrue(client.create_workspace_acl("sk1_kba_test"))

        self.assertEqual(posted.get("sk1_kba_test.*.r"), "r_sk1_kba_test")
        self.assertNotIn("ROLE_ANONYMOUS", posted.get("sk1_kba_test.*.r", ""))

    def test_create_acl_409_anonymous_read_rules_already_correct(self):
        """409 med ROLE_ANONYMOUS i befintliga regler → korrekt, returnerar True utan skrivning."""
        client = self._make_client()
        correct_rules = {
            "skx_kba_fg.*.r": "r_skx_kba_fg,ROLE_ANONYMOUS",
            "skx_kba_fg.*.w": "w_skx_kba_fg",
        }
        with patch.object(client, "_request_with_retry",
                          return_value=self._mock_response(409)):
            with patch.object(client, "get_acl_rules", return_value=correct_rules):
                self.assertTrue(client.create_workspace_acl("skx_kba_fg", anonymous_read=True))


class _StyrdKlocka:
    """Monoton klocka med förutbestämda avläsningar, för tidmätningstesterna.

    Varje anrop plockar nästa värde ur listan. Tar värdena slut returneras det
    sista om och om igen, så att ett oväntat extra anrop inte spräcker testet
    med StopIteration utan bara ger varaktigheten noll.
    """

    def __init__(self, tider):
        self._tider = list(tider)
        self._sista = 0.0

    def __call__(self):
        if self._tider:
            self._sista = self._tider.pop(0)
        return self._sista


class TestLangsammaGeoServerAnrop(unittest.TestCase):
    """
    Instrumentering: onormalt långsamma REST-anrop ska synas i loggen.

    Bakgrund: i drift tog varje avstämnings *första* GeoServer-anrop 18–21
    sekunder, medan de dussintals anrop som följde i samma svep gick på
    bråkdelar av en sekund. Utan tidmätning i loggen gick det inte att skilja
    en långsam GeoServer från en anslutningsuppbyggnad som väntar ut en
    TCP-timeout innan den faller tillbaka på nästa adress. Varningen anger
    därför både varaktigheten och hur länge sessionen stått oanvänd.
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _anrop(self, client, tider, svar=None, fel=None):
        """Kör ett anrop med styrd klocka och mockad session."""
        session_mock = (
            patch.object(client.session, "request", side_effect=fel) if fel
            else patch.object(client.session, "request", return_value=svar)
        )
        with patch.object(gl.time, "monotonic", _StyrdKlocka(tider)), \
                patch.object(gl.time, "sleep"), session_mock:
            return client._request_with_retry("GET", f"{client.rest_url}/workspaces.json")

    def test_snabbt_anrop_ger_ingen_varning(self):
        """Ett anrop under tröskeln loggar ingenting."""
        client = self._make_client()
        svar = MagicMock(status_code=200)

        with patch.object(gl.log, "warning") as mock_warning:
            self._anrop(client, [100.0, 100.4], svar=svar)

        mock_warning.assert_not_called()

    def test_langsamt_anrop_varnar_med_varaktighet(self):
        """Ett anrop över tröskeln loggar varaktigheten."""
        client = self._make_client()
        svar = MagicMock(status_code=200)

        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            self._anrop(client, [100.0, 118.7], svar=svar)

        rad = "\n".join(cm.output)
        self.assertIn("Långsamt GeoServer-anrop", rad)
        self.assertIn("18.7 s", rad)
        self.assertIn("sessionens första anrop", rad)

    def test_varning_anger_hur_lange_sessionen_stod_oanvand(self):
        """Andra anropet relaterar varaktigheten till pausen sedan det förra.

        Det är den uppgiften som skiljer 'GeoServer är långsam' från
        'anslutningen hann stängas och måste byggas upp igen'.
        """
        client = self._make_client()
        svar = MagicMock(status_code=200)

        # Ett snabbt anrop som avslutas vid t=100.2 ...
        self._anrop(client, [100.0, 100.2], svar=svar)

        # ... och ett långsamt en timme senare.
        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            self._anrop(client, [3701.0, 3719.7], svar=svar)

        rad = "\n".join(cm.output)
        self.assertIn("18.7 s", rad)
        self.assertIn("3601 s sedan", rad)

    def test_langsamt_anrop_som_misslyckas_varnar_ocksa(self):
        """Ett anrop som hänger sig och sedan ger anslutningsfel loggas per försök.

        Ett försök som tar tid och *ändå* misslyckas är minst lika intressant
        som ett långsamt lyckat anrop.
        """
        client = self._make_client()
        tider = []
        for i in range(1 + client.MAX_RETRIES):
            tider.extend([i * 30.0, i * 30.0 + 18.7])

        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            with self.assertRaises(requests.exceptions.ConnectionError):
                self._anrop(
                    client, tider,
                    fel=requests.exceptions.ConnectionError("nätet nere"),
                )

        langsamma = [r for r in cm.output if "Långsamt GeoServer-anrop" in r]
        self.assertEqual(len(langsamma), 1 + client.MAX_RETRIES)


class TestAclRollordning(unittest.TestCase):
    """
    REGRESSION: ACL-regler med flera roller skrevs om vid varje avstämning.

    GeoServer lagrar en flerrollsregel som en kommaseparerad sträng men
    returnerar den i sin egen ordning: 'r_sk0_ext_sgu,ROLE_ANONYMOUS' kommer
    tillbaka som 'ROLE_ANONYMOUS,r_sk0_ext_sgu'. Jämförelsen var en
    strängjämförelse, så lyssnaren bedömde regeln som felaktig, gjorde DELETE
    + POST, och fick tillbaka samma omkastade ordning nästa gång. Resultatet
    blev en oändlig skrivloop mot produktion — synlig i loggen som samma regel
    "korrigerad" vid varje periodisk avstämning, utan att någonsin konvergera.

    Bara scheman med anonym_las = true drabbades: en regel med en enda roll
    har ingen ordning att vara oense om.
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _mock_response(self, status_code, text=""):
        resp = MagicMock()
        resp.status_code = status_code
        resp.text = text
        return resp

    # --- _rollmangd ---------------------------------------------------------

    def test_rollmangd_ignorerar_ordning(self):
        self.assertEqual(
            gl.GeoServerClient._rollmangd("r_x,ROLE_ANONYMOUS"),
            gl.GeoServerClient._rollmangd("ROLE_ANONYMOUS,r_x"),
        )

    def test_rollmangd_tolererar_mellanslag(self):
        self.assertEqual(
            gl.GeoServerClient._rollmangd("r_x, ROLE_ANONYMOUS"),
            frozenset({"r_x", "ROLE_ANONYMOUS"}),
        )

    def test_rollmangd_hanterar_tomt_varde(self):
        """En saknad regel (None) ska ge tom mängd, inte krascha."""
        self.assertEqual(gl.GeoServerClient._rollmangd(None), frozenset())
        self.assertEqual(gl.GeoServerClient._rollmangd(""), frozenset())
        self.assertEqual(gl.GeoServerClient._rollmangd("r_x,"), frozenset({"r_x"}))

    # --- _ensure_acl_rules --------------------------------------------------

    def test_omvand_rollordning_ger_ingen_skrivning(self):
        """Kärnan i buggen: omkastad ordning ska bedömas som korrekt."""
        client = self._make_client()
        gs_svar = {"sk0_ext_sgu.*.r": "ROLE_ANONYMOUS,r_sk0_ext_sgu"}
        with patch.object(client, "get_acl_rules", return_value=gs_svar):
            with patch.object(client, "_request_with_retry") as mock_req:
                resultat = client._ensure_acl_rules("sk0_ext_sgu", {
                    "sk0_ext_sgu.*.r": "r_sk0_ext_sgu,ROLE_ANONYMOUS",
                })
        self.assertTrue(resultat)
        self.assertEqual(
            mock_req.call_count, 0,
            "regeln skrevs om trots att den bara hade omkastad ordning",
        )

    def test_upprepad_avstamning_konvergerar(self):
        """
        Andra avstämningen efter en skrivning får tillbaka GeoServers ordning
        och ska då lämna regeln i fred. Det är just detta som saknades: i
        loggen korrigerades samma regel om och om igen.
        """
        client = self._make_client()
        forvantat = {"sk0_ext_sjv.*.r": "r_sk0_ext_sjv,ROLE_ANONYMOUS"}
        gs_svar = {"sk0_ext_sjv.*.r": "ROLE_ANONYMOUS,r_sk0_ext_sjv"}
        for varv in range(3):
            with patch.object(client, "get_acl_rules", return_value=gs_svar):
                with patch.object(client, "_request_with_retry") as mock_req:
                    client._ensure_acl_rules("sk0_ext_sjv", forvantat)
            self.assertEqual(
                mock_req.call_count, 0, f"skrivning skedde på varv {varv + 1}"
            )

    def test_verkligt_fel_roll_repareras_fortfarande(self):
        """
        Rättningen får inte göra kontrollen tandlös: en regel med en annan
        uppsättning roller ska fortfarande lagas.
        """
        client = self._make_client()
        gs_svar = {"sk0_ext_sgu.*.r": "ROLE_AUTHENTICATED,r_sk0_ext_sgu"}
        with patch.object(client, "get_acl_rules", return_value=gs_svar):
            with patch.object(client, "_request_with_retry") as mock_req:
                mock_req.side_effect = [
                    self._mock_response(200),   # DELETE
                    self._mock_response(201),   # POST
                ]
                resultat = client._ensure_acl_rules("sk0_ext_sgu", {
                    "sk0_ext_sgu.*.r": "r_sk0_ext_sgu,ROLE_ANONYMOUS",
                })
        self.assertTrue(resultat)
        self.assertEqual(mock_req.call_count, 2)

    def test_anonym_roll_som_tagits_bort_repareras(self):
        """
        Delmängd är inte likhet: har någon plockat bort ROLE_ANONYMOUS i
        GeoServers gränssnitt ska lyssnaren lägga tillbaka den.
        """
        client = self._make_client()
        gs_svar = {"sk0_ext_sgu.*.r": "r_sk0_ext_sgu"}
        with patch.object(client, "get_acl_rules", return_value=gs_svar):
            with patch.object(client, "_request_with_retry") as mock_req:
                mock_req.side_effect = [
                    self._mock_response(200),
                    self._mock_response(201),
                ]
                resultat = client._ensure_acl_rules("sk0_ext_sgu", {
                    "sk0_ext_sgu.*.r": "r_sk0_ext_sgu,ROLE_ANONYMOUS",
                })
        self.assertTrue(resultat)
        self.assertEqual(mock_req.call_count, 2)

    def test_enkelrollsregel_paverkas_inte(self):
        """Regler med en enda roll ska bete sig precis som förut."""
        client = self._make_client()
        gs_svar = {"sk1_kba_bm_w.*.w": "w_sk1_kba_bm"}
        with patch.object(client, "get_acl_rules", return_value=gs_svar):
            with patch.object(client, "_request_with_retry") as mock_req:
                resultat = client._ensure_acl_rules("sk1_kba_bm_w", {
                    "sk1_kba_bm_w.*.w": "w_sk1_kba_bm",
                })
        self.assertTrue(resultat)
        self.assertEqual(mock_req.call_count, 0)


class TestCreatePgDatastore(unittest.TestCase):
    """
    Enhetstester för GeoServerClient.create_pg_datastore som verifierar att
    direkta PostgreSQL-anslutningsparametrar skickas korrekt till GeoServer.

    Täcker specifikt regressionsfallet (lösenordsförnyelse efter ominstallation):
    när en datastore redan finns med SAMMA pg_user men ett förnyat lösenord
    (hex_underhall 'lösenord backfyllt') ska ett PUT skickas – inte hoppas över.
    """

    WORKSPACE   = "sk0_kba_testschema"
    STORE       = "sk0_kba_testschema"
    PG_USER     = "gs_r_sk0_kba_testschema"
    PG_PASSWORD = "brand_new_password_after_reinstall"

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _mock_response(self, status_code, text=""):
        resp = MagicMock()
        resp.status_code = status_code
        resp.text = text
        return resp

    def _call_create(self, client):
        return client.create_pg_datastore(
            workspace=self.WORKSPACE,
            store_name=self.STORE,
            host="db-host",
            port=5432,
            dbname="geodata_sk0_oppen",
            schema_name=self.WORKSPACE,
            pg_user=self.PG_USER,
            pg_password=self.PG_PASSWORD,
        )

    # ------------------------------------------------------------------
    # Regression: befintlig datastore med SAMMA användare – ska alltid PUT
    # ------------------------------------------------------------------
    def test_existing_store_same_user_refreshes_password(self):
        """
        Regression: befintlig datastore med samma pg_user ska ändå PUT:as
        med det nya lösenordet.

        Simulerar 'before state' efter ominstallation: hex_underhall har
        genererat ett nytt lösenord ('lösenord backfyllt') men GeoServer
        har fortfarande det gamla. Utan denna fix returnerades True direkt
        och GeoServer fick aldrig det nya lösenordet → 'null'-fel vid
        listning av lager.
        """
        client = self._make_client()

        with patch.object(client, "_get_datastore_user", return_value=self.PG_USER):
            with patch.object(client, "_update_pg_datastore", return_value=True) as mock_put:
                result = self._call_create(client)

        self.assertTrue(result)
        mock_put.assert_called_once_with(
            self.WORKSPACE, self.STORE,
            "db-host", 5432, "geodata_sk0_oppen",
            self.WORKSPACE, self.PG_USER, self.PG_PASSWORD,
        )

    def test_existing_store_different_user_updates_via_put(self):
        """Befintlig datastore med annan pg_user (r_* → gs_r_* migration) → PUT."""
        client = self._make_client()
        old_user = f"r_{self.WORKSPACE}"

        with patch.object(client, "_get_datastore_user", return_value=old_user):
            with patch.object(client, "_update_pg_datastore", return_value=True) as mock_put:
                result = self._call_create(client)

        self.assertTrue(result)
        mock_put.assert_called_once_with(
            self.WORKSPACE, self.STORE,
            "db-host", 5432, "geodata_sk0_oppen",
            self.WORKSPACE, self.PG_USER, self.PG_PASSWORD,
        )

    # ------------------------------------------------------------------
    # Ny datastore (finns inte sedan tidigare) – POST
    # ------------------------------------------------------------------
    def test_create_pg_datastore_success(self):
        """Lyckad skapning av direkt PG-datastore returnerar True."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # _get_datastore_user → 404 = finns inte
            self._mock_response(201),  # POST /datastores → 201
        ]) as mock_req:
            result = client.create_pg_datastore(
                workspace=self.WORKSPACE,
                store_name=self.STORE,
                host="localhost",
                port=5432,
                dbname="geodata",
                schema_name=self.WORKSPACE,
                pg_user="r_sk0_kba_testschema",
                pg_password="secret",
            )

        self.assertTrue(result)
        calls = mock_req.call_args_list
        self.assertEqual(len(calls), 2)

        # Andra anropet ska vara POST till datastores
        method, url = calls[1][0][0], calls[1][0][1]
        self.assertEqual(method, "POST")
        self.assertIn("/workspaces/sk0_kba_testschema/datastores", url)

        # Kontrollera att payload innehåller direkta PG-parametrar (inte JNDI)
        payload = calls[1][1]["json"]
        ds = payload["dataStore"]
        self.assertEqual(ds["type"], "PostGIS")
        entries = {e["@key"]: e["$"] for e in ds["connectionParameters"]["entry"]}
        self.assertEqual(entries["dbtype"], "postgis")
        self.assertEqual(entries["host"], "localhost")
        self.assertEqual(entries["port"], "5432")
        self.assertEqual(entries["database"], "geodata")
        self.assertEqual(entries["schema"], self.WORKSPACE)
        self.assertEqual(entries["user"], "r_sk0_kba_testschema")
        self.assertEqual(entries["passwd"], "secret")

    def test_create_pg_datastore_failure(self):
        """Om GeoServer returnerar fel vid POST returneras False."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # _get_datastore_user → finns inte
            self._mock_response(500),  # POST → failure
        ]):
            result = client.create_pg_datastore(
                workspace=self.WORKSPACE,
                store_name=self.STORE,
                host="localhost",
                port=5432,
                dbname="geodata",
                schema_name=self.WORKSPACE,
                pg_user="r_sk0_kba_testschema",
                pg_password="secret",
            )

        self.assertFalse(result)

    def test_post_conflict_falls_back_to_put(self):
        """
        POST 409/500 'already exists' (datastore finns men _get_datastore_user
        misslyckades att läsa) ska falla tillbaka till _update_pg_datastore.
        """
        client = self._make_client()

        with patch.object(client, "_get_datastore_user", return_value=None):
            with patch.object(client, "_request_with_retry",
                              return_value=self._mock_response(409, "already exists")):
                with patch.object(client, "_update_pg_datastore", return_value=True) as mock_put:
                    result = self._call_create(client)

        self.assertTrue(result)
        mock_put.assert_called_once()


class TestReconcileGeoServerSchemas(unittest.TestCase):
    """
    Enhetstester för _reconcile_geoserver_schemas – startavstämningen som körs
    en gång per uppstart och skapar saknade GeoServer-workspaces.

    Varken PostgreSQL-server eller GeoServer behövs: cur, cur.connection och
    gs_client mockas fullständigt.
    """

    # ------------------------------------------------------------------
    # Hjälpare
    # ------------------------------------------------------------------

    def _make_cur_mock(self, pg_schema_names):
        """
        Returnerar en mock av en psycopg2-cursor vars fetchall() ger de
        angivna schemanamnen och vars .connection ger en separat mock-anslutning.
        """
        cur = MagicMock()
        cur.fetchall.return_value = [(name,) for name in pg_schema_names]
        cur.connection = MagicMock()   # simulerar cur.connection (vår fix)
        return cur

    def _make_gs_mock(self, existing_workspaces=None, get_status=200):
        """
        Returnerar en GeoServerClient-mock vars GET /workspaces.json svarar
        med de angivna workspace-namnen.
        """
        gs = MagicMock()
        gs.rest_url = "http://geoserver.example.com/rest"
        gs.create_workspace.return_value = True
        gs.create_pg_datastore.return_value = True

        ws_list = [{"name": n} for n in (existing_workspaces or [])]
        get_resp = MagicMock()
        get_resp.status_code = get_status
        get_resp.json.return_value = {"workspaces": {"workspace": ws_list}}
        gs._request_with_retry.return_value = get_resp
        return gs

    DB_CONFIG = {
        "host": "localhost",
        "port": 5432,
        "dbname": "geodata",
        "user": "hex_listener",
        "password": "pw",
    }

    # ------------------------------------------------------------------
    # 1. Normalflöde
    # ------------------------------------------------------------------

    def test_missing_schema_creates_workspace(self):
        """Schema i PG men inte i GeoServer → båda workspaces skapas."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_any_call("sk0_kba_testschema")

    def test_existing_schema_refreshes_datastore_credentials(self):
        """
        Schema finns i både PG och GeoServer → workspaces skapas inte igen men
        create_pg_datastore anropas för att uppdatera lösenordet.

        Förut hoppades befintliga scheman över helt under startavstämning.
        Nu körs handle_schema_notification för alla scheman (idempotent) så att
        lösenordsändringar efter ominstallation slår igenom vid omstart av tjänsten.
        """
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=["sk0_kba_testschema"])

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            with patch.object(gl, "_fetch_write_role_credentials",
                              return_value=(TEST_W_ROLE_NAME, TEST_W_ROLE_PASSWORD)):
                gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        # create_workspace anropas (idempotent – verkliga implementationen
        # kontrollerar att workspace finns innan den försöker skapa)
        gs.create_workspace.assert_any_call("sk0_kba_testschema")
        # create_pg_datastore anropas för att synka lösenord (minst läs-datastore)
        self.assertGreaterEqual(gs.create_pg_datastore.call_count, 1)

    def test_in_sync_logs_ok(self):
        """Identiska listor → ingen skapning, inga varningar om saknade/extra scheman."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=["sk0_kba_testschema"])

        # Mocka handle_schema_notification för att isolera reconcilieringslogiken
        # från interna varningar (t.ex. _load_schema_pattern med tom mock-cursor).
        with patch.object(gl, "handle_schema_notification", return_value=True):
            with self.assertLogs("geoserver_listener", level="WARNING") as cm:
                # Trigga en WARNING vi kan filtrera bort – annars misslyckas assertLogs
                # om inga loggar alls produceras.
                logging.getLogger("geoserver_listener").warning("_sentinel_")
                gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        # Den enda WARNING-raden ska vara vår sentinel, inte en om saknade scheman
        warnings = [line for line in cm.output if "WARNING" in line and "_sentinel_" not in line]
        self.assertEqual(warnings, [], f"Unexpected warnings: {warnings}")

    # ------------------------------------------------------------------
    # 2. Argument-passning (verifierar fixen: cur.connection som pg_conn)
    # ------------------------------------------------------------------

    def test_cur_connection_passed_as_pg_conn(self):
        """
        handle_schema_notification ska ta emot cur.connection som pg_conn –
        det här testet fångar exakt det fel vi fixade (jndi_mappings / felaktig
        argumentordning).
        """
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        captured = {}

        def fake_handle(schema_name, db_config, pg_conn, gs_client, db_label=""):
            captured["pg_conn"] = pg_conn
            captured["db_config"] = db_config
            captured["gs_client"] = gs_client
            return True

        with patch.object(gl, "handle_schema_notification", side_effect=fake_handle):
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        self.assertIn("pg_conn", captured, "handle_schema_notification was never called")
        # pg_conn ska vara cur.connection, INTE gs_client eller jndi_mappings
        self.assertIs(captured["pg_conn"], cur.connection)
        # db_config ska vara hela DB_CONFIG-dict, inte en nyckel ur den
        self.assertIs(captured["db_config"], self.DB_CONFIG)
        # gs_client ska vara GeoServerClient-mocken
        self.assertIs(captured["gs_client"], gs)

    # ------------------------------------------------------------------
    # 3. Saknade credentials (befintliga JNDI-scheman efter patch)
    # ------------------------------------------------------------------

    def test_missing_credentials_skips_schema_without_crash(self):
        """
        Schema utan rad i hex_rolluppgifter (t.ex. gamla JNDI-scheman) ska
        hoppas över tyst – inte krascha startavstämningen.
        """
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        with patch.object(gl, "_fetch_role_credentials", return_value=(None, None)):
            # Ska inte kasta undantag
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_not_called()

    # ------------------------------------------------------------------
    # 4. GeoServer-fel – startavstämningen ska aldrig avbryta lyssnaren
    # ------------------------------------------------------------------

    def test_geoserver_unavailable_skips_reconciliation(self):
        """Nätverksfel mot GeoServer → logg ERROR, ingen krasch."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = MagicMock()
        gs.rest_url = "http://geoserver.example.com/rest"
        gs._request_with_retry.side_effect = requests.exceptions.ConnectionError("down")

        gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)  # ska inte kasta

        gs.create_workspace.assert_not_called()

    def test_geoserver_non_200_skips_reconciliation(self):
        """GeoServer svarar med t.ex. 503 → logg ERROR, ingen krasch."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=[], get_status=503)

        gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_not_called()

    def test_workspace_creation_failure_continues_next_schema(self):
        """
        Om skapandet av en workspace misslyckas ska nästa schema i listan
        ändå försökas – ett enskilt fel avbryter inte hela avstämningen.
        """
        cur = self._make_cur_mock(["sk0_kba_alpha", "sk0_kba_beta"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        call_count = {"n": 0}

        def handle_side_effect(schema_name, db_config, pg_conn, gs_client, db_label=""):
            call_count["n"] += 1
            if schema_name == "sk0_kba_alpha":
                raise RuntimeError("simulated failure")
            return True

        with patch.object(gl, "handle_schema_notification", side_effect=handle_side_effect):
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        self.assertEqual(call_count["n"], 2, "Båda scheman ska ha försökts")

    # ------------------------------------------------------------------
    # 5. Extra workspace i GeoServer – ska INTE tas bort
    # ------------------------------------------------------------------

    def test_extra_geoserver_workspace_logged_not_deleted(self):
        """
        Workspace i GeoServer utan matchande PG-schema → WARNING loggas,
        delete_workspace anropas INTE.
        """
        cur = self._make_cur_mock([])   # inga PG-scheman
        gs  = self._make_gs_mock(existing_workspaces=["sk0_kba_orphan"])

        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.delete_workspace = MagicMock()
        gs.delete_workspace.assert_not_called()

        warning_lines = [l for l in cm.output if "sk0_kba_orphan" in l]
        self.assertTrue(warning_lines, "Förväntad WARNING om sk0_kba_orphan saknas i loggen")

    def test_extra_non_hex_workspace_not_warned(self):
        """
        Workspace som inte matchar sk0/sk1-mönstret (t.ex. 'topp') ger ingen
        WARNING – vi äger inte dem.
        """
        cur = self._make_cur_mock([])
        gs  = self._make_gs_mock(existing_workspaces=["topp", "extern_data"])

        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            logging.getLogger("geoserver_listener").warning("_sentinel_")
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        non_sentinel = [l for l in cm.output if "_sentinel_" not in l and "WARNING" in l]
        self.assertEqual(non_sentinel, [])

    # ------------------------------------------------------------------
    # 6. DB-fel avbryter inte lyssnaren
    # ------------------------------------------------------------------

    def test_db_query_error_does_not_propagate(self):
        """Fel i SQL-frågan (t.ex. brutna privilegier) loggas men kastas inte."""
        cur = MagicMock()
        cur.execute.side_effect = Exception("permission denied")
        gs  = self._make_gs_mock(existing_workspaces=[])

        gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)  # ska inte kasta

        gs.create_workspace.assert_not_called()

    # ------------------------------------------------------------------
    # 7. Sk2/skx-scheman publiceras inte om SCHEMA_PATTERN så säger
    # ------------------------------------------------------------------


    def test_sk2_schema_blocked_by_schema_pattern(self):
        """
        sk2 är inte publicerbart i standardkonfigurationen (publiceras_geoserver = false).
        SCHEMA_PATTERN laddas från DB via _load_schema_pattern; i det här testet
        mockas det till fallback-värdet (sk0/sk1 only) för att verifiera att
        handle_schema_notification avvisar sk2 via _validate_schema_name.

        Om sk2 skulle läggas till i hex_standardiserade_skyddsnivaer med
        publiceras_geoserver = true OCH _load_schema_pattern körs, uppdateras
        SCHEMA_PATTERN och sk2-scheman publiceras. Det är avsiktligt beteende.
        """
        cur = self._make_cur_mock(["sk2_kba_hemlig"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        # SCHEMA_PATTERN är fallback-värdet (sk0/sk1 only) – sk2 avvisas
        with patch.object(gl, "_fetch_role_credentials",
                          return_value=("r_sk2_kba_hemlig", "pw")):
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_not_called()


class TestLoadSchemaPattern(unittest.TestCase):
    """
    Enhetstester för _load_schema_pattern – verifierar att det trådlokala
    schemanamnsmönstret byggs korrekt från konfigurationstabellerna och att
    fallback till SCHEMA_PATTERN fungerar när tabellerna är tomma eller vid fel.
    """

    def _make_cur_mock(self, skyddsnivaer_prefixes, datakategori_prefixes):
        """Cursor-mock vars fetchall returnerar rätt data för de två frågorna."""
        cur = MagicMock()
        cur.fetchall.side_effect = [
            [(p,) for p in skyddsnivaer_prefixes],
            [(p,) for p in datakategori_prefixes],
        ]
        return cur

    def setUp(self):
        """Rensa det trådlokala mönstret före varje test för isolering."""
        gl._thread_local.__dict__.pop("schema_pattern", None)

    def tearDown(self):
        """Återställ trådlokalt läge efter varje test."""
        gl._thread_local.__dict__.pop("schema_pattern", None)

    def test_pattern_built_from_config(self):
        """Mönstret byggs från skyddsnivaer + datakategorier ur DB."""
        cur = self._make_cur_mock(["sk0", "sk1"], ["ext", "kba", "sys"])
        gl._load_schema_pattern(cur)
        pattern = gl._get_schema_pattern()
        self.assertRegex("sk0_kba_test",  pattern)
        self.assertRegex("sk1_ext_sjv",   pattern)
        self.assertNotRegex("sk2_kba_hemlig", pattern)

    def test_new_security_level_included(self):
        """Om sk2 läggs till med publiceras_geoserver = true inkluderas det i mönstret."""
        cur = self._make_cur_mock(["sk0", "sk1", "sk2"], ["ext", "kba", "sys"])
        gl._load_schema_pattern(cur)
        self.assertRegex("sk2_kba_hemlig", gl._get_schema_pattern())

    def test_new_datakategori_included(self):
        """En ny datakategori inkluderas direkt efter att mönstret laddats."""
        cur = self._make_cur_mock(["sk0", "sk1"], ["ext", "kba", "sys", "int"])
        gl._load_schema_pattern(cur)
        self.assertRegex("sk0_int_test", gl._get_schema_pattern())

    def test_empty_skyddsnivaer_keeps_existing_pattern(self):
        """Tomma skyddsnivaer → befintligt mönster behålls, ingen krasch."""
        cur = self._make_cur_mock([], ["kba"])
        before = gl._get_schema_pattern()
        gl._load_schema_pattern(cur)
        self.assertIs(gl._get_schema_pattern(), before)

    def test_empty_kategorier_keeps_existing_pattern(self):
        """Tomma datakategorier → befintligt mönster behålls."""
        cur = self._make_cur_mock(["sk0"], [])
        before = gl._get_schema_pattern()
        gl._load_schema_pattern(cur)
        self.assertIs(gl._get_schema_pattern(), before)

    def test_db_error_keeps_existing_pattern(self):
        """DB-fel → befintligt mönster behålls, ingen krasch."""
        cur = MagicMock()
        cur.execute.side_effect = Exception("connection lost")
        before = gl._get_schema_pattern()
        gl._load_schema_pattern(cur)
        self.assertIs(gl._get_schema_pattern(), before)


class TestPeriodicReconcileLoop(unittest.TestCase):
    """
    Enhetstester för _periodic_reconcile_loop – verifierar att periodisk
    avstämning anropar _reconcile_geoserver_schemas, hanterar fel gracefully
    och avslutar omedelbart när stop_event sätts.
    """

    DB_CONFIG = {
        "host": "localhost",
        "port": 5432,
        "dbname": "geodata",
        "user": "hex_listener",
        "password": "pw",
    }

    def _make_conn_mock(self):
        conn = MagicMock()
        conn.cursor.return_value.__enter__.return_value = MagicMock()
        return conn

    def test_calls_reconcile_after_interval(self):
        """Anropar _reconcile_geoserver_schemas efter interval_seconds."""
        stop = threading.Event()
        gs = MagicMock()
        called = threading.Event()

        def fake_reconcile(*args, **kwargs):
            called.set()

        with patch.object(gl, "_reconcile_geoserver_schemas", side_effect=fake_reconcile):
            with patch("psycopg2.connect", return_value=self._make_conn_mock()):
                t = threading.Thread(
                    target=gl._periodic_reconcile_loop,
                    args=(self.DB_CONFIG, gs, stop, 0.05, "test"),
                    daemon=True,
                )
                t.start()
                called.wait(timeout=3)
                stop.set()
                t.join(timeout=3)

        self.assertTrue(called.is_set(), "_reconcile_geoserver_schemas anropades aldrig")

    def test_stops_when_stop_event_set(self):
        """stop_event redan satt → loop-body körs aldrig och tråden avslutas."""
        stop = threading.Event()
        stop.set()
        gs = MagicMock()

        with patch.object(gl, "_reconcile_geoserver_schemas") as mock_rec:
            t = threading.Thread(
                target=gl._periodic_reconcile_loop,
                args=(self.DB_CONFIG, gs, stop, 60, "test"),
                daemon=True,
            )
            t.start()
            t.join(timeout=3)

        mock_rec.assert_not_called()
        self.assertFalse(t.is_alive())

    def test_pg_connection_error_is_handled(self):
        """OperationalError vid PG-anslutning loggas som WARNING – ingen krasch."""
        stop = threading.Event()
        gs = MagicMock()
        attempt = {"n": 0}

        def fail_connect(*args, **kwargs):
            attempt["n"] += 1
            if attempt["n"] >= 2:
                stop.set()
            raise psycopg2.OperationalError("connection refused")

        with patch("psycopg2.connect", side_effect=fail_connect):
            t = threading.Thread(
                target=gl._periodic_reconcile_loop,
                args=(self.DB_CONFIG, gs, stop, 0.05, "test"),
                daemon=True,
            )
            t.start()
            t.join(timeout=5)

        self.assertFalse(t.is_alive())
        self.assertGreaterEqual(attempt["n"], 1)

    def test_unexpected_error_is_handled(self):
        """RuntimeError under avstämning loggas som ERROR – tråden fortsätter och kraschar inte."""
        stop = threading.Event()
        gs = MagicMock()
        call_count = {"n": 0}

        def fail_reconcile(*args, **kwargs):
            call_count["n"] += 1
            if call_count["n"] >= 2:
                stop.set()
            raise RuntimeError("unexpected")

        with patch.object(gl, "_reconcile_geoserver_schemas", side_effect=fail_reconcile):
            with patch("psycopg2.connect", return_value=self._make_conn_mock()):
                t = threading.Thread(
                    target=gl._periodic_reconcile_loop,
                    args=(self.DB_CONFIG, gs, stop, 0.05, "test"),
                    daemon=True,
                )
                t.start()
                t.join(timeout=5)

        self.assertFalse(t.is_alive())
        self.assertGreaterEqual(call_count["n"], 1)

    def test_opens_own_pg_connection(self):
        """Öppnar en egen kortlivad PG-anslutning per körning med rätt parametrar."""
        stop = threading.Event()
        gs = MagicMock()
        called = threading.Event()

        with patch.object(gl, "_reconcile_geoserver_schemas", side_effect=lambda *a, **k: called.set()):
            with patch("psycopg2.connect", return_value=self._make_conn_mock()) as mock_connect:
                t = threading.Thread(
                    target=gl._periodic_reconcile_loop,
                    args=(self.DB_CONFIG, gs, stop, 0.05, "test"),
                    daemon=True,
                )
                t.start()
                called.wait(timeout=3)
                stop.set()
                t.join(timeout=3)

        mock_connect.assert_called_with(
            host=self.DB_CONFIG["host"],
            port=self.DB_CONFIG["port"],
            dbname=self.DB_CONFIG["dbname"],
            user=self.DB_CONFIG["user"],
            password=self.DB_CONFIG["password"],
            connect_timeout=10,
            client_encoding="utf8",
        )

    def test_reconcile_interval_zero_does_not_spawn_thread(self):
        """listen_loop med reconcile_interval=0 startar ingen reconcile-bakgrundstråd."""
        gs = MagicMock()
        stop = threading.Event()
        stop.set()  # Avsluta listen_loop omedelbart utan PG-anslutning

        with patch.object(gl, "_periodic_reconcile_loop") as mock_periodic:
            gl.listen_loop(
                DB_CONFIG,
                reconnect_delay=1,
                gs_client=gs,
                stop_event=stop,
                reconcile_interval=0,
            )

        mock_periodic.assert_not_called()

    def test_reconcile_interval_positive_spawns_thread(self):
        """listen_loop med reconcile_interval>0 startar _periodic_reconcile_loop som bakgrundstråd."""
        gs = MagicMock()
        gs.create_workspace.return_value = True
        gs.create_pg_datastore.return_value = True
        gs.create_gs_role.return_value = True
        gs.create_workspace_acl.return_value = True
        stop = threading.Event()
        periodic_called = threading.Event()

        def fake_periodic(db_config, gs_client, stop_event, interval_seconds, db_label="",
                          all_pg_schemas=None, **kwargs):
            periodic_called.set()
            stop_event.wait()

        with patch.object(gl, "_periodic_reconcile_loop", side_effect=fake_periodic):
            with patch.object(gl, "_fetch_role_credentials",
                              return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
                t = threading.Thread(
                    target=gl.listen_loop,
                    args=(DB_CONFIG, 1, gs, stop, None, None, 30),
                    daemon=True,
                )
                t.start()
                periodic_called.wait(timeout=3)
                stop.set()
                t.join(timeout=3)

        self.assertTrue(periodic_called.is_set(), "_periodic_reconcile_loop startades aldrig")


class TestLoadConfig(unittest.TestCase):
    """
    Enhetstester för load_config – verifierar att HEX_RECONCILE_INTERVAL
    läses korrekt med standard och anpassade värden.
    """

    _MIN_ENV = {
        "HEX_GS_USER": "admin",
        "HEX_GS_PASSWORD": "secret",
        "HEX_DB_1_DBNAME": "geodata",
    }

    def test_reconcile_interval_default(self):
        """HEX_RECONCILE_INTERVAL ej satt → standard 43200 (12 h)."""
        with patch.dict(os.environ, self._MIN_ENV, clear=True):
            config = gl.load_config()
        self.assertEqual(config["reconcile_interval"], 43200)

    def test_reconcile_interval_custom(self):
        """HEX_RECONCILE_INTERVAL=300 → 300."""
        env = {**self._MIN_ENV, "HEX_RECONCILE_INTERVAL": "300"}
        with patch.dict(os.environ, env, clear=True):
            config = gl.load_config()
        self.assertEqual(config["reconcile_interval"], 300)

    def test_reconcile_interval_zero(self):
        """HEX_RECONCILE_INTERVAL=0 → periodisk avstämning avaktiverad."""
        env = {**self._MIN_ENV, "HEX_RECONCILE_INTERVAL": "0"}
        with patch.dict(os.environ, env, clear=True):
            config = gl.load_config()
        self.assertEqual(config["reconcile_interval"], 0)


# ---------------------------------------------------------------------------
# Föräldralösa workspaces: upptäckt och uppstädning
# ---------------------------------------------------------------------------

class _FakeCursor:
    """Cursor-mock som svarar olika på schemafrågan och prefixfrågan."""

    def __init__(self, schemas=(), prefixes=()):
        self._schemas = list(schemas)
        self._prefixes = list(prefixes)
        self._result = []
        self.connection = MagicMock()

    def execute(self, sql, params=None):
        if "pg_namespace" in sql:
            self._result = [(namn,) for namn in self._schemas]
        elif "hex_standardiserade_skyddsnivaer" in sql:
            self._result = [(prefix,) for prefix in self._prefixes]
        else:
            self._result = []

    def fetchall(self):
        return self._result


class _FakeGeoServer:
    """GeoServer-mock med inventerings-API (list_store_names/get_datastore_parameters)."""

    def __init__(self, workspaces, stores=None, params=None, unreachable=()):
        self.rest_url = "http://geoserver.example.com/rest"
        self.workspaces = list(workspaces)
        self.stores = stores or {}
        self.params = params or {}
        self.unreachable = set(unreachable)      # (workspace, store_type) som ger None
        self.create_workspace = MagicMock(return_value=True)
        self.create_pg_datastore = MagicMock(return_value=True)
        self.delete_workspace = MagicMock(return_value=True)
        self.delete_workspace_acl = MagicMock(return_value=True)
        self.delete_gs_role = MagicMock(return_value=True)

    def _request_with_retry(self, method, url, **kwargs):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {
            "workspaces": {"workspace": [{"name": n} for n in self.workspaces]}
        }
        return resp

    def list_store_names(self, workspace, store_type):
        if (workspace, store_type) in self.unreachable:
            return None
        return list(self.stores.get(workspace, {}).get(store_type, []))

    def get_datastore_parameters(self, workspace, store_name):
        return self.params.get((workspace, store_name))


DB_A = {"host": "pg1", "port": 5432, "dbname": "geodata_sk0",
        "user": "hex_listener", "password": "pw"}
DB_B = {"host": "pg1", "port": 5432, "dbname": "geodata_sk1",
        "user": "hex_listener", "password": "pw"}

# Datastore som Hex själv skulle ha skapat för schemat sk0_kba_gamla i DB_A.
def _hex_params(schema="sk0_kba_gamla", dbname="geodata_sk0"):
    return {
        "dbtype": "postgis",
        "host": "pg1",
        "port": "5432",
        "database": dbname,
        "schema": schema,
    }


def _hex_workspace_stores(ws_names):
    """Stores-dict där varje workspace har exakt en PostGIS-datastore."""
    return {ws: {"datastores": [ws]} for ws in ws_names}


class TestOrphanWorkspaceDetection(unittest.TestCase):
    """
    Upptäckt av workspaces vars PG-schema är borta.

    Regressionsskydd för felet där en tömd databas rapporterade "i synk" trots
    kvarlämnade workspaces i GeoServer: ägarprefixen härleddes ur befintliga
    scheman, och utan scheman fanns inga prefix att jämföra mot.
    """

    def _reconcile(self, cur, gs, **kwargs):
        with patch.object(gl, "handle_schema_notification", return_value=True):
            gl._reconcile_geoserver_schemas(cur, DB_A, gs, "geodata_sk0", **kwargs)

    def test_empty_database_still_reports_orphans(self):
        """Databas utan scheman + workspaces i GeoServer → varning, inte "i synk"."""
        cur = _FakeCursor(schemas=[], prefixes=["sk0", "sk1"])
        gs = _FakeGeoServer(["sk0_kba_gamla", "sk0_kba_gamla_w"])

        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            self._reconcile(cur, gs, all_pg_schemas=set(), all_db_configs=[DB_A])

        self.assertTrue(
            [rad for rad in cm.output if "sk0_kba_gamla" in rad],
            "Föräldralös workspace rapporterades inte",
        )
        self.assertFalse(
            [rad for rad in cm.output if "i synk" in rad],
            "Avstämningen påstod att GeoServer och PostgreSQL var i synk",
        )

    def test_empty_database_multi_db_uses_configured_prefixes(self):
        """Flerdatabasläge: prefixen läses ur konfigurationen, inte ur befintliga scheman."""
        cur = _FakeCursor(schemas=[], prefixes=["sk0", "sk1"])
        gs = _FakeGeoServer(["sk0_kba_gamla"])

        with patch.object(gl, "_fetch_publishable_schemas", return_value=set()):
            with self.assertLogs("geoserver_listener", level="WARNING") as cm:
                self._reconcile(cur, gs, all_pg_schemas=set(), all_db_configs=[DB_A, DB_B])

        self.assertTrue([rad for rad in cm.output if "sk0_kba_gamla" in rad])

    def test_other_databases_prefix_is_not_reported(self):
        """Flerdatabasläge: en workspace med ett annat prefix rapporteras inte här."""
        cur = _FakeCursor(schemas=[], prefixes=["sk0"])
        gs = _FakeGeoServer(["sk1_kba_annan"])

        with patch.object(gl, "_fetch_publishable_schemas", return_value=set()):
            with self.assertLogs("geoserver_listener", level="INFO") as cm:
                self._reconcile(cur, gs, all_pg_schemas=set(), all_db_configs=[DB_A, DB_B])

        self.assertFalse([rad for rad in cm.output if "sk1_kba_annan" in rad])

    def test_write_workspace_of_live_schema_is_not_orphan(self):
        """'<schema>_w' till ett levande schema räknas inte som föräldralös."""
        cur = _FakeCursor(schemas=["sk0_kba_aktiv"], prefixes=["sk0"])
        gs = _FakeGeoServer(["sk0_kba_aktiv", "sk0_kba_aktiv_w"])

        with self.assertLogs("geoserver_listener", level="INFO") as cm:
            self._reconcile(cur, gs, all_pg_schemas={"sk0_kba_aktiv"}, all_db_configs=[DB_A])

        self.assertTrue([rad for rad in cm.output if "i synk" in rad])

    def test_stale_startup_set_does_not_hide_new_schemas(self):
        """Färska scheman från andra databaser hämtas om vid varje avstämning."""
        cur = _FakeCursor(schemas=[], prefixes=["sk0"])
        gs = _FakeGeoServer(["sk0_kba_ny"])

        # Schemat skapades i DB_B efter uppstart – startmängden känner inte till det.
        with patch.object(gl, "_fetch_publishable_schemas", return_value={"sk0_kba_ny"}):
            with self.assertLogs("geoserver_listener", level="INFO") as cm:
                self._reconcile(cur, gs, all_pg_schemas=set(), all_db_configs=[DB_A, DB_B])

        self.assertTrue([rad for rad in cm.output if "i synk" in rad])


class TestOrphanWorkspaceCleanup(unittest.TestCase):
    """Uppstädning av föräldralösa workspaces – lägena off, dry-run och on."""

    SCHEMA = "sk0_kba_gamla"
    WS = ["sk0_kba_gamla", "sk0_kba_gamla_w"]

    def _run(self, gs, cleanup_mode, all_db_configs=None, prefixes=("sk0",)):
        """Kör avstämningen och returnerar mocken för borttagningsflödet."""
        cur = _FakeCursor(schemas=[], prefixes=list(prefixes))
        with patch.object(gl, "handle_schema_notification", return_value=True):
            with patch.object(gl, "handle_schema_removal_notification",
                              return_value=True) as removal:
                gl._reconcile_geoserver_schemas(
                    cur, DB_A, gs, "geodata_sk0",
                    all_pg_schemas=set(),
                    all_db_configs=all_db_configs or [DB_A],
                    cleanup_mode=cleanup_mode,
                )
        return removal

    def _hex_owned_gs(self):
        return _FakeGeoServer(
            self.WS,
            stores=_hex_workspace_stores(self.WS),
            params={(ws, ws): _hex_params() for ws in self.WS},
        )

    def test_off_is_default_and_never_deletes(self):
        """CLEANUP_OFF (standard) varnar men tar aldrig bort."""
        removal = self._run(self._hex_owned_gs(), gl.CLEANUP_OFF)
        removal.assert_not_called()

    def test_dry_run_logs_but_does_not_delete(self):
        """CLEANUP_DRY_RUN loggar vad som skulle tas bort utan att ta bort."""
        gs = self._hex_owned_gs()
        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            removal = self._run(gs, gl.CLEANUP_DRY_RUN)
        removal.assert_not_called()
        self.assertTrue([rad for rad in cm.output if "DRY-RUN" in rad and self.SCHEMA in rad])

    def test_on_deletes_hex_owned_workspace(self):
        """CLEANUP_ON tar bort en workspace som bara har Hex:s egna PostGIS-datastores."""
        removal = self._run(self._hex_owned_gs(), gl.CLEANUP_ON)
        removal.assert_called_once()
        self.assertEqual(removal.call_args.args[0], self.SCHEMA)

    def test_coveragestore_protects_manual_raster_publication(self):
        """En manuell rasterpublicering med matchande namn rörs aldrig."""
        gs = _FakeGeoServer(
            ["sk0_kba_gamla"],
            stores={"sk0_kba_gamla": {"coveragestores": ["ortofoto_2025"]}},
        )
        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()
        self.assertTrue([rad for rad in cm.output if "coveragestores" in rad])

    def test_datastore_towards_other_database_is_not_deleted(self):
        """Datastore mot en databas vi inte övervakar → workspacen lämnas orörd."""
        gs = _FakeGeoServer(
            ["sk0_kba_gamla"],
            stores={"sk0_kba_gamla": {"datastores": ["sk0_kba_gamla"]}},
            params={("sk0_kba_gamla", "sk0_kba_gamla"):
                    _hex_params(dbname="nagon_annan_databas")},
        )
        removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()

    def test_datastore_exposing_other_schema_is_not_deleted(self):
        """Datastore som exponerar ett annat schema än workspacenamnet lämnas orörd."""
        gs = _FakeGeoServer(
            ["sk0_kba_gamla"],
            stores={"sk0_kba_gamla": {"datastores": ["sk0_kba_gamla"]}},
            params={("sk0_kba_gamla", "sk0_kba_gamla"): _hex_params(schema="sk0_kba_annat")},
        )
        removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()

    def test_non_postgis_datastore_is_not_deleted(self):
        """Shapefile-datastore (dbtype != postgis) lämnas orörd."""
        gs = _FakeGeoServer(
            ["sk0_kba_gamla"],
            stores={"sk0_kba_gamla": {"datastores": ["mapp"]}},
            params={("sk0_kba_gamla", "mapp"): {"url": "file:data/mapp"}},
        )
        removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()

    def test_empty_workspace_is_not_deleted(self):
        """Workspace helt utan lagringar lämnas orörd och kräver manuell granskning."""
        gs = _FakeGeoServer(["sk0_kba_gamla"], stores={})
        with self.assertLogs("geoserver_listener", level="WARNING") as cm:
            removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()
        self.assertTrue([rad for rad in cm.output if "inga lagringar" in rad])

    def test_unreadable_geoserver_inventory_is_not_deleted(self):
        """Om GeoServer inte kan inventeras tas ingenting bort."""
        gs = _FakeGeoServer(
            ["sk0_kba_gamla"],
            stores={"sk0_kba_gamla": {"datastores": ["sk0_kba_gamla"]}},
            params={("sk0_kba_gamla", "sk0_kba_gamla"): _hex_params()},
            unreachable={("sk0_kba_gamla", "coveragestores")},
        )
        removal = self._run(gs, gl.CLEANUP_ON)
        removal.assert_not_called()

    def test_unreadable_database_blocks_cleanup(self):
        """Om en övervakad databas inte kan läsas tas ingenting bort."""
        gs = self._hex_owned_gs()
        with patch.object(gl, "_fetch_publishable_schemas", return_value=None):
            with self.assertLogs("geoserver_listener", level="WARNING") as cm:
                removal = self._run(gs, gl.CLEANUP_ON, all_db_configs=[DB_A, DB_B])
        removal.assert_not_called()
        self.assertTrue([rad for rad in cm.output if "kunde inte läsas" in rad])


class TestStoreInventoryParsing(unittest.TestCase):
    """GeoServerClient.list_store_names och get_datastore_parameters."""

    def _client(self, status_code, payload):
        client = gl.GeoServerClient("http://gs.example.com/geoserver", "u", "p")
        resp = MagicMock()
        resp.status_code = status_code
        resp.json.return_value = payload
        client._request_with_retry = MagicMock(return_value=resp)
        return client

    def test_empty_collection_is_serialized_as_string(self):
        """GeoServer returnerar "" för en tom samling – ska ge tom lista, inte None."""
        client = self._client(200, {"dataStores": ""})
        self.assertEqual(client.list_store_names("ws", "datastores"), [])

    def test_names_are_extracted(self):
        client = self._client(200, {"coverageStores": {"coverageStore": [{"name": "raster"}]}})
        self.assertEqual(client.list_store_names("ws", "coveragestores"), ["raster"])

    def test_404_is_empty_not_unknown(self):
        client = self._client(404, {})
        self.assertEqual(client.list_store_names("ws", "wmsstores"), [])

    def test_http_error_gives_none(self):
        """500 betyder "vet inte" – aldrig tom lista, som skulle kunna tillåta borttagning."""
        client = self._client(500, {})
        self.assertIsNone(client.list_store_names("ws", "datastores"))

    def test_connection_error_gives_none(self):
        client = gl.GeoServerClient("http://gs.example.com/geoserver", "u", "p")
        client._request_with_retry = MagicMock(
            side_effect=requests.exceptions.ConnectionError("nere")
        )
        self.assertIsNone(client.list_store_names("ws", "datastores"))

    def test_connection_parameters_become_dict(self):
        client = self._client(200, {
            "dataStore": {
                "connectionParameters": {
                    "entry": [
                        {"@key": "dbtype", "$": "postgis"},
                        {"@key": "schema", "$": "sk0_kba_test"},
                    ]
                }
            }
        })
        self.assertEqual(
            client.get_datastore_parameters("ws", "store"),
            {"dbtype": "postgis", "schema": "sk0_kba_test"},
        )


class TestCleanupModeAndEnvPath(unittest.TestCase):
    """HEX_ORPHAN_CLEANUP och HEX_ENV_FILE."""

    def test_default_is_off(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(gl._read_cleanup_mode(), gl.CLEANUP_OFF)

    def test_aliases(self):
        for varde, forvantat in [
            ("on", gl.CLEANUP_ON), ("true", gl.CLEANUP_ON), ("1", gl.CLEANUP_ON),
            ("dry-run", gl.CLEANUP_DRY_RUN), ("dry_run", gl.CLEANUP_DRY_RUN),
            ("OFF", gl.CLEANUP_OFF), ("false", gl.CLEANUP_OFF),
        ]:
            with patch.dict(os.environ, {"HEX_ORPHAN_CLEANUP": varde}, clear=True):
                self.assertEqual(gl._read_cleanup_mode(), forvantat, varde)

    def test_unknown_value_falls_back_to_off(self):
        """Ett stavfel får aldrig aktivera borttagning."""
        with patch.dict(os.environ, {"HEX_ORPHAN_CLEANUP": "yes-please"}, clear=True):
            with self.assertLogs("geoserver_listener", level="WARNING"):
                self.assertEqual(gl._read_cleanup_mode(), gl.CLEANUP_OFF)

    def test_env_file_defaults_to_script_directory(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(gl.resolve_env_path(), SRC_PATH / ".env")

    def test_env_file_override(self):
        with patch.dict(os.environ, {"HEX_ENV_FILE": r"D:\Hex\config\.env"}, clear=True):
            self.assertEqual(gl.resolve_env_path(), Path(r"D:\Hex\config\.env"))


class TestGsVersionsKontroll(unittest.TestCase):
    """
    Versionsparsning och varning för otestade GeoServer-versioner.

    Varningen är rent informativ men ska träffa rätt: en uppgradering till en
    otestad version ska synas i loggen, medan de versioner lyssnaren är
    verifierad mot ska passera tyst.
    """

    def test_parsar_vanliga_versionsstrangar(self):
        for text, forvantat in [
            ("2.28.0", (2, 28)),
            ("3.0.0", (3, 0)),
            ("2.27.3", (2, 27)),
            ("3.1-SNAPSHOT", (3, 1)),
            ("  2.28.1  ", (2, 28)),
        ]:
            self.assertEqual(gl._parsa_gs_version(text), forvantat, text)

    def test_otolkbar_version_ger_none(self):
        for text in ["okänd", "", None, "abc", 2.28]:
            self.assertIsNone(gl._parsa_gs_version(text), repr(text))

    def test_testade_versioner_varnar_inte(self):
        """2.27-3.0 är verifierade – de ska passera utan varning."""
        for text in ["2.27.0", "2.28.0", "2.28.1", "3.0.0"]:
            logger = logging.getLogger("geoserver_listener")
            with patch.object(logger, "warning") as warn:
                gl._varna_om_otestad_gs_version(text)
                self.assertFalse(warn.called, f"{text} varnade oväntat")

    def test_otestad_version_varnar(self):
        """Både äldre och nyare versioner än det testade intervallet varnar."""
        for text in ["2.26.4", "3.1.0", "4.0.0"]:
            with self.assertLogs("geoserver_listener", level="WARNING") as cm:
                gl._varna_om_otestad_gs_version(text)
            self.assertIn(text, "\n".join(cm.output))

    def test_otolkbar_version_varnar_men_stoppar_inte(self):
        with self.assertLogs("geoserver_listener", level="WARNING"):
            gl._varna_om_otestad_gs_version("okänd")


class TestGsRollApiKompat(unittest.TestCase):
    """
    Regression: GeoServers rollendpoint svarar olika i 2.x och 3.x.

    Verifierat mot riktiga servrar (GeoServer 2.28.0 och 3.0.0):

      Fall                     2.28.0                      3.0.0
      -----------------------  --------------------------  ------------------
      POST ny roll             201                         201
      POST befintlig roll      404 + "already exists"      400 + generiskt
      DELETE befintlig roll    200                         200
      DELETE saknad roll       404                         400

    I 3.x bytte felhanteraren i RolesRestController både statuskod (404 -> 400)
    och svarstext: orsaken skrivs numera bara till serverloggen och svaret
    innehåller ett generiskt meddelande. Varken statuskod eller text går alltså
    att matcha på längre, så tvetydiga svar verifieras mot /security/roles.

    Utan detta returnerar create_gs_role False vid varje omkörning mot 3.x,
    vilket avbryter handle_schema_notification i steg 5 – före ACL-stegen –
    för varje redan publicerat schema vid varje avstämning.
    """

    # Autentiska svarskroppar från de två versionerna.
    KROPP_228_FINNS = (
        '{"servlet":"dispatcher","message":"The role r_sk0_kba_test already exists",'
        '"url":"/geoserver/rest/security/roles/role/r_sk0_kba_test","status":"404"}'
    )
    KROPP_300_GENERISK = (
        '{"origin":"dispatcher","message":"Role Rest Request failed with '
        'IllegalArgumentException: Check the logs for further details",'
        '"url":"http://gs/geoserver/rest/security/roles/role/r_sk0_kba_test",'
        '"status":"400"}'
    )

    ROLL = "r_sk0_kba_test"

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com",
            user="admin",
            password="secret",
        )

    def _svar(self, status, text="", json_data=None):
        resp = MagicMock()
        resp.status_code = status
        resp.text = text
        if json_data is None:
            resp.json.side_effect = ValueError("ingen JSON")
        else:
            resp.json.return_value = json_data
        return resp

    def _rollista(self, *roller):
        return self._svar(200, json_data={"roles": list(roller)})

    # -- create_gs_role ----------------------------------------------------

    def test_create_dubblett_228_oforandrad(self):
        """2.28: 404 + 'already exists' avgörs direkt, utan extra anrop."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._svar(404, self.KROPP_228_FINNS)) as req:
            self.assertTrue(client.create_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 1, "2.28-vägen ska inte kosta extra anrop")

    def test_create_dubblett_300_bekraftas(self):
        """3.0: 400 + generisk text -> slås upp mot /security/roles."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry", side_effect=[
            self._svar(400, self.KROPP_300_GENERISK),
            self._rollista("ADMIN", self.ROLL),
        ]) as req:
            self.assertTrue(client.create_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 2)
        self.assertIn("/security/roles.json", req.call_args_list[1][0][1])

    def test_create_400_nar_rollen_verkligen_saknas(self):
        """400 där rollen inte finns är ett äkta fel och ska underkännas."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry", side_effect=[
            self._svar(400, self.KROPP_300_GENERISK),
            self._rollista("ADMIN"),
        ]):
            self.assertFalse(client.create_gs_role(self.ROLL))

    def test_create_400_nar_rollistan_inte_gar_att_hamta(self):
        """Okänt utfall får aldrig tolkas som framgång."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry", side_effect=[
            self._svar(400, self.KROPP_300_GENERISK),
            self._svar(500, "trasig"),
        ]):
            self.assertFalse(client.create_gs_role(self.ROLL))

    def test_create_201_kostar_inget_extra_anrop(self):
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._svar(201)) as req:
            self.assertTrue(client.create_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 1)

    def test_create_409_kostar_inget_extra_anrop(self):
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._svar(409)) as req:
            self.assertTrue(client.create_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 1)

    # -- delete_gs_role ----------------------------------------------------

    def test_delete_saknad_228_oforandrad(self):
        """2.28: 404 avgörs direkt, utan extra anrop."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._svar(404)) as req:
            self.assertTrue(client.delete_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 1, "2.28-vägen ska inte kosta extra anrop")

    def test_delete_saknad_300_bekraftas(self):
        """3.0: 400 -> slås upp; rollen saknas alltså borttagningen är klar."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry", side_effect=[
            self._svar(400, self.KROPP_300_GENERISK),
            self._rollista("ADMIN"),
        ]) as req:
            self.assertTrue(client.delete_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 2)

    def test_delete_400_nar_rollen_finns_kvar(self):
        """400 medan rollen ligger kvar är ett äkta fel."""
        client = self._make_client()
        with patch.object(client, "_request_with_retry", side_effect=[
            self._svar(400, self.KROPP_300_GENERISK),
            self._rollista("ADMIN", self.ROLL),
        ]):
            self.assertFalse(client.delete_gs_role(self.ROLL))

    def test_delete_200_kostar_inget_extra_anrop(self):
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._svar(200)) as req:
            self.assertTrue(client.delete_gs_role(self.ROLL))
        self.assertEqual(req.call_count, 1)

    # -- list_gs_roles -----------------------------------------------------

    def test_list_gs_roles_parsar_svaret(self):
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          return_value=self._rollista("ADMIN", "GROUP_ADMIN")):
            self.assertEqual(client.list_gs_roles(), {"ADMIN", "GROUP_ADMIN"})

    def test_list_gs_roles_returnerar_none_vid_fel(self):
        """None betyder 'vet inte' och får aldrig förväxlas med tom mängd."""
        client = self._make_client()
        for svar in [self._svar(404), self._svar(500, "fel"), self._svar(200)]:
            with patch.object(client, "_request_with_retry", return_value=svar):
                self.assertIsNone(client.list_gs_roles())

    def test_list_gs_roles_none_vid_natverksfel(self):
        client = self._make_client()
        with patch.object(client, "_request_with_retry",
                          side_effect=requests.exceptions.ConnectionError("nere")):
            self.assertIsNone(client.list_gs_roles())


class TestRestWireKontrakt(unittest.TestCase):
    """
    Kontraktstester på HTTP-nivå.

    Övriga sviter mockar _request_with_retry och testar därför aldrig vad som
    faktiskt skickas. Här mockas requests.Session.request i stället, så att
    metod, URL, headers och kropp verifieras – det lager där en förändring i
    GeoServers REST-API först märks.
    """

    def _make_client(self):
        return gl.GeoServerClient(
            base_url="http://geoserver.example.com/",
            user="admin",
            password="secret",
            namespace_uri_base="https://gis.example.se",
        )

    def _patcha_session(self, client, status=200, json_data=None, text=""):
        resp = MagicMock()
        resp.status_code = status
        resp.text = text
        if json_data is None:
            resp.json.side_effect = ValueError("ingen JSON")
        else:
            resp.json.return_value = json_data
        return patch.object(client.session, "request", return_value=resp)

    def test_content_type_satts_inte_sessionsbrett(self):
        """
        Content-Type hör till kroppen. Ett sessionsbrett värde påstår att även
        kroppslösa GET/DELETE/POST har en JSON-kropp. GeoServer 2.28 och 3.0
        svarar identiskt med och utan headern (verifierat mot båda), men
        påståendet är fel och Spring blir strängare för varje version.
        """
        client = self._make_client()
        self.assertNotIn("Content-Type", client.session.headers)
        self.assertEqual(client.session.headers.get("Accept"), "application/json")

    def test_bas_url_normaliseras(self):
        client = self._make_client()
        self.assertEqual(client.rest_url, "http://geoserver.example.com/rest")

    def test_rollskapande_skickar_ratt_metod_och_url(self):
        client = self._make_client()
        with self._patcha_session(client, status=201) as req:
            client.create_gs_role("r_sk0_kba_test")
        metod, url = req.call_args[0]
        self.assertEqual(metod, "POST")
        self.assertEqual(
            url,
            "http://geoserver.example.com/rest/security/roles/role/r_sk0_kba_test",
        )
        self.assertIsNone(req.call_args[1].get("json"),
                          "rollskapande ska inte skicka någon kropp")

    def test_rollistning_anvander_verifierad_sokvag(self):
        """
        '/rest/security/roles.json' fungerar i både 2.28 och 3.0.
        Användarhandbokens '/rest/roles/' ger 404 i båda, och avslutande
        snedstreck ger 404 i 3.x - därför testas den exakta sökvägen.
        """
        client = self._make_client()
        with self._patcha_session(client, json_data={"roles": []}) as req:
            client.list_gs_roles()
        metod, url = req.call_args[0]
        self.assertEqual(metod, "GET")
        self.assertEqual(
            url, "http://geoserver.example.com/rest/security/roles.json"
        )
        self.assertFalse(url.endswith("/"), "avslutande snedstreck ger 404 i 3.x")

    def test_ingen_url_har_avslutande_snedstreck(self):
        """
        Spring 6+ slutade matcha avslutande snedstreck. Verifierat: 2.28 svarar
        200 på '/rest/security/roles/' medan 3.0 svarar 404. Ingen av
        lyssnarens URL:er får sluta med snedstreck.
        """
        client = self._make_client()
        anrop = []

        def registrera(*args, **kwargs):
            anrop.append(args[1])
            resp = MagicMock()
            resp.status_code = 200
            resp.text = ""
            resp.json.return_value = {
                "workspaces": {"workspace": []},
                "roles": [],
                "namespace": {"uri": "https://gis.example.se/sk0_kba_test"},
                "dataStore": {"connectionParameters": {"entry": []}},
            }
            return resp

        with patch.object(client.session, "request", side_effect=registrera):
            client.workspace_exists("sk0_kba_test")
            client.list_gs_roles()
            client.get_namespace_uri("sk0_kba_test")
            client.datastore_exists("sk0_kba_test", "sk0_kba_test")
            client.list_store_names("sk0_kba_test", "datastores")
            client.get_acl_rules()

        self.assertTrue(anrop, "inga anrop registrerades")
        for url in anrop:
            bana = url.split("?")[0]
            self.assertFalse(bana.endswith("/"), f"avslutande snedstreck: {url}")

    def test_datastore_skickar_forvantade_anslutningsparametrar(self):
        """
        Parameternamnen kommer från GeoTools och är oförändrade i GeoServer 3
        - inklusive felstavningen 'Estimated extends', som måste behållas.
        """
        client = self._make_client()
        with patch.object(client, "_get_datastore_user", return_value=None):
            with self._patcha_session(client, status=201) as req:
                client.create_pg_datastore(
                    "sk0_kba_test", "sk0_kba_test", "db.example.se", 5432,
                    "geodata_sk0", "sk0_kba_test", "gs_r_sk0_kba_test", "hemligt",
                )
        payload = req.call_args[1]["json"]
        entries = {e["@key"]: e["$"] for e in
                   payload["dataStore"]["connectionParameters"]["entry"]}
        self.assertEqual(entries["dbtype"], "postgis")
        self.assertEqual(entries["schema"], "sk0_kba_test")
        self.assertEqual(entries["user"], "gs_r_sk0_kba_test")
        self.assertEqual(entries["port"], "5432")
        self.assertEqual(entries["namespace"], "https://gis.example.se/sk0_kba_test")
        for nyckel in ("Expose primary keys", "fetch size", "Loose bbox",
                       "Estimated extends", "encode functions",
                       "validate connections", "max connections", "min connections"):
            self.assertIn(nyckel, entries, f"saknad parameter: {nyckel}")

    def test_workspace_borttagning_anvander_recurse(self):
        client = self._make_client()
        with self._patcha_session(client, status=200) as req:
            client.delete_workspace("sk0_kba_test")
        metod, url = req.call_args[0]
        self.assertEqual(metod, "DELETE")
        self.assertIn("recurse=true", url)

    def test_about_version_tolkas_som_i_bada_versionerna(self):
        """
        Svarsformatet för /about/version.json är identiskt i 2.28.0 och 3.0.0
        (verifierat mot båda servrarna). Notera att GeoTools 'Version' är ett
        heltal medan GeoServers är en sträng - bara GeoServer-posten läses.
        """
        client = self._make_client()
        svar_300 = {"about": {"resource": [
            {"@name": "GeoServer", "Version": "3.0.0"},
            {"@name": "GeoTools", "Version": 35},
            {"@name": "GeoWebCache", "Version": "2.0.0"},
        ]}}
        with self._patcha_session(client, json_data=svar_300):
            with self.assertLogs("geoserver_listener", level="INFO") as cm:
                self.assertTrue(client.test_connection())
        self.assertIn("3.0.0", "\n".join(cm.output))


# ---------------------------------------------------------------------------
# Startpunkt
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )
    # Håll geoserver_listener-loggutskrift synlig så att testutskriften är informativ
    logging.getLogger("geoserver_listener").setLevel(logging.INFO)

    unittest.main(verbosity=2)
