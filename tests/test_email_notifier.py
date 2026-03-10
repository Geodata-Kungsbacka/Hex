#!/usr/bin/env python3
"""
Test: EmailNotifier – relay-läge och autentiserat läge.

Kräver varken PostgreSQL eller ett riktigt SMTP-server;
smtplib.SMTP mockas helt.

Användning:
    python3 tests/test_email_notifier.py
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, call

# psycopg2 is not installed in this environment; stub it out before importing
# the listener so the module-level import doesn't fail.
for _mod in ("psycopg2", "psycopg2.extensions", "psycopg2.extras",
             "win32serviceutil", "win32service", "win32event",
             "servicemanager", "pywintypes"):
    sys.modules.setdefault(_mod, MagicMock())

sys.path.insert(0, str(Path(__file__).parent.parent / "src" / "geoserver"))
import geoserver_listener as gl

# ---------------------------------------------------------------------------
# Hjälpare
# ---------------------------------------------------------------------------

def _make_notifier(user="", password="", from_addr="hex@example.com",
                   to_addr="dest@example.com", port=25):
    cfg = {
        "enabled": bool(to_addr),
        "host": "smtp.example.com",
        "port": port,
        "user": user,
        "password": password,
        "from_addr": from_addr,
        "to_addr": to_addr,
    }
    return gl.EmailNotifier(cfg)


# ---------------------------------------------------------------------------
# Tester
# ---------------------------------------------------------------------------

class TestEmailNotifierRelayMode(unittest.TestCase):
    """Relay-läge: inga credentials, ingen STARTTLS/login."""

    def setUp(self):
        self.notifier = _make_notifier()  # tom user/password
        self.assertTrue(self.notifier.enabled, "Notifier ska vara aktiverad trots tom user/pass")

    @patch("smtplib.SMTP")
    def test_no_starttls_called(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        self.notifier.send("Ämne", "Meddelande")

        mock_server.starttls.assert_not_called()

    @patch("smtplib.SMTP")
    def test_no_login_called(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        self.notifier.send("Ämne", "Meddelande")

        mock_server.login.assert_not_called()

    @patch("smtplib.SMTP")
    def test_message_sent(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        self.notifier.send("Ämne", "Meddelande")

        mock_server.send_message.assert_called_once()


class TestEmailNotifierAuthMode(unittest.TestCase):
    """Autentiserat läge: credentials finns -> STARTTLS + login."""

    def setUp(self):
        self.notifier = _make_notifier(
            user="user@example.com",
            password="secret",
            port=587,
        )
        self.assertTrue(self.notifier.enabled)

    @patch("smtplib.SMTP")
    def test_starttls_and_login_called(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        self.notifier.send("Ämne", "Meddelande")

        mock_server.starttls.assert_called_once()
        mock_server.login.assert_called_once_with("user@example.com", "secret")
        mock_server.send_message.assert_called_once()


class TestEmailNotifierDisabled(unittest.TestCase):
    """Ingen HEX_SMTP_TO -> disabled, ingen nätverkstrafik."""

    def setUp(self):
        self.notifier = _make_notifier(to_addr="")
        self.assertFalse(self.notifier.enabled)

    @patch("smtplib.SMTP")
    def test_no_smtp_connection(self, mock_smtp_cls):
        self.notifier.send("Ämne", "Meddelande")
        mock_smtp_cls.assert_not_called()


class TestEmailNotifierCooldown(unittest.TestCase):
    """Samma ämne skickas bara en gång under COOLDOWN-perioden."""

    @patch("smtplib.SMTP")
    def test_duplicate_suppressed(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        notifier = _make_notifier()
        notifier.send("Ämne", "Meddelande")
        notifier.send("Ämne", "Meddelande igen")  # ska undertryckas

        self.assertEqual(mock_server.send_message.call_count, 1)

    @patch("smtplib.SMTP")
    def test_different_subjects_both_sent(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        notifier = _make_notifier()
        notifier.send("Ämne A", "Meddelande")
        notifier.send("Ämne B", "Meddelande")

        self.assertEqual(mock_server.send_message.call_count, 2)


class TestEmailNotifierFromAddr(unittest.TestCase):
    """from_addr sätts korrekt i meddelandet."""

    @patch("smtplib.SMTP")
    def test_from_addr_in_message(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value.__enter__ = MagicMock(return_value=mock_server)
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        notifier = _make_notifier(from_addr="avsandare@kungsbacka.se")
        notifier.send("Ämne", "Meddelande")

        sent_msg = mock_server.send_message.call_args[0][0]
        self.assertEqual(sent_msg["From"], "avsandare@kungsbacka.se")


if __name__ == "__main__":
    unittest.main()
