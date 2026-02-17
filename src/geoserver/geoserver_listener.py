#!/usr/bin/env python3
"""
GeoServer Schema Listener - Lyssnar pa pg_notify och skapar workspace/store i GeoServer.

Denna process lyssnar pa PostgreSQL-kanalen 'geoserver_schema' och nar ett nytt
sk0- eller sk1-schema skapas, skapar den automatiskt:
  1. En workspace i GeoServer med samma namn som schemat
  2. En JNDI-datastore i den workspace med samma namn som schemat

Stodjer flera databaser - en lyssnartrad per databas.

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
import re
import select
import smtplib
import sys
import threading
import time
from email.mime.text import MIMEText
from pathlib import Path

import psycopg2
import psycopg2.extensions
import requests
from requests.auth import HTTPBasicAuth

# =============================================================================
# LOGGING
# =============================================================================

log = logging.getLogger("geoserver_listener")
log.setLevel(logging.INFO)

# Lagg till en konsollhandler bara om ingen handler redan finns
# (geoserver_service.py lagger till en filhandler innan import)
if not log.handlers:
    _console = logging.StreamHandler()
    _console.setFormatter(logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    ))
    log.addHandler(_console)

# Forhindra dubbletter via root-loggern
log.propagate = False

# =============================================================================
# CONFIGURATION
# =============================================================================

def load_config():
    """Laddar konfiguration fran miljovariabler.

    Soker forst efter en .env-fil i samma katalog som skriptet.
    Miljovariabler som redan ar satta har foretrrade framfor .env-filen.

    Stodjer tva format:
    1. Nytt flerdatabas-format: HEX_DB_1_DBNAME, HEX_DB_1_JNDI_sk0 osv.
    2. Gammalt enkeldatabas-format: HEX_PG_DBNAME, HEX_JNDI_sk0 osv.
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
        # GeoServer
        "gs_url": os.environ.get("HEX_GS_URL", "http://localhost:8080/geoserver"),
        "gs_user": os.environ.get("HEX_GS_USER", ""),
        "gs_password": os.environ.get("HEX_GS_PASSWORD", ""),
        # Reconnect
        "reconnect_delay": int(os.environ.get("HEX_RECONNECT_DELAY", "5")),
        # Databaser
        "databases": _parse_database_configs(),
        # E-post (valfritt - inaktivt om HEX_SMTP_TO inte ar satt)
        "smtp": {
            "enabled": bool(os.environ.get("HEX_SMTP_TO", "")),
            "host": os.environ.get("HEX_SMTP_HOST", "smtp.office365.com"),
            "port": int(os.environ.get("HEX_SMTP_PORT", "587")),
            "user": os.environ.get("HEX_SMTP_USER", ""),
            "password": os.environ.get("HEX_SMTP_PASSWORD", ""),
            "from_addr": os.environ.get("HEX_SMTP_FROM", os.environ.get("HEX_SMTP_USER", "")),
            "to_addr": os.environ.get("HEX_SMTP_TO", ""),
        },
    }

    # Validera att kritiska variabler ar satta
    missing = []
    if not config["gs_user"]:
        missing.append("HEX_GS_USER")
    if not config["gs_password"]:
        missing.append("HEX_GS_PASSWORD")
    if not config["databases"]:
        missing.append("HEX_DB_1_DBNAME (eller HEX_PG_DBNAME)")

    if missing:
        log.error("Saknade miljovariabler: %s", ", ".join(missing))
        log.error("Konfigurera dessa i .env eller som miljovariabler.")
        sys.exit(1)

    # Varna om nagon databas saknar JNDI-kopplingar
    for db in config["databases"]:
        if not db["jndi_mappings"]:
            log.warning(
                "Databas '%s' har inga JNDI-kopplingar konfigurerade. "
                "Ange t.ex. HEX_DB_N_JNDI_sk0=java:comp/env/jdbc/server.database",
                db["dbname"],
            )

    return config


