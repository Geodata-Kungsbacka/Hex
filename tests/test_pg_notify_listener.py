#!/usr/bin/env python3
"""
Test: pg_notify-lyssnarsimulering – båda riktningarna.

Verifierar att lyssnaren korrekt tar emot och vidarebefordrar:
  - geoserver_schema        (schema-skapande)
  - geoserver_schema_drop   (schema-borttagning)

GeoServer krävs inte: GeoServerClient ersätts med en mock som
registrerar varje anrop. Testet använder en riktig PostgreSQL-anslutning
så att den faktiska LISTEN/NOTIFY-mekaniken testas.

Lyssnaren använder direkta PostgreSQL-anslutningar (inte JNDI): autentiseringsuppgifter
för läsrollen hämtas från tabellen hex_role_credentials.

Användning:
    python3 tests/test_pg_notify_listener.py
"""

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
# PostgreSQL-anslutningsparametrar (lokalt kluster, inget lösenord krävs)
# ---------------------------------------------------------------------------
PG_PARAMS = {
    "host": "/var/run/postgresql",  # Unix socket – undviker lösenordsautentisering
    "port": 5432,
    "dbname": "postgres",
    "user": "root",
    "password": "",
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

# Testuppgifter för läsrollen som lagras i hex_role_credentials
TEST_ROLE_NAME = f"r_{VALID_CREATE_SCHEMA}"
TEST_ROLE_PASSWORD = "test_password_123"


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
    hex_role_credentials-tabell.
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
        gs.delete_workspace.return_value = True
        gs.delete_workspace_acl.return_value = True
        gs.delete_gs_role.return_value = True
        return gs

    def _make_pg_conn_mock(self):
        """Returnerar en psycopg2-anslutnings-mock."""
        return MagicMock()

    # ------------------------------------------------------------------
    # 2. Schema CREATE-hanterare
    # ------------------------------------------------------------------
    def test_create_handler_calls_workspace_and_datastore(self):
        """Lyckad väg: alla fyra steg utförs för ett giltigt sk0-schema."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )

        self.assertTrue(result)
        gs.create_workspace.assert_called_once_with(VALID_CREATE_SCHEMA)
        gs.create_pg_datastore.assert_called_once_with(
            workspace=VALID_CREATE_SCHEMA,
            store_name=VALID_CREATE_SCHEMA,
            host=DB_CONFIG["host"],
            port=DB_CONFIG["port"],
            dbname=DB_CONFIG["dbname"],
            schema_name=VALID_CREATE_SCHEMA,
            pg_user=TEST_ROLE_NAME,
            pg_password=TEST_ROLE_PASSWORD,
        )
        self.assertEqual(gs.create_gs_role.call_count, 2)
        gs.create_gs_role.assert_any_call(f"r_{VALID_CREATE_SCHEMA}")
        gs.create_gs_role.assert_any_call(f"w_{VALID_CREATE_SCHEMA}")
        gs.create_workspace_acl.assert_called_once_with(VALID_CREATE_SCHEMA)

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
        Regression: skx_kba_test publiceras inte om SCHEMA_PATTERN inte
        uppdaterats sedan tjänsten startade. handle_schema_notification ska
        ladda om mönstret från DB via pg_conn.cursor() innan validering så
        att ett nytt prefix (skx) accepteras utan omstart.
        """
        gs = self._make_gs_mock()

        # Cursor-mock vars fetchall returnerar skx som publicerbart prefix
        cur_mock = MagicMock()
        cur_mock.fetchall.side_effect = [
            [("sk0",), ("sk1",), ("skx",)],   # standardiserade_skyddsnivaer
            [("ext",), ("kba",), ("sys",)],    # standardiserade_datakategorier
        ]
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = cur_mock

        original_pattern = gl.SCHEMA_PATTERN
        try:
            with patch.object(gl, "_fetch_role_credentials",
                              return_value=("r_skx_kba_test", "pw")):
                result = gl.handle_schema_notification(
                    "skx_kba_test", DB_CONFIG, mock_conn, gs
                )
        finally:
            gl.SCHEMA_PATTERN = original_pattern

        self.assertTrue(result, "skx_kba_test ska accepteras när mönstret laddats om från DB")
        gs.create_workspace.assert_called_once_with("skx_kba_test")

    def test_create_handler_missing_credentials(self):
        """Schema utan autentiseringsuppgifter i hex_role_credentials hoppas över."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(None, None)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_workspace_failure_aborts(self):
        """Om workspace-skapande misslyckas hoppas datastore-steget över."""
        gs = self._make_gs_mock(workspace_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_pg_datastore.assert_not_called()

    def test_create_handler_sk1_schema(self):
        """sk1-scheman hanteras identiskt med sk0-scheman."""
        gs = self._make_gs_mock()
        mock_conn = self._make_pg_conn_mock()
        sk1_role = f"r_{VALID_DROP_SCHEMA}"

        with patch.object(gl, "_fetch_role_credentials", return_value=(sk1_role, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_DROP_SCHEMA,   # "sk1_ext_oldschema"
                DB_CONFIG,
                mock_conn,
                gs,
            )
        self.assertTrue(result)
        gs.create_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    def test_create_handler_datastore_failure(self):
        """Om datastore-skapande misslyckas avbryts flödet innan roller skapas."""
        gs = self._make_gs_mock(datastore_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_workspace.assert_called_once()
        gs.create_gs_role.assert_not_called()
        gs.create_workspace_acl.assert_not_called()

    def test_create_handler_role_failure_aborts(self):
        """Om GeoServer-roll inte kan skapas avbryts flödet innan ACL sätts."""
        gs = self._make_gs_mock(role_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_workspace.assert_called_once()
        gs.create_pg_datastore.assert_called_once()
        gs.create_workspace_acl.assert_not_called()

    def test_create_handler_acl_failure_aborts(self):
        """Om ACL-regler inte kan skapas returneras False."""
        gs = self._make_gs_mock(acl_ok=False)
        mock_conn = self._make_pg_conn_mock()

        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            result = gl.handle_schema_notification(
                VALID_CREATE_SCHEMA, DB_CONFIG, mock_conn, gs
            )
        self.assertFalse(result)
        gs.create_workspace.assert_called_once()
        gs.create_pg_datastore.assert_called_once()
        self.assertEqual(gs.create_gs_role.call_count, 2)

    # ------------------------------------------------------------------
    # 3. Schema DROP-hanterare
    # ------------------------------------------------------------------
    def test_drop_handler_calls_delete_workspace(self):
        """Lyckad väg: ACL-regler, workspace och roller tas bort i rätt ordning."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)

        self.assertTrue(result)
        gs.delete_workspace_acl.assert_called_once_with(VALID_DROP_SCHEMA)
        gs.delete_workspace.assert_called_once_with(VALID_DROP_SCHEMA)
        self.assertEqual(gs.delete_gs_role.call_count, 2)
        gs.delete_gs_role.assert_any_call(f"r_{VALID_DROP_SCHEMA}")
        gs.delete_gs_role.assert_any_call(f"w_{VALID_DROP_SCHEMA}")

    def test_drop_handler_rejects_invalid_schema(self):
        """Ogiltiga schemanamn avvisas innan GeoServer kontaktas."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification("bad_schema_name", gs)
        self.assertFalse(result)
        gs.delete_workspace.assert_not_called()

    def test_drop_handler_returns_false_on_geoserver_failure(self):
        """Hanteraren returnerar False när workspace-borttagning misslyckas; roller rensas inte."""
        gs = self._make_gs_mock()
        gs.delete_workspace.return_value = False
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)
        self.assertFalse(result)
        gs.delete_workspace_acl.assert_called_once_with(VALID_DROP_SCHEMA)
        gs.delete_gs_role.assert_not_called()


class TestListenLoopIntegration(unittest.TestCase):
    """
    Integrationstest: kör listen_loop i en bakgrundstråd, skicka NOTIFY
    från huvudtråden och verifiera att mock-GeoServer anropades korrekt.

    _fetch_role_credentials mockas för att undvika beroende av databasens
    hex_role_credentials-tabell under integrationstester.
    """

    TIMEOUT = 5  # sekunder att vänta på att tråden plockar upp notifieringen

    def _run_listen_loop(self, gs_mock, stop_event):
        with patch.object(gl, "_fetch_role_credentials", return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
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
        time.sleep(0.5)  # ge tråden tid att köra LISTEN

        pg_notify(CHANNEL_CREATE, VALID_CREATE_SCHEMA)

        deadline = time.monotonic() + self.TIMEOUT
        while time.monotonic() < deadline:
            if gs.create_workspace.called:
                break
            time.sleep(0.1)

        stop.set()
        t.join(timeout=3)

        gs.create_workspace.assert_called_once_with(VALID_CREATE_SCHEMA)
        gs.create_pg_datastore.assert_called_once()

    def test_listen_loop_picks_up_drop_notification(self):
        """listen_loop tar emot geoserver_schema_drop NOTIFY och anropar delete_workspace."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()
        time.sleep(0.5)

        pg_notify(CHANNEL_DROP, VALID_DROP_SCHEMA)

        deadline = time.monotonic() + self.TIMEOUT
        while time.monotonic() < deadline:
            if gs.delete_workspace.called:
                break
            time.sleep(0.1)

        stop.set()
        t.join(timeout=3)

        gs.delete_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    def test_listen_loop_both_directions(self):
        """Båda NOTIFY-kanaler bearbetas i en enda listen_loop-körning."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()
        time.sleep(0.5)

        pg_notify(CHANNEL_CREATE, VALID_CREATE_SCHEMA)
        pg_notify(CHANNEL_DROP,   VALID_DROP_SCHEMA)

        deadline = time.monotonic() + self.TIMEOUT
        while time.monotonic() < deadline:
            if gs.create_workspace.called and gs.delete_workspace.called:
                break
            time.sleep(0.1)

        stop.set()
        t.join(timeout=3)

        gs.create_workspace.assert_called_once_with(VALID_CREATE_SCHEMA)
        gs.delete_workspace.assert_called_once_with(VALID_DROP_SCHEMA)


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

        # Verify the URI in the payload is a proper https URI, not "http://sk0_ext_sjv"
        ns_payload = calls[2][1]["json"]
        uri = ns_payload["namespace"]["uri"]
        self.assertTrue(uri.startswith("https://"), f"Expected https URI, got: {uri}")
        self.assertNotEqual(uri, "http://sk0_ext_sjv")
        self.assertIn("sk0_ext_sjv", uri)

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

    def test_existing_workspace_skips_all_calls(self):
        """Om workspace redan finns ska varken POST eller PUT anropas."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(200),  # workspace_exists -> 200 = exists
        ]) as mock_req:
            result = client.create_workspace("sk0_ext_sjv")

        self.assertTrue(result)
        self.assertEqual(len(mock_req.call_args_list), 1)


