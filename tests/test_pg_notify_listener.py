#!/usr/bin/env python3
"""
Test: pg_notify listener simulation – both directions.

Verifies that the listener logic correctly receives and dispatches:
  - geoserver_schema        (schema creation)
  - geoserver_schema_drop   (schema deletion)

No GeoServer is required: the GeoServerClient is replaced with a mock that
records every call. The test uses a real PostgreSQL connection so the actual
LISTEN / NOTIFY plumbing is exercised.

Usage:
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
# Resolve project root so we can import geoserver_listener directly
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_PATH = PROJECT_ROOT / "src" / "geoserver"
sys.path.insert(0, str(SRC_PATH))

import geoserver_listener as gl  # noqa: E402

# ---------------------------------------------------------------------------
# PostgreSQL connection parameters (local cluster, no password needed)
# ---------------------------------------------------------------------------
PG_PARAMS = {
    "host": "/var/run/postgresql",  # Unix socket – avoids password auth
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
# Helper: open a plain psycopg2 connection in autocommit mode
# ---------------------------------------------------------------------------
def make_conn():
    conn = psycopg2.connect(**PG_PARAMS)
    conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    return conn


# ---------------------------------------------------------------------------
# Helper: send a NOTIFY from a separate connection and return
# ---------------------------------------------------------------------------
def pg_notify(channel, payload):
    """Issue NOTIFY channel, 'payload'; from a short-lived connection."""
    conn = make_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"NOTIFY {channel}, %s;", (payload,))
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Core listener poll – single iteration helper used in tests
# ---------------------------------------------------------------------------
def run_listener_once(listen_conn, timeout=3.0):
    """
    Poll *listen_conn* for up to *timeout* seconds and return all
    (channel, payload) pairs received.
    """
    received = []
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready = select.select([listen_conn], [], [], max(0, remaining))
        if ready == ([], [], []):
            break  # timed out – stop polling
        listen_conn.poll()
        while listen_conn.notifies:
            n = listen_conn.notifies.pop(0)
            received.append((n.channel, n.payload))

    return received


# ===========================================================================
# Tests
# ===========================================================================

class TestPgNotifyRoundTrip(unittest.TestCase):
    """End-to-end LISTEN / NOTIFY round-trip via a real PostgreSQL connection."""

    def setUp(self):
        self.listen_conn = make_conn()
        cur = self.listen_conn.cursor()
        cur.execute(f"LISTEN {CHANNEL_CREATE};")
        cur.execute(f"LISTEN {CHANNEL_DROP};")

    def tearDown(self):
        if not self.listen_conn.closed:
            self.listen_conn.close()

    # ------------------------------------------------------------------
    # 1. Raw LISTEN / NOTIFY – no application logic, just the plumbing
    # ------------------------------------------------------------------
    def test_raw_notify_create_channel_received(self):
        """NOTIFY on geoserver_schema is delivered to the listener."""
        pg_notify(CHANNEL_CREATE, VALID_CREATE_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1, f"Expected 1 notification, got {msgs}")
        channel, payload = msgs[0]
        self.assertEqual(channel, CHANNEL_CREATE)
        self.assertEqual(payload, VALID_CREATE_SCHEMA)

    def test_raw_notify_drop_channel_received(self):
        """NOTIFY on geoserver_schema_drop is delivered to the listener."""
        pg_notify(CHANNEL_DROP, VALID_DROP_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1, f"Expected 1 notification, got {msgs}")
        channel, payload = msgs[0]
        self.assertEqual(channel, CHANNEL_DROP)
        self.assertEqual(payload, VALID_DROP_SCHEMA)

    def test_both_channels_in_sequence(self):
        """Both channels can carry notifications in the same session."""
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
        Raw NOTIFY with an invalid schema name *is* delivered at the transport
        level, but the handler rejects it. Verify the transport still works
        and the handler returns False.
        """
        pg_notify(CHANNEL_CREATE, INVALID_SCHEMA)
        msgs = run_listener_once(self.listen_conn)

        self.assertEqual(len(msgs), 1)
        _, payload = msgs[0]
        self.assertEqual(payload, INVALID_SCHEMA)

        # Handler must reject the invalid name
        mock_gs = MagicMock()
        result = gl.handle_schema_notification(
            INVALID_SCHEMA, JNDI_MAPPINGS, mock_gs
        )
        self.assertFalse(result)
        mock_gs.create_workspace.assert_not_called()