def _parse_database_configs():
    """Parsar databaskonfigurationer fran miljovariabler.

    Forsoker forst det nya flerdatabas-formatet (HEX_DB_N_*).
    Faller tillbaka till det gamla formatet (HEX_PG_* + HEX_JNDI_*).
    """
    # Forsoker nytt format: HEX_DB_1_DBNAME, HEX_DB_2_DBNAME osv.
    db_numbers = set()
    for key in os.environ:
        m = re.match(r"^HEX_DB_(\d+)_DBNAME$", key)
        if m:
            db_numbers.add(m.group(1))

    if db_numbers:
        return _parse_multi_database_configs(db_numbers)

    # Fallback: gammalt enkeldatabas-format
    dbname = os.environ.get("HEX_PG_DBNAME", "")
    if dbname:
        return [{
            "host": os.environ.get("HEX_PG_HOST", "localhost"),
            "port": int(os.environ.get("HEX_PG_PORT", "5432")),
            "dbname": dbname,
            "user": os.environ.get("HEX_PG_USER", "postgres"),
            "password": os.environ.get("HEX_PG_PASSWORD", ""),
            "jndi_mappings": _parse_jndi_mappings(),
        }]

    return []


def _parse_multi_database_configs(db_numbers):
    """Parsar HEX_DB_N_* grupper fran miljovariabler.

    Delade standardvarden hamtas fran HEX_PG_HOST, HEX_PG_PORT osv.
    Varje databas kan overrida dessa med HEX_DB_N_HOST, HEX_DB_N_PORT osv.
    """
    default_host = os.environ.get("HEX_PG_HOST", "localhost")
    default_port = int(os.environ.get("HEX_PG_PORT", "5432"))
    default_user = os.environ.get("HEX_PG_USER", "postgres")
    default_password = os.environ.get("HEX_PG_PASSWORD", "")

    databases = []
    for n in sorted(db_numbers, key=int):
        prefix = f"HEX_DB_{n}_"

        # Parsa JNDI-kopplingar for denna databas
        jndi = {}
        jndi_prefix = prefix + "JNDI_"
        for key, value in os.environ.items():
            if key.startswith(jndi_prefix):
                sk_prefix = key[len(jndi_prefix):].lower()
                jndi[sk_prefix] = value

        dbname = os.environ.get(f"{prefix}DBNAME", "")
        if not dbname:
            continue

        databases.append({
            "host": os.environ.get(f"{prefix}HOST", default_host),
            "port": int(os.environ.get(f"{prefix}PORT", str(default_port))),
            "dbname": dbname,
            "user": os.environ.get(f"{prefix}USER", default_user),
            "password": os.environ.get(f"{prefix}PASSWORD", default_password),
            "jndi_mappings": jndi,
        })

    return databases


def _parse_jndi_mappings():
    """Parsar JNDI-kopplingar fran miljovariabler (gammalt format).

    Lader HEX_JNDI_sk0, HEX_JNDI_sk1 osv.
    Returnerar dict med prefix -> JNDI-namn.
    """
    mappings = {}
    for key, value in os.environ.items():
        if key.startswith("HEX_JNDI_"):
            prefix = key[len("HEX_JNDI_"):].lower()  # t.ex. "sk0"
            mappings[prefix] = value

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
# E-POSTNOTIFIERINGAR
# =============================================================================