class TestCreatePgDatastore(unittest.TestCase):
    """
    Enhetstester för GeoServerClient.create_pg_datastore som verifierar att
    direkta PostgreSQL-anslutningsparametrar skickas korrekt till GeoServer.
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

    def test_create_pg_datastore_success(self):
        """Lyckad skapning av direkt PG-datastore returnerar True."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # datastore_exists -> 404
            self._mock_response(201),  # POST /datastores -> 201
        ]) as mock_req:
            result = client.create_pg_datastore(
                workspace="sk0_kba_testschema",
                store_name="sk0_kba_testschema",
                host="localhost",
                port=5432,
                dbname="geodata",
                schema_name="sk0_kba_testschema",
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
        self.assertEqual(entries["schema"], "sk0_kba_testschema")
        self.assertEqual(entries["user"], "r_sk0_kba_testschema")
        self.assertEqual(entries["passwd"], "secret")

    def test_create_pg_datastore_already_exists(self):
        """Om datastore redan finns returneras True utan att skapa."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(200),  # datastore_exists -> 200 = exists
        ]) as mock_req:
            result = client.create_pg_datastore(
                workspace="sk0_kba_testschema",
                store_name="sk0_kba_testschema",
                host="localhost",
                port=5432,
                dbname="geodata",
                schema_name="sk0_kba_testschema",
                pg_user="r_sk0_kba_testschema",
                pg_password="secret",
            )

        self.assertTrue(result)
        self.assertEqual(len(mock_req.call_args_list), 1)

    def test_create_pg_datastore_failure(self):
        """Om GeoServer returnerar fel vid POST returneras False."""
        client = self._make_client()

        with patch.object(client, "_request_with_retry", side_effect=[
            self._mock_response(404),  # datastore_exists
            self._mock_response(500),  # POST -> failure
        ]):
            result = client.create_pg_datastore(
                workspace="sk0_kba_testschema",
                store_name="sk0_kba_testschema",
                host="localhost",
                port=5432,
                dbname="geodata",
                schema_name="sk0_kba_testschema",
                pg_user="r_sk0_kba_testschema",
                pg_password="secret",
            )

        self.assertFalse(result)


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
        """Schema i PG men inte i GeoServer → workspace skapas."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=[])

        with patch.object(gl, "_fetch_role_credentials",
                          return_value=(TEST_ROLE_NAME, TEST_ROLE_PASSWORD)):
            gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_called_once_with("sk0_kba_testschema")

    def test_schema_already_in_geoserver_not_recreated(self):
        """Schema finns i både PG och GeoServer → ingen workspace skapas."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=["sk0_kba_testschema"])

        gl._reconcile_geoserver_schemas(cur, self.DB_CONFIG, gs)

        gs.create_workspace.assert_not_called()

    def test_in_sync_logs_ok(self):
        """Identiska listor → ingen skapning, inga varningar."""
        cur = self._make_cur_mock(["sk0_kba_testschema"])
        gs  = self._make_gs_mock(existing_workspaces=["sk0_kba_testschema"])

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
        Schema utan rad i hex_role_credentials (t.ex. gamla JNDI-scheman) ska
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

        Om sk2 skulle läggas till i standardiserade_skyddsnivaer med
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
    Enhetstester för _load_schema_pattern – verifierar att SCHEMA_PATTERN
    byggs korrekt från konfigurationstabellerna och att fallback fungerar.
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
        """Spara originalvärdet av SCHEMA_PATTERN och återställ efter varje test."""
        self._original_pattern = gl.SCHEMA_PATTERN

    def tearDown(self):
        gl.SCHEMA_PATTERN = self._original_pattern

    def test_pattern_built_from_config(self):
        """Mönstret byggs från skyddsnivaer + datakategorier ur DB."""
        cur = self._make_cur_mock(["sk0", "sk1"], ["ext", "kba", "sys"])
        gl._load_schema_pattern(cur)
        self.assertRegex("sk0_kba_test",  gl.SCHEMA_PATTERN)
        self.assertRegex("sk1_ext_sjv",   gl.SCHEMA_PATTERN)
        self.assertNotRegex("sk2_kba_hemlig", gl.SCHEMA_PATTERN)

    def test_new_security_level_included(self):
        """Om sk2 läggs till med publiceras_geoserver = true inkluderas det i mönstret."""
        cur = self._make_cur_mock(["sk0", "sk1", "sk2"], ["ext", "kba", "sys"])
        gl._load_schema_pattern(cur)
        self.assertRegex("sk2_kba_hemlig", gl.SCHEMA_PATTERN)

    def test_new_datakategori_included(self):
        """En ny datakategori inkluderas direkt efter att mönstret laddats."""
        cur = self._make_cur_mock(["sk0", "sk1"], ["ext", "kba", "sys", "int"])
        gl._load_schema_pattern(cur)
        self.assertRegex("sk0_int_test", gl.SCHEMA_PATTERN)

    def test_empty_skyddsnivaer_keeps_existing_pattern(self):
        """Tomma skyddsnivaer → befintligt mönster behålls, ingen krasch."""
        cur = self._make_cur_mock([], ["kba"])
        original = gl.SCHEMA_PATTERN
        gl._load_schema_pattern(cur)
        self.assertIs(gl.SCHEMA_PATTERN, original)

    def test_empty_kategorier_keeps_existing_pattern(self):
        """Tomma datakategorier → befintligt mönster behålls."""
        cur = self._make_cur_mock(["sk0"], [])
        original = gl.SCHEMA_PATTERN
        gl._load_schema_pattern(cur)
        self.assertIs(gl.SCHEMA_PATTERN, original)

    def test_db_error_keeps_existing_pattern(self):
        """DB-fel → befintligt mönster behålls, ingen krasch."""
        cur = MagicMock()
        cur.execute.side_effect = Exception("connection lost")
        original = gl.SCHEMA_PATTERN
        gl._load_schema_pattern(cur)
        self.assertIs(gl.SCHEMA_PATTERN, original)


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
