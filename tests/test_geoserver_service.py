#!/usr/bin/env python3
"""
Test: geoserver_service.py – Windows-tjänsten runt lyssnaren.

Modulen importerar pywin32 (win32event, win32service, win32serviceutil,
servicemanager) på toppnivå och går därför inte att importera på Linux. Följden
har varit att den inte haft en enda testrad, trots att den är det som faktiskt
startar lyssnaren i drift.

Sviten stoppar in attrapper för pywin32 i sys.modules före importen. Det räcker
för att testa det som inte är Windows-specifikt:

  * att modulen över huvud taget går att importera – den hämtar fem namn ur
    geoserver_listener (load_config, resolve_env_path, GeoServerClient,
    run_all_listeners, log), och döps något av dem om i lyssnaren fortsätter
    hela lyssnarsviten vara grön medan tjänsten inte längre startar
  * att HEX_LOG_DIR styr loggkatalogen, med D:\\Hex\\Logs som dokumenterad
    standard (docs/09)
  * att setup_file_logging() skapar katalogen och kopplar en roterande
    filhanterare på lyssnarens logger – loggfilen är tjänstens enda
    felsökningskanal

Kräver ingen databas och ingen Windows-miljö.

Kör med:
    python3 tests/test_geoserver_service.py
"""

import importlib
import logging
import os
import sys
import tempfile
import unittest
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
from unittest.mock import MagicMock, patch

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_PATH = PROJECT_ROOT / "src" / "geoserver"
sys.path.insert(0, str(SRC_PATH))

# pywin32 finns inte på Linux. Attrapperna behöver bara svara på
# attributuppslag – modulen anropar dem först när tjänsten körs.
PYWIN32_MODULER = ("win32event", "win32service", "win32serviceutil", "servicemanager")


def importera_tjansten(env=None):
    """Importerar geoserver_service med attrapper för pywin32 och given miljö.

    Modulen räknar ut LOG_DIR vid import, så miljön måste vara satt innan.
    Modulen laddas om varje gång för att importtidslogiken ska köras på nytt.
    """
    attrapper = {namn: MagicMock() for namn in PYWIN32_MODULER}
    # win32serviceutil.ServiceFramework används som basklass – en MagicMock
    # duger inte som bas, så den får bli en tom riktig klass.
    attrapper["win32serviceutil"].ServiceFramework = type("ServiceFramework", (), {})
    with patch.dict(sys.modules, attrapper), \
            patch.dict(os.environ, env or {}, clear=False):
        if "geoserver_service" in sys.modules:
            del sys.modules["geoserver_service"]
        modul = importlib.import_module("geoserver_service")
    return modul


class TestImport(unittest.TestCase):
    """Kontraktet mot geoserver_listener."""

    def test_modulen_gar_att_importera(self):
        self.assertIsNotNone(importera_tjansten())

    def test_namnen_fran_lyssnaren_finns_kvar(self):
        """
        De fem namnen tjänsten importerar ur geoserver_listener.

        Byter ett av dem namn i lyssnaren märks det ingen annanstans:
        lyssnarsviten importerar dem inte via tjänsten, och felet syns först
        när Windows-tjänsten inte startar.
        """
        import geoserver_listener as gl
        for namn in ("load_config", "resolve_env_path", "GeoServerClient",
                     "run_all_listeners", "log"):
            with self.subTest(namn=namn):
                self.assertTrue(hasattr(gl, namn),
                                f"geoserver_service importerar {namn} ur geoserver_listener")

    def test_tjansteklassens_identitet(self):
        """
        _svc_name_ är registreringsnyckeln i Windows tjänstehanterare.

        docs/09 säger att ett byte kräver remove + install, inte update – och
        dokumentationens sc- och py-kommandon använder namnet ordagrant.
        """
        modul = importera_tjansten()
        self.assertEqual(modul.HexGeoServerService._svc_name_, "HexGeoServerListener")
        self.assertTrue(modul.HexGeoServerService._svc_display_name_)


class TestLoggkatalog(unittest.TestCase):
    """HEX_LOG_DIR – dokumenterad i docs/09."""

    def test_standardkatalog_utanfor_kodkatalogen(self):
        """
        Standarden ska ligga utanför src/geoserver.

        docs/09 bygger hela uppgraderingsrutinen på det: ligger loggfilen i
        kodkatalogen håller tjänsten den öppen, och katalogen går inte att
        byta ut utan att först avinstallera tjänsten.
        """
        with patch.dict(os.environ, {}, clear=True):
            modul = importera_tjansten()
        self.assertEqual(str(modul.LOG_DIR), r"D:\Hex\Logs")
        self.assertNotIn("geoserver", str(modul.LOG_DIR).lower())

    def test_hex_log_dir_styr_katalogen(self):
        with tempfile.TemporaryDirectory() as d:
            modul = importera_tjansten({"HEX_LOG_DIR": d})
            self.assertEqual(modul.LOG_DIR, Path(d))
            self.assertEqual(modul.LOG_FILE, Path(d) / "hex_geoserver_listener.log")


class TestSetupFileLogging(unittest.TestCase):
    """Loggfilen är tjänstens enda felsökningskanal."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.katalog = Path(self.tempdir.name) / "Logs"   # finns inte än
        self.modul = importera_tjansten({"HEX_LOG_DIR": str(self.katalog)})
        import geoserver_listener as gl
        self.logger = gl.log
        self.ursprungliga = list(self.logger.handlers)
        self.addCleanup(setattr, self.logger, "handlers", self.ursprungliga)

    def _tillagda(self):
        return [h for h in self.logger.handlers if h not in self.ursprungliga]

    def test_katalogen_skapas_om_den_saknas(self):
        self.assertFalse(self.katalog.exists())
        self.modul.setup_file_logging()
        for h in self._tillagda():
            h.close()
        self.assertTrue(self.katalog.is_dir())

    def test_roterande_handlare_kopplas_pa_lyssnarens_logger(self):
        self.modul.setup_file_logging()
        tillagda = self._tillagda()
        self.addCleanup(lambda: [h.close() for h in tillagda])
        self.assertEqual(len(tillagda), 1, "exakt en filhanterare ska läggas till")
        handlare = tillagda[0]
        self.assertIsInstance(handlare, TimedRotatingFileHandler)
        self.assertEqual(handlare.when, "MIDNIGHT")
        self.assertEqual(handlare.backupCount, 14)
        self.assertEqual(handlare.level, logging.INFO)

    def test_loggposter_hamnar_i_filen_med_utf8(self):
        """Svenska tecken i loggen ska inte bli mojibake."""
        self.modul.setup_file_logging()
        tillagda = self._tillagda()
        self.logger.info("Uppstädning av föräldralösa workspaces: PÅ")
        for h in tillagda:
            h.flush()
            h.close()
        innehall = self.modul.LOG_FILE.read_text(encoding="utf-8")
        self.assertIn("Uppstädning av föräldralösa workspaces: PÅ", innehall)


if __name__ == "__main__":
    unittest.main(verbosity=2)