class EmailNotifier:
    """Skickar e-postnotifieringar vid fel och aterhamtning.

    Aktiveras genom att satta HEX_SMTP_TO i miljovariabler.
    Anvander STARTTLS (port 587) mot Exchange/Office 365 som standard.

    Har en enkel spam-sparre: samma amne skickas inte oftare an var 5:e minut.
    """

    # Minsta tid (sekunder) mellan identiska notifieringar
    COOLDOWN = 300

    def __init__(self, smtp_config):
        self.enabled = smtp_config.get("enabled", False)
        self.host = smtp_config.get("host", "")
        self.port = smtp_config.get("port", 587)
        self.user = smtp_config.get("user", "")
        self.password = smtp_config.get("password", "")
        self.from_addr = smtp_config.get("from_addr", "")
        self.to_addr = smtp_config.get("to_addr", "")
        self._last_sent = {}  # amne -> tidpunkt
        self._lock = threading.Lock()

        if self.enabled:
            if not self.user or not self.password:
                log.warning(
                    "E-post aktiverad (HEX_SMTP_TO satt) men HEX_SMTP_USER/HEX_SMTP_PASSWORD "
                    "saknas - e-postnotifieringar avaktiverade"
                )
                self.enabled = False
            else:
                log.info("E-postnotifieringar aktiverade -> %s", self.to_addr)

    def _should_send(self, subject):
        """Kontrollerar spam-sparren. Returnerar True om meddelandet far skickas."""
        with self._lock:
            last = self._last_sent.get(subject, 0)
            now = time.time()
            if now - last < self.COOLDOWN:
                return False
            self._last_sent[subject] = now
            return True

    def send(self, subject, body):
        """Skickar ett e-postmeddelande. Loggar fel men kastar aldrig undantag."""
        if not self.enabled:
            return

        if not self._should_send(subject):
            log.debug("E-post undertryckt (cooldown): %s", subject)
            return

        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = subject
        msg["From"] = self.from_addr
        msg["To"] = self.to_addr

        try:
            with smtplib.SMTP(self.host, self.port, timeout=30) as server:
                server.starttls()
                server.login(self.user, self.password)
                server.send_message(msg)
            log.info("E-postnotifiering skickad: %s", subject)
        except Exception as e:
            log.error("Kunde inte skicka e-post ('%s'): %s", subject, e)

    # -- Bekvama metoder for vanliga handelser ---------------------------------

    def notify_schema_failure(self, schema_name, db_label, error):
        """Notifierar om misslyckad schema-publicering till GeoServer."""
        self.send(
            f"[Hex] Schema-publicering misslyckades: {schema_name}",
            f"Schema '{schema_name}' kunde inte publiceras till GeoServer.\n\n"
            f"Databas: {db_label}\n"
            f"Fel: {error}\n\n"
            f"Atgard: Kontrollera att GeoServer ar tillgangligt och skicka sedan "
            f"NOTIFY manuellt:\n"
            f"  NOTIFY geoserver_schema, '{schema_name}';\n",
        )

    def notify_pg_connection_lost(self, db_label, error):
        """Notifierar om forlorad PostgreSQL-anslutning."""
        self.send(
            f"[Hex] PostgreSQL-anslutning forlorad: {db_label}",
            f"Lyssnaren tappade anslutningen till databas '{db_label}'.\n\n"
            f"Fel: {error}\n\n"
            f"Lyssnaren forsoker ateransluta automatiskt.\n"
            f"Under avbrottet kan schema-notifieringar ga forlorade.\n",
        )

    def notify_pg_reconnected(self, db_label):
        """Notifierar om lyckad ateranslutning till PostgreSQL."""
        self.send(
            f"[Hex] PostgreSQL ateransluten: {db_label}",
            f"Lyssnaren har ateranslutit till databas '{db_label}'.\n\n"
            f"Schema-notifieringar hanteras nu som vanligt.\n"
            f"OBS: Notifieringar som skickades under avbrottet kan ha gatt forlorade.\n",
        )

    def notify_unexpected_error(self, db_label, error):
        """Notifierar om ovantat fel."""
        self.send(
            f"[Hex] Ovantat fel i lyssnaren: {db_label}",
            f"Ett ovantat fel uppstod i lyssnaren for databas '{db_label}'.\n\n"
            f"Fel: {error}\n\n"
            f"Lyssnaren forsoker ateransluta automatiskt.\n",
        )


# =============================================================================
# GEOSERVER REST API
# =============================================================================

