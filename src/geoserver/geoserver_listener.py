#!/usr/bin/env python3
"""
GeoServer Schema Listener - Lyssnar pa pg_notify och skapar workspace/store i GeoServer.

Denna process lyssnar pa PostgreSQL-kanalen 'geoserver_schema' och nar ett nytt
sk0- eller sk1-schema skapas, skapar den automatiskt:
  1. En workspace i GeoServer med samma namn som schemat
  2. En JNDI-datastore i den workspace med samma namn som schemat

Konfiguration laddas fran miljovariabler eller .env-fil.

Anvandning:
    python geoserver_listener.py              # Starta lyssnaren
    python geoserver_listener.py --test       # Testa GeoServer-anslutning
    python geoserver_listener.py --dry-run    # Visa vad som skulle goras utan att gora det

Krav:
    pip install psycopg2 requests python-dotenv
"""

import argparse
import json
import logging
import os
import select
import sys
import time
from pathlib import Path

import psycopg2
import psycopg2.extensions
import requests
from requests.auth import HTTPBasicAuth

# =============================================================================
# LOGGING
# =============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("geoserver_listener")

# =============================================================================
# CONFIGURATION
# =============================================================================

def load_config():
    """Laddar konfiguration fran miljovariabler.

    Soker forst efter en .env-fil i samma katalog som skriptet.
    Miljovariabler som redan ar satta har foretrrade framfor .env-filen.
    """
    # Forsok ladda .env fran samma katalog som skriptet
    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        try:
            from dotenv import load_dotenv
            load_dotenv(env_path, override=False)
            log.info("Laddade konfiguration fran %s", env_path)
        except ImportError:
            log.warning(
                "python-dotenv ar inte installerat - lader enbart fran miljovariabler. "
                "Installera med: pip install python-dotenv"
            )
            _load_env_file_fallback(env_path)

    config = {
        # PostgreSQL
        "pg_host": os.environ.get("HEX_PG_HOST", "localhost"),
        "pg_port": int(os.environ.get("HEX_PG_PORT", "5432")),
        "pg_dbname": os.environ.get("HEX_PG_DBNAME", ""),
        "pg_user": os.environ.get("HEX_PG_USER", "postgres"),
        "pg_password": os.environ.get("HEX_PG_PASSWORD", ""),
        # GeoServer
        "gs_url": os.environ.get("HEX_GS_URL", "http://localhost:8080/geoserver"),
        "gs_user": os.environ.get("HEX_GS_USER", ""),
        "gs_password": os.environ.get("HEX_GS_PASSWORD", ""),
        # JNDI-kopplingar per prefix
        # Format: java:comp/env/jdbc/[server].[database]
        "jndi_mappings": _parse_jndi_mappings(),
        # Reconnect
        "reconnect_delay": int(os.environ.get("HEX_RECONNECT_DELAY", "5")),
    }

    # Validera att kritiska variabler ar satta
    missing = []
    if not config["pg_dbname"]:
        missing.append("HEX_PG_DBNAME")
    if not config["gs_user"]:
        missing.append("HEX_GS_USER")
    if not config["gs_password"]:
        missing.append("HEX_GS_PASSWORD")

    if missing:
        log.error("Saknade miljovariabler: %s", ", ".join(missing))
        log.error("Konfigurera dessa i .env eller som miljovariabler.")
        sys.exit(1)

    return config


def _parse_jndi_mappings():
    """Parsar JNDI-kopplingar fran miljovariabler.

    Lader HEX_JNDI_sk0, HEX_JNDI_sk1 osv.
    Returnerar dict med prefix -> JNDI-namn.
    """
    mappings = {}
    for key, value in os.environ.items():
        if key.startswith("HEX_JNDI_"):
            prefix = key[len("HEX_JNDI_"):].lower()  # t.ex. "sk0"
            mappings[prefix] = value

    if not mappings:
        log.warning(
            "Inga JNDI-kopplingar konfigurerade. "
            "Ange t.ex. HEX_JNDI_sk0=java:comp/env/jdbc/server.database"
        )

    return mappings


def _load_env_file_fallback(env_path):
    """Enkel .env-laddare om python-dotenv inte ar tillgangligt."""
    try:
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, value = line.partition("=")
                    key = key.strip()
                    value = value.strip().strip('"').strip("'")
                    if key not in os.environ:
                        os.environ[key] = value
    except Exception as e:
        log.warning("Kunde inte ladda %s: %s", env_path, e)


# =============================================================================
# GEOSERVER REST API
# =============================================================================

