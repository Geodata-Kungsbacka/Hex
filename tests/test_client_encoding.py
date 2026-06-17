#!/usr/bin/env python3
"""
Test: verifiera att psycopg2.connect() alltid anropas med client_encoding="utf8".

Simulerar även det faktiska felet som uppstår utan fix: psycopg2 tar emot
WIN1252-kodade bytes (t.ex. 'ö' = 0xf6) och försöker avkoda dem som UTF-8.

Kör med:
    python3 tests/test_client_encoding.py
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, call

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_PATH = PROJECT_ROOT / "src" / "geoserver"
sys.path.insert(0, str(SRC_PATH))

import geoserver_listener as gl  # noqa: E402


# ---------------------------------------------------------------------------
# Hjälpare: bygger en minimal db_config
# ---------------------------------------------------------------------------
def _db_config(dbname="testdb"):
    return {
        "host": "localhost",
        "port": 5432,
        "dbname": dbname,
        "user": "testuser",
        "password": "testpass",
    }


# ---------------------------------------------------------------------------
# 1. Simulera UnicodeDecodeError utan fix
# ---------------------------------------------------------------------------
class TestUnicodeErrorWithoutFix(unittest.TestCase):
    """Visar att bytes med 0xf6 (ö i WIN1252) inte kan avkodas som UTF-8."""

    def test_win1252_byte_fails_as_utf8(self):
        """0xf6 är giltigt WIN1252 ('ö') men ogiltigt UTF-8 – avkodning ska misslyckas."""
        win1252_bytes = b"Sch\xf6n"  # "Schön" i WIN1252
        with self.assertRaises(UnicodeDecodeError):
            win1252_bytes.decode("utf-8")

    def test_win1252_byte_succeeds_as_cp1252(self):
        """Samma bytes avkodas korrekt med rätt codec (cp1252 = WIN1252)."""
        win1252_bytes = b"Sch\xf6n"
        self.assertEqual(win1252_bytes.decode("cp1252"), "Schön")

    def test_server_side_conversion_roundtrip(self):
        """
        Simulerar server-sidans konvertering: WIN1252 → UTF-8.
        Det är vad client_encoding='utf8' gör i PostgreSQL – servern
        konverterar till UTF-8 innan data skickas till klienten.
        """
        original_win1252 = b"Sch\xf6n"
        text = original_win1252.decode("cp1252")           # server avkodar sin data
        utf8_bytes = text.encode("utf-8")                  # server kodar om till UTF-8
        self.assertEqual(utf8_bytes.decode("utf-8"), "Schön")  # klienten tar emot UTF-8


# ---------------------------------------------------------------------------
# 2. Verifiera att _fetch_publishable_schemas skickar client_encoding
# ---------------------------------------------------------------------------
class TestFetchPublishableSchemasEncoding(unittest.TestCase):

    def _make_mock_conn(self):
        """Returnerar en mock-anslutning med fungerande context manager för cursor."""
        mock_cur = MagicMock()
        mock_cur.__enter__ = MagicMock(return_value=mock_cur)
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.fetchall.return_value = []

        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)
        return mock_conn

    def test_client_encoding_passed(self):
        """_fetch_publishable_schemas ska alltid skicka client_encoding='utf8'."""
        mock_conn = self._make_mock_conn()
        with patch("psycopg2.connect", return_value=mock_conn) as mock_connect:
            gl._fetch_publishable_schemas(_db_config())
            mock_connect.assert_called_once()
            kwargs = mock_connect.call_args.kwargs
            self.assertIn(
                "client_encoding", kwargs,
                "client_encoding saknas i psycopg2.connect()-anropet",
            )
            self.assertEqual(
                kwargs["client_encoding"], "utf8",
                f"Förväntade 'utf8', fick '{kwargs.get('client_encoding')}'",
            )


# ---------------------------------------------------------------------------
# 3. Verifiera att listen_loop skickar client_encoding
# ---------------------------------------------------------------------------
class TestListenLoopEncoding(unittest.TestCase):

    def test_client_encoding_passed(self):
        """listen_loop ska anropa psycopg2.connect() med client_encoding='utf8'."""
        stop_event = __import__("threading").Event()

        mock_cur = MagicMock()
        mock_cur.fetchall.return_value = []

        mock_conn = MagicMock()
        mock_conn.closed = False
        mock_conn.notifies = []
        mock_conn.cursor.return_value = mock_cur

        captured = {}

        def fake_connect(**kwargs):
            captured.update(kwargs)
            stop_event.set()           # avbryt loopen direkt efter första anslutning
            return mock_conn

        mock_gs = MagicMock()
        mock_gs.get_all_workspaces.return_value = []

        with patch("psycopg2.connect", side_effect=fake_connect):
            with patch("select.select", return_value=([], [], [])):
                gl.listen_loop(
                    _db_config(),
                    reconnect_delay=0,
                    gs_client=mock_gs,
                    stop_event=stop_event,
                )

        self.assertIn(
            "client_encoding", captured,
            "client_encoding saknas i psycopg2.connect()-anropet från listen_loop",
        )
        self.assertEqual(
            captured["client_encoding"], "utf8",
            f"Förväntade 'utf8', fick '{captured.get('client_encoding')}'",
        )


# ---------------------------------------------------------------------------
# 4. Verifiera att _periodic_reconcile_loop skickar client_encoding
# ---------------------------------------------------------------------------
class TestPeriodicReconcileEncoding(unittest.TestCase):

    def test_client_encoding_passed(self):
        """_periodic_reconcile_loop ska anropa psycopg2.connect() med client_encoding='utf8'."""
        stop_event = __import__("threading").Event()

        mock_cur = MagicMock()
        mock_cur.__enter__ = MagicMock(return_value=mock_cur)
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.fetchall.return_value = []

        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)

        captured = {}

        def fake_connect(**kwargs):
            captured.update(kwargs)
            stop_event.set()  # kör bara ett varv
            return mock_conn

        mock_gs = MagicMock()
        mock_gs.get_all_workspaces.return_value = []

        with patch("psycopg2.connect", side_effect=fake_connect):
            gl._periodic_reconcile_loop(
                _db_config(),
                gs_client=mock_gs,
                stop_event=stop_event,
                interval_seconds=0,
            )

        self.assertIn(
            "client_encoding", captured,
            "client_encoding saknas i psycopg2.connect()-anropet från _periodic_reconcile_loop",
        )
        self.assertEqual(
            captured["client_encoding"], "utf8",
            f"Förväntade 'utf8', fick '{captured.get('client_encoding')}'",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