class GeoServerClient:
    """Klient for GeoServer REST API."""

    # Timeout i sekunder for enskilda HTTP-anrop
    REQUEST_TIMEOUT = 30

    # Retry-konfiguration for transienta fel (timeout, anslutningsfel)
    MAX_RETRIES = 3
    RETRY_BACKOFF = [2, 5, 10]  # Sekunder mellan forsok

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

    def _request_with_retry(self, method, url, **kwargs):
        """Gor ett HTTP-anrop med retry vid transienta fel.

        Transienta fel (timeout, anslutningsfel) far upp till MAX_RETRIES
        nya forsok med exponentiell backoff. Lyckade svar och HTTP-felkoder
        (4xx, 5xx) returneras direkt utan retry.

        Returns:
            requests.Response
        Raises:
            requests.exceptions.ConnectionError: Om alla forsok misslyckats
            requests.exceptions.Timeout: Om alla forsok timeout:at
        """
        kwargs.setdefault("timeout", self.REQUEST_TIMEOUT)
        last_exc = None

        for attempt in range(1 + self.MAX_RETRIES):
            try:
                resp = self.session.request(method, url, **kwargs)
                return resp
            except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
                last_exc = e
                if attempt < self.MAX_RETRIES:
                    delay = self.RETRY_BACKOFF[attempt]
                    log.warning(
                        "  GeoServer-anrop misslyckades (forsok %d/%d): %s. "
                        "Forsoker igen om %ds...",
                        attempt + 1,
                        1 + self.MAX_RETRIES,
                        e,
                        delay,
                    )
                    time.sleep(delay)
                else:
                    log.error(
                        "  GeoServer-anrop misslyckades efter %d forsok: %s",
                        1 + self.MAX_RETRIES,
                        e,
                    )

        raise last_exc

    def test_connection(self):
        """Testar anslutning till GeoServer REST API."""
        try:
            resp = self._request_with_retry("GET", f"{self.rest_url}/about/version.json")
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
        resp = self._request_with_retry(
            "GET", f"{self.rest_url}/workspaces/{name}.json"
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

        resp = self._request_with_retry(
            "POST", f"{self.rest_url}/workspaces", json=payload
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
        resp = self._request_with_retry(
            "GET", f"{self.rest_url}/workspaces/{workspace}/datastores/{name}.json"
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

        resp = self._request_with_retry(
            "POST", f"{self.rest_url}/workspaces/{workspace}/datastores", json=payload
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

# Regex som matchar giltiga schemanamn for GeoServer-publicering.
# Maste overensstamma med SQL-valideringen i validera_schemanamn(),
# men begransat till sk0/sk1 (sk2 publiceras inte till GeoServer).
SCHEMA_PATTERN = re.compile(r"^sk[01]_(ext|kba|sys)_.+$")


def handle_schema_notification(schema_name, jndi_mappings, gs_client, db_label=""):
    """Hanterar en notifiering om nytt schema.

    Skapar workspace och JNDI-datastore i GeoServer.
    """
    tag = f"[{db_label}] " if db_label else ""
    log.info("%sMottog notifiering for schema: %s", tag, schema_name)

    # Validera schemanamnet innan vi gor nagot mot GeoServer.
    # SQL-triggern filtrerar redan, men pg_notify-kanalen ar oppen
    # sa vem som helst med NOTIFY-rattighet kan skicka godtycklig payload.
    if not SCHEMA_PATTERN.match(schema_name):
        log.warning(
            "%sOgiltigt schemanamn '%s' - matchar inte monster '%s'. Ignorerar.",
            tag,
            schema_name,
            SCHEMA_PATTERN.pattern,
        )
        return False

    # Extrahera prefix (sk0 eller sk1)
    prefix = schema_name.split("_")[0]  # t.ex. "sk0"

    if prefix not in jndi_mappings:
        log.warning(
            "%sIngen JNDI-koppling konfigurerad for prefix '%s' - hoppar over schema '%s'",
            tag,
            prefix,
            schema_name,
        )
        return False

    jndi_name = jndi_mappings[prefix]
    log.info("%s  Prefix: %s -> JNDI: %s", tag, prefix, jndi_name)

    # 1. Skapa workspace
    log.info("%s  Steg 1: Skapar workspace '%s'...", tag, schema_name)
    if not gs_client.create_workspace(schema_name):
        log.error("%s  Avbryter - workspace kunde inte skapas", tag)
        return False

    # 2. Skapa JNDI-datastore
    log.info("%s  Steg 2: Skapar JNDI-datastore '%s'...", tag, schema_name)
    if not gs_client.create_jndi_datastore(schema_name, schema_name, jndi_name, schema_name):
        log.error("%s  Avbryter - datastore kunde inte skapas", tag)
        return False

    log.info("%s  Schema '%s' publicerat till GeoServer", tag, schema_name)
    return True


# =============================================================================
# POSTGRESQL LISTENER
# =============================================================================

def listen_loop(db_config, reconnect_delay, gs_client, stop_event=None, notifier=None):
    """Huvudloop som lyssnar pa pg_notify och hanterar notifieringar for en databas.

    Args:
        db_config: Databaskonfiguration med host, port, dbname, user, password, jndi_mappings
        reconnect_delay: Sekunder att vanta innan ateranslutning
        gs_client: GeoServerClient-instans
        stop_event: threading.Event som signalerar att loopen ska avslutas
                    (anvands av Windows-tjansten for graceful shutdown)
        notifier: EmailNotifier-instans (eller None om e-post ej konfigurerats)
    """
    db_label = db_config["dbname"]
    was_disconnected = False  # Sparar om vi tappat anslutning for aterhamtningsnotifiering

    while not (stop_event and stop_event.is_set()):
        conn = None
        try:
            log.info("[%s] Ansluter till PostgreSQL %s@%s:%d/%s...",
                     db_label, db_config["user"], db_config["host"],
                     db_config["port"], db_config["dbname"])

            conn = psycopg2.connect(
                host=db_config["host"],
                port=db_config["port"],
                dbname=db_config["dbname"],
                user=db_config["user"],
                password=db_config["password"],
            )
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

            cur = conn.cursor()
            cur.execute("LISTEN geoserver_schema;")
            log.info("[%s] Lyssnar pa kanal 'geoserver_schema'...", db_label)
            log.info("[%s] Vantar pa nya scheman...", db_label)

            # Skicka aterhamtningsnotifiering om vi tappat anslutning tidigare
            if was_disconnected and notifier:
                notifier.notify_pg_reconnected(db_label)
                was_disconnected = False

            while not (stop_event and stop_event.is_set()):
                # Vanta pa notifiering med 5s timeout
                # Kort timeout sa att stop_event kontrolleras regelbundet
                if select.select([conn], [], [], 5) == ([], [], []):
                    # Timeout - skicka keepalive
                    cur.execute("SELECT 1")
                    continue

                conn.poll()
                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    schema_name = notify.payload

                    if not schema_name:
                        log.warning("[%s] Tom notifiering mottagen - ignorerar", db_label)
                        continue

                    try:
                        handle_schema_notification(
                            schema_name,
                            db_config["jndi_mappings"],
                            gs_client,
                            db_label=db_label,
                        )
                    except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
                        # Transienta fel - alla retry i _request_with_retry
                        # ar forbrukade. Logga tydligt sa det syns i loggen.
                        log.error(
                            "[%s] Schema '%s' misslyckades efter alla retry-forsok: %s. "
                            "Schemat ignoreras denna gang - skicka NOTIFY manuellt "
                            "eller aterskap schemat for att forsoka igen.",
                            db_label, schema_name, e,
                        )
                        if notifier:
                            notifier.notify_schema_failure(schema_name, db_label, e)
                    except Exception as e:
                        log.error("[%s] Fel vid hantering av schema '%s': %s",
                                  db_label, schema_name, e)
                        if notifier:
                            notifier.notify_schema_failure(schema_name, db_label, e)

        except psycopg2.OperationalError as e:
            log.error("[%s] PostgreSQL-anslutning forlorad: %s", db_label, e)
            was_disconnected = True
            if notifier:
                notifier.notify_pg_connection_lost(db_label, e)
        except Exception as e:
            log.error("[%s] Ovantat fel: %s", db_label, e)
            was_disconnected = True
            if notifier:
                notifier.notify_unexpected_error(db_label, e)
        finally:
            if conn and not conn.closed:
                conn.close()

        if stop_event and stop_event.is_set():
            break

        log.info("[%s] Ateransluter om %d sekunder...", db_label, reconnect_delay)
        time.sleep(reconnect_delay)

    log.info("[%s] Lyssnaren avslutad.", db_label)


def run_all_listeners(config, dry_run=False, stop_event=None):
    """Startar lyssnare for alla konfigurerade databaser.

    En databas kors direkt i anropande trad.
    Flera databaser far varsin trad.
    """
    if stop_event is None:
        stop_event = threading.Event()

    databases = config["databases"]
    notifier = EmailNotifier(config["smtp"])

    if len(databases) == 1:
        # En databas - kor direkt utan extra trad
        gs_client = GeoServerClient(
            base_url=config["gs_url"],
            user=config["gs_user"],
            password=config["gs_password"],
            dry_run=dry_run,
        )
        listen_loop(databases[0], config["reconnect_delay"], gs_client, stop_event, notifier)
        return

    # Flera databaser - en trad per databas
    threads = []
    for db_config in databases:
        # Varje trad far sin egen GeoServerClient (requests.Session ar inte tradsaker)
        gs_client = GeoServerClient(
            base_url=config["gs_url"],
            user=config["gs_user"],
            password=config["gs_password"],
            dry_run=dry_run,
        )
        t = threading.Thread(
            target=listen_loop,
            args=(db_config, config["reconnect_delay"], gs_client, stop_event, notifier),
            name=f"listener-{db_config['dbname']}",
            daemon=True,
        )
        t.start()
        threads.append(t)
        log.info("Startade lyssnartrad for databas '%s'", db_config["dbname"])

    try:
        while any(t.is_alive() for t in threads):
            for t in threads:
                t.join(timeout=1.0)
    except KeyboardInterrupt:
        log.info("Avbruten av anvandaren - avslutar alla lyssnare...")
        stop_event.set()
        for t in threads:
            t.join(timeout=5.0)


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

    # Visa konfiguration
    log.info("=" * 60)
    log.info("GeoServer Schema Listener")
    log.info("=" * 60)
    log.info("GeoServer:  %s", config["gs_url"])
    log.info("Databaser:  %d st", len(config["databases"]))
    for db in config["databases"]:
        log.info("  [%s] %s@%s:%d/%s",
                 db["dbname"], db["user"], db["host"], db["port"], db["dbname"])
        for prefix, jndi in sorted(db["jndi_mappings"].items()):
            log.info("    %s -> %s", prefix, jndi)
    if config["smtp"]["enabled"]:
        log.info("E-post:     %s -> %s", config["smtp"]["host"], config["smtp"]["to_addr"])
    else:
        log.info("E-post:     avaktiverad (satt HEX_SMTP_TO for att aktivera)")
    if args.dry_run:
        log.info("LAGE: dry-run (inga andringar gors)")
    log.info("=" * 60)

    # Testa GeoServer-anslutning
    gs_client = GeoServerClient(
        base_url=config["gs_url"],
        user=config["gs_user"],
        password=config["gs_password"],
        dry_run=args.dry_run,
    )

    if not gs_client.test_connection():
        log.error("Kunde inte ansluta till GeoServer - avbryter")
        sys.exit(1)

    if args.test:
        log.info("Anslutningstest lyckat")
        sys.exit(0)

    # Starta lyssnare for alla databaser
    run_all_listeners(config, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