class GeoServerClient:
    """Klient for GeoServer REST API."""

    def __init__(self, base_url, user, password, dry_run=False):
        self.base_url = base_url.rstrip("/")
        self.rest_url = f"{self.base_url}/rest"
        self.auth = HTTPBasicAuth(user, password)
        self.dry_run = dry_run
        self.session = requests.Session()
        self.session.auth = self.auth
        self.session.headers.update({
            "Content-Type": "application/json",
            "Accept": "application/json",
        })

    def test_connection(self):
        """Testar anslutning till GeoServer REST API."""
        try:
            resp = self.session.get(f"{self.rest_url}/about/version.json", timeout=10)
            if resp.status_code == 200:
                data = resp.json()
                resources = data.get("about", {}).get("resource", [])
                gs_version = "okand"
                for r in resources:
                    if r.get("@name") == "GeoServer":
                        gs_version = r.get("Version", "okand")
                        break
                log.info("Ansluten till GeoServer %s pa %s", gs_version, self.base_url)
                return True
            elif resp.status_code == 401:
                log.error("Autentisering misslyckades - kontrollera anvandardnamn/losenord")
                return False
            else:
                log.error("Ovantad statuskod fran GeoServer: %d", resp.status_code)
                return False
        except requests.ConnectionError:
            log.error("Kan inte ansluta till GeoServer pa %s", self.base_url)
            return False
        except Exception as e:
            log.error("Fel vid anslutning till GeoServer: %s", e)
            return False

    def workspace_exists(self, name):
        """Kontrollerar om en workspace redan finns."""
        resp = self.session.get(
            f"{self.rest_url}/workspaces/{name}.json", timeout=10
        )
        return resp.status_code == 200

    def create_workspace(self, name):
        """Skapar en workspace i GeoServer."""
        if self.workspace_exists(name):
            log.info("  Workspace '%s' finns redan - hoppar over skapande", name)
            return True

        payload = {"workspace": {"name": name}}

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa workspace: %s", name)
            log.info("  [DRY-RUN] POST %s/workspaces", self.rest_url)
            log.info("  [DRY-RUN] Payload: %s", json.dumps(payload))
            return True

        resp = self.session.post(
            f"{self.rest_url}/workspaces",
            json=payload,
            timeout=10,
        )

        if resp.status_code == 201:
            log.info("  Workspace '%s' skapad", name)
            return True
        else:
            log.error(
                "  Misslyckades att skapa workspace '%s': %d %s",
                name,
                resp.status_code,
                resp.text,
            )
            return False

    def datastore_exists(self, workspace, name):
        """Kontrollerar om en datastore redan finns."""
        resp = self.session.get(
            f"{self.rest_url}/workspaces/{workspace}/datastores/{name}.json",
            timeout=10,
        )
        return resp.status_code == 200

    def create_jndi_datastore(self, workspace, store_name, jndi_name, schema_name):
        """Skapar en JNDI PostGIS-datastore i GeoServer.

        Args:
            workspace: Workspace-namn
            store_name: Datastore-namn (samma som schema)
            jndi_name: JNDI-kopplingsnamn (t.ex. java:comp/env/jdbc/server.db)
            schema_name: PostgreSQL-schemanamn att exponera
        """
        if self.datastore_exists(workspace, store_name):
            log.info("  Datastore '%s' finns redan i workspace '%s' - hoppar over", store_name, workspace)
            return True

        payload = {
            "dataStore": {
                "name": store_name,
                "type": "PostGIS (JNDI)",
                "enabled": True,
                "connectionParameters": {
                    "entry": [
                        {"@key": "dbtype", "$": "postgis"},
                        {"@key": "jndiReferenceName", "$": jndi_name},
                        {"@key": "schema", "$": schema_name},
                        {"@key": "Expose primary keys", "$": "true"},
                        {"@key": "fetch size", "$": "1000"},
                        {"@key": "Loose bbox", "$": "true"},
                        {"@key": "Estimated extends", "$": "true"},
                        {"@key": "encode functions", "$": "true"},
                    ]
                },
            }
        }

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa JNDI-datastore: %s", store_name)
            log.info("  [DRY-RUN] POST %s/workspaces/%s/datastores", self.rest_url, workspace)
            log.info("  [DRY-RUN] JNDI: %s", jndi_name)
            log.info("  [DRY-RUN] Schema: %s", schema_name)
            return True

        resp = self.session.post(
            f"{self.rest_url}/workspaces/{workspace}/datastores",
            json=payload,
            timeout=10,
        )

        if resp.status_code == 201:
            log.info("  Datastore '%s' skapad med JNDI '%s'", store_name, jndi_name)
            return True
        else:
            log.error(
                "  Misslyckades att skapa datastore '%s': %d %s",
                store_name,
                resp.status_code,
                resp.text,
            )
            return False


# =============================================================================
# SCHEMA HANDLER
# =============================================================================