class TestHandlerLogicWithMockGeoServer(unittest.TestCase):
    """
    Unit tests for handle_schema_notification and
    handle_schema_removal_notification using a mock GeoServerClient.
    The PostgreSQL connection is used only for NOTIFY; the handlers run
    synchronously in the test thread.
    """

    def _make_gs_mock(self, workspace_ok=True, datastore_ok=True):
        """Return a GeoServerClient mock with configurable outcomes."""
        gs = MagicMock()
        gs.workspace_exists.return_value = False
        gs.create_workspace.return_value = workspace_ok
        gs.datastore_exists.return_value = False
        gs.create_jndi_datastore.return_value = datastore_ok
        gs.delete_workspace.return_value = True
        return gs

    # ------------------------------------------------------------------
    # 2. Schema CREATE handler
    # ------------------------------------------------------------------
    def test_create_handler_calls_workspace_and_datastore(self):
        """Happy path: workspace + datastore are created for a valid sk0 schema."""
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
        """Schema names that don't match the regex are silently skipped."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_notification(
            "public_bad", JNDI_MAPPINGS, gs
        )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_missing_jndi_mapping(self):
        """Schema with no matching JNDI mapping (e.g. sk2_*) is skipped."""
        gs = self._make_gs_mock()
        # sk2 is not in JNDI_MAPPINGS
        result = gl.handle_schema_notification(
            "sk0_kba_missing", {"sk1": "java:comp/env/jdbc/db"}, gs
        )
        self.assertFalse(result)
        gs.create_workspace.assert_not_called()

    def test_create_handler_workspace_failure_aborts(self):
        """If workspace creation fails the datastore step is skipped."""
        gs = self._make_gs_mock(workspace_ok=False)
        result = gl.handle_schema_notification(
            VALID_CREATE_SCHEMA, JNDI_MAPPINGS, gs
        )
        self.assertFalse(result)
        gs.create_jndi_datastore.assert_not_called()

    def test_create_handler_sk1_schema(self):
        """sk1 schemas are handled identically to sk0 schemas."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_notification(
            VALID_DROP_SCHEMA,   # "sk1_ext_oldschema"
            JNDI_MAPPINGS,
            gs,
        )
        self.assertTrue(result)
        gs.create_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    # ------------------------------------------------------------------
    # 3. Schema DROP handler
    # ------------------------------------------------------------------
    def test_drop_handler_calls_delete_workspace(self):
        """Happy path: delete_workspace is called for a valid schema."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)

        self.assertTrue(result)
        gs.delete_workspace.assert_called_once_with(VALID_DROP_SCHEMA)

    def test_drop_handler_rejects_invalid_schema(self):
        """Invalid schema names are rejected before touching GeoServer."""
        gs = self._make_gs_mock()
        result = gl.handle_schema_removal_notification("bad_schema_name", gs)
        self.assertFalse(result)
        gs.delete_workspace.assert_not_called()

    def test_drop_handler_returns_false_on_geoserver_failure(self):
        """Handler returns False when GeoServer delete fails."""
        gs = self._make_gs_mock()
        gs.delete_workspace.return_value = False
        result = gl.handle_schema_removal_notification(VALID_DROP_SCHEMA, gs)
        self.assertFalse(result)


class TestListenLoopIntegration(unittest.TestCase):
    """
    Integration test: run listen_loop in a background thread, fire NOTIFY
    from the main thread, and assert the mock GeoServer was called correctly.
    """

    TIMEOUT = 5  # seconds to wait for the thread to pick up the notification

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
        """listen_loop receives geoserver_schema NOTIFY and calls create_workspace."""
        gs = self._make_gs_mock()
        stop = threading.Event()

        t = threading.Thread(
            target=self._run_listen_loop, args=(gs, stop), daemon=True
        )
        t.start()
        time.sleep(0.5)  # give the thread time to LISTEN

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
        """listen_loop receives geoserver_schema_drop NOTIFY and calls delete_workspace."""
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
        """Both NOTIFY channels are processed in a single listen_loop run."""
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
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )
    # Keep geoserver_listener log output visible so the test output is informative
    logging.getLogger("geoserver_listener").setLevel(logging.INFO)

    unittest.main(verbosity=2)
