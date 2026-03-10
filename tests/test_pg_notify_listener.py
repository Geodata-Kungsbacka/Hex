#!/usr/bin/env python3
"""
Test: pg_notify-lyssnarsimulering – båda riktningarna.

Verifierar att lyssnaren korrekt tar emot och vidarebefordrar:
  - geoserver_schema        (schema-skapande)
  - geoserver_schema_drop   (schema-borttagning)

GeoServer krävs inte: GeoServerClient ersätts med en mock som
registrerar varje anrop. Testet använder en riktig PostgreSQL-anslutning
så att den faktiska LISTEN/NOTIFY-mekaniken testas.

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

CHANNEL_CREATE = gl.CHANNEL_SCHEMA_CREATE   # "geoserver_schema"
CHANNEL_DROP   = gl.CHANNEL_SCHEMA_DROP     # "geoserver_schema_drop"

VALID_CREATE_SCHEMA = "sk0_kba_testschema"
VALID_DROP_SCHEMA   = "sk1_ext_oldschema"
INVALID_SCHEMA      = "public_not_a_valid_name"

JNDI_MAPPINGS = {
    "sk0": "java:comp/env/jdbc/server.testdb",
    "sk1": "java:comp/env/jdbc/server.testdb",
}


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

        # Hanteraren måste avvisa det ogiltiga namnet
        mock_gs = MagicMock()
        result = gl.handle_schema_notification(
            INVALID_SCHEMA, JNDI_MAPPINGS, mock_gs
        )
        self.assertFalse(result)
        mock_gs.create_workspace.assert_not_called()


class TestHandlerLogicWithMockGeoServer(unittest.TestCase):
    """
    Enhetstester för handle_schema_notification och
    handle_schema_removal_notification med en mockad GeoServerClient.
    PostgreSQL-anslutningen används enbart för NOTIFY; hanterarna körs
    synkront i testtråden.
    """

    def _make_gs_mock(self, workspace_ok=True, datastore_ok=True):
        """Returnerar en GeoServerClient-mock med konfigurerbart utfall."""
        gs = MagicMock()
        gs.workspace_exists.return_value = False
        gs.create_workspace.return_value = workspace_ok
        gs.datastore_exists.return_value = False
        gs.create_jndi_datastore.return_value = datastore_ok
        gs.delete_workspace.return_value = True
        return gs

    # ------------------------------------------------------------------
    # 2. Schema CREATE-hanterare
    # ------------------------------------------------------------------
    def test_create_handler_calls_workspace_and_datastore(self):
        """Lyckad väg: workspace + datastore skapas för ett giltigt sk0-schema."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_notification(
            VALID_CREATE_SCHEMA, JNDI_MAPPINGS, gs
        )

        self.assertTrue(result)
        gs.create_workspace.assert_called_once_with(VALID_CREATE_SCHEMA)
        gs.create_jndi_datastore.assert_called_once_with(
            VALID_CREATE_SCHEMA,
            VALID_CREATE_SCHEMA,
            JNDI_MAPPINGS["sk0"],
            VALID_CREATE_SCHEMA,
        )

    def test_create_handler_rejects_invalid_schema(self):
        """Schemanamn som inte matchar regex hoppas tyst över."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_notification(
            "public_bad", JNDI_MAPPINGS, gs
        )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_missing_jndi_mapping(self):
        """Schema utan matchande JNDI-koppling (t.ex. sk2_*) hoppas över."""
        gs = self._make_gs_mock()
        # sk2 finns inte i JNDI_MAPPINGS
        result = gl.handle_schema_notification(
            "sk0_kba_missing", {"sk1": "java:comp/env/jdbc/db"}, gs
        )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_workspace_failure_aborts(self):
        """Om workspace-skapande misslyckas hoppas datastore-steget över."""
        gs = self._make_gs_mock(workspace_ok=False)
        result = gl.handle_schema_notification(
            VALID_CREATE_SCHEMA, JNDI_MAPPINGS, gs
        )
        self.assertFalse(result)
        gs.create_jndi_datastore.assert_not_called()

    def test_create_handler_sk1_schema(self):
        """sk1-scheman hanteras identiskt med sk0-scheman."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_notification(
            VALID_DROP_SCHEMA,   # "sk1_ext_oldschema"
            JNDI_MAPPINGS,
            gs,
        )
        self.assertTrue(result)
        gs.create_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    # ------------------------------------------------------------------
    # 3. Schema DROP-hanterare
    # ------------------------------------------------------------------
    def test_drop_handler_calls_delete_workspace(self):
        """Lyckad väg: delete_workspace anropas för ett giltigt schema."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)

        self.assertTrue(result)
        gs.delete_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    def test_drop_handler_rejects_invalid_schema(self):
        """Ogiltiga schemanamn avvisas innan GeoServer kontaktas."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification("bad_schema_name", gs)
        self.assertFalse(result)
        gs.delete_workspace.assert_not_called()

    def test_drop_handler_returns_false_on_geoserver_failure(self):
        """Hanteraren returnerar False när GeoServer-borttagning misslyckas."""
        gs = self._make_gs_mock()
        gs.delete_workspace.return_value = False
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)
        self.assertFalse(result)


class TestListenLoopIntegration(unittest.TestCase):
    """
    Integrationstest: kör listen_loop i en bakgrundstråd, skicka NOTIFY
    från huvudtråden och verifiera att mock-GeoServer anropades korrekt.
    """

    TIMEOUT = 5  # sekunder att vänta på att tråden plockar upp notifieringen

    def _run_listen_loop(self, gs_mock, stop_event, db_label="testdb"):
        db_config = {**PG_PARAMS, "jndi_mappings": JNDI_MAPPINGS}
        gl.listen_loop(
            db_config,
            reconnect_delay=1,
            gs_client=gs_mock,
            stop_event=stop_event,
        )

    def _make_gs_mock(self):
        gs = MagicMock()
        gs.workspace_exists.return_value = False
        gs.create_workspace.return_value = True
        gs.datastore_exists.return_value = False
        gs.create_jndi_datastore.return_value = True
        gs.delete_workspace.return_value = True
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
        gs.create_jndi_datastore.assert_called_once()

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