def handle_schema_notification(schema_name, config, gs_client):
    """Hanterar en notifiering om nytt schema.

    Skapar workspace och JNDI-datastore i GeoServer.
    """
    log.info("Mottog notifiering for schema: %s", schema_name)

    # Extrahera prefix (sk0 eller sk1)
    prefix = schema_name.split("_")[0]  # t.ex. "sk0"

    if prefix not in config["jndi_mappings"]:
        log.warning(
            "  Ingen JNDI-koppling konfigurerad for prefix '%s' - hoppar over schema '%s'",
            prefix,
            schema_name,
        )
        log.warning(
            "  Konfigurera HEX_JNDI_%s i miljovariabler eller .env",
            prefix,
        )
        return False

    jndi_name = config["jndi_mappings"][prefix]
    log.info("  Prefix: %s -> JNDI: %s", prefix, jndi_name)

    # 1. Skapa workspace
    log.info("  Steg 1: Skapar workspace '%s'...", schema_name)
    if not gs_client.create_workspace(schema_name):
        log.error("  Avbryter - workspace kunde inte skapas")
        return False

    # 2. Skapa JNDI-datastore
    log.info("  Steg 2: Skapar JNDI-datastore '%s'...", schema_name)
    if not gs_client.create_jndi_datastore(schema_name, schema_name, jndi_name, schema_name):
        log.error("  Avbryter - datastore kunde inte skapas")
        return False

    log.info("  Schema '%s' publicerat till GeoServer", schema_name)
    return True


# =============================================================================
# POSTGRESQL LISTENER
# =============================================================================

def listen_loop(config, gs_client):
    """Huvudloop som lyssnar pa pg_notify och hanterar notifieringar."""
    while True:
        conn = None
        try:
            log.info("Ansluter till PostgreSQL %s@%s:%d/%s...",
                     config["pg_user"], config["pg_host"],
                     config["pg_port"], config["pg_dbname"])

            conn = psycopg2.connect(
                host=config["pg_host"],
                port=config["pg_port"],
                dbname=config["pg_dbname"],
                user=config["pg_user"],
                password=config["pg_password"],
            )
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

            cur = conn.cursor()
            cur.execute("LISTEN geoserver_schema;")
            log.info("Lyssnar pa kanal 'geoserver_schema'...")
            log.info("Vantar pa nya scheman...")

            while True:
                # Vanta pa notifiering med 60s timeout (for keepalive)
                if select.select([conn], [], [], 60) == ([], [], []):
                    # Timeout - skicka keepalive
                    cur.execute("SELECT 1")
                    continue

                conn.poll()
                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    schema_name = notify.payload

                    if not schema_name:
                        log.warning("Tom notifiering mottagen - ignorerar")
                        continue

                    try:
                        handle_schema_notification(schema_name, config, gs_client)
                    except Exception as e:
                        log.error("Fel vid hantering av schema '%s': %s", schema_name, e)

        except psycopg2.OperationalError as e:
            log.error("PostgreSQL-anslutning forlorad: %s", e)
        except Exception as e:
            log.error("Ovantat fel: %s", e)
        finally:
            if conn and not conn.closed:
                conn.close()

        delay = config["reconnect_delay"]
        log.info("Ateransluter om %d sekunder...", delay)
        time.sleep(delay)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="GeoServer Schema Listener - skapar workspace/store automatiskt vid nya scheman"
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Testa anslutning till GeoServer och avsluta",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Visa vad som skulle goras utan att gora det",
    )
    args = parser.parse_args()

    config = load_config()

    gs_client = GeoServerClient(
        base_url=config["gs_url"],
        user=config["gs_user"],
        password=config["gs_password"],
        dry_run=args.dry_run,
    )

    # Visa konfiguration
    log.info("=" * 60)
    log.info("GeoServer Schema Listener")
    log.info("=" * 60)
    log.info("PostgreSQL: %s@%s:%d/%s",
             config["pg_user"], config["pg_host"],
             config["pg_port"], config["pg_dbname"])
    log.info("GeoServer:  %s", config["gs_url"])
    log.info("JNDI-kopplingar:")
    for prefix, jndi in sorted(config["jndi_mappings"].items()):
        log.info("  %s -> %s", prefix, jndi)
    if args.dry_run:
        log.info("LAGE: dry-run (inga andringar gors)")
    log.info("=" * 60)

    # Testa GeoServer-anslutning
    if not gs_client.test_connection():
        log.error("Kunde inte ansluta till GeoServer - avbryter")
        sys.exit(1)

    if args.test:
        log.info("Anslutningstest lyckat")
        sys.exit(0)

    # Starta lyssnaren
    listen_loop(config, gs_client)


if __name__ == "__main__":
    main()
