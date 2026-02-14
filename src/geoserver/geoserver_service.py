#!/usr/bin/env python3
"""
HexGeoServer Windows Service - Kor GeoServer Schema Listener som en Windows-tjanst.

Installera, starta och hantera tjansten via kommandoraden:

    python geoserver_service.py install     Installera tjansten
    python geoserver_service.py start       Starta tjansten
    python geoserver_service.py stop        Stoppa tjansten
    python geoserver_service.py remove      Avinstallera tjansten
    python geoserver_service.py status      Visa tjanstens status

Eller hantera via services.msc (Windows Services).

Konfiguration laddas fran miljovariabler (systemvida) eller .env-fil
i samma katalog som detta skript.

Loggning sker till Windows Event Log (Application) och till fil:
    C:\\ProgramData\\Hex\\geoserver_listener.log

Krav:
    pip install psycopg2 requests python-dotenv pywin32
"""

import logging
import os
import sys
import threading
from logging.handlers import RotatingFileHandler
from pathlib import Path

import win32event
import win32service
import win32serviceutil
import servicemanager

# Lagg till skriptets katalog i sys.path sa att geoserver_listener kan importeras
SCRIPT_DIR = Path(__file__).parent.resolve()
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from geoserver_listener import load_config, GeoServerClient, run_all_listeners, log


# =============================================================================
# LOGGING TILL FIL
# =============================================================================

LOG_DIR = Path(os.environ.get("HEX_LOG_DIR", r"C:\ProgramData\Hex"))
LOG_FILE = LOG_DIR / "geoserver_listener.log"


def setup_file_logging():
    """Konfigurerar loggning till roterande fil."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    file_handler = RotatingFileHandler(
        LOG_FILE,
        maxBytes=5 * 1024 * 1024,  # 5 MB
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(
        logging.Formatter(
            "%(asctime)s [%(levelname)s] %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )

    # Lagg till fil-handler pa root och geoserver_listener-loggern
    logging.getLogger().addHandler(file_handler)
    log.addHandler(file_handler)


# =============================================================================
# WINDOWS SERVICE
# =============================================================================

class HexGeoServerService(win32serviceutil.ServiceFramework):
    """Windows-tjanst som kor GeoServer Schema Listener."""

    _svc_name_ = "HexGeoServerListener"
    _svc_display_name_ = "Hex GeoServer Schema Listener"
    _svc_description_ = (
        "Lyssnar pa PostgreSQL-notifieringar och skapar automatiskt "
        "workspace och datastore i GeoServer for nya sk0/sk1-scheman."
    )

    def __init__(self, args):
        win32serviceutil.ServiceFramework.__init__(self, args)
        self.stop_event = threading.Event()
        self.hWaitStop = win32event.CreateEvent(None, 0, 0, None)

    def SvcStop(self):
        """Anropas nar tjansten stoppas (via services.msc eller net stop)."""
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        log.info("Stoppsignal mottagen - avslutar lyssnaren...")
        self.stop_event.set()
        win32event.SetEvent(self.hWaitStop)

    def SvcDoRun(self):
        """Huvudmetod som kor nar tjansten startar."""
        try:
            servicemanager.LogMsg(
                servicemanager.EVENTLOG_INFORMATION_TYPE,
                servicemanager.PYS_SERVICE_STARTED,
                (self._svc_name_, ""),
            )

            setup_file_logging()

            log.info("=" * 60)
            log.info("Hex GeoServer Schema Listener - Windows Service")
            log.info("Loggfil: %s", LOG_FILE)
            log.info("=" * 60)

            # Byt arbetskatalog till skriptets katalog (for .env)
            os.chdir(SCRIPT_DIR)

            config = load_config()

            log.info("GeoServer:  %s", config["gs_url"])
            log.info("Databaser:  %d st", len(config["databases"]))
            for db in config["databases"]:
                log.info("  [%s] %s@%s:%d/%s",
                         db["dbname"], db["user"], db["host"], db["port"], db["dbname"])
                for prefix, jndi in sorted(db["jndi_mappings"].items()):
                    log.info("    %s -> %s", prefix, jndi)

            gs_client = GeoServerClient(
                base_url=config["gs_url"],
                user=config["gs_user"],
                password=config["gs_password"],
            )

            if not gs_client.test_connection():
                log.error("Kunde inte ansluta till GeoServer vid uppstart")
                log.error("Tjansten fortsatter - forsoker igen vid nasta notifiering")

            run_all_listeners(config, stop_event=self.stop_event)

        except Exception as e:
            log.error("Tjansten avslutades med fel: %s", e)
            servicemanager.LogErrorMsg(f"HexGeoServerListener fel: {e}")
        finally:
            log.info("Tjansten avslutad.")
            servicemanager.LogMsg(
                servicemanager.EVENTLOG_INFORMATION_TYPE,
                servicemanager.PYS_SERVICE_STOPPED,
                (self._svc_name_, ""),
            )


# =============================================================================
# STATUSKOMMANDO
# =============================================================================

def show_status():
    """Visar tjanstens aktuella status."""
    import win32service as ws
    try:
        scm = ws.OpenSCManager(None, None, ws.SC_MANAGER_CONNECT)
        try:
            svc = ws.OpenService(scm, HexGeoServerService._svc_name_, ws.SERVICE_QUERY_STATUS)
            try:
                status = ws.QueryServiceStatus(svc)
                state = status[1]
                states = {
                    ws.SERVICE_STOPPED: "Stoppad",
                    ws.SERVICE_START_PENDING: "Startar...",
                    ws.SERVICE_STOP_PENDING: "Stoppar...",
                    ws.SERVICE_RUNNING: "Kor",
                    ws.SERVICE_CONTINUE_PENDING: "Aterupptar...",
                    ws.SERVICE_PAUSE_PENDING: "Pausar...",
                    ws.SERVICE_PAUSED: "Pausad",
                }
                print(f"Tjanst: {HexGeoServerService._svc_display_name_}")
                print(f"Status: {states.get(state, f'Okand ({state})')}")
                if LOG_FILE.exists():
                    print(f"Loggfil: {LOG_FILE}")
            finally:
                ws.CloseServiceHandle(svc)
        finally:
            ws.CloseServiceHandle(scm)
    except Exception as e:
        if "1060" in str(e):
            print(f"Tjansten '{HexGeoServerService._svc_name_}' ar inte installerad.")
        else:
            print(f"Fel: {e}")


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "status":
        show_status()
    elif len(sys.argv) == 1:
        # Kors av Windows Service Manager
        servicemanager.Initialize()
        servicemanager.PrepareToHostSingle(HexGeoServerService)
        servicemanager.StartServiceCtrlDispatcher()
    else:
        win32serviceutil.HandleCommandLine(HexGeoServerService)
