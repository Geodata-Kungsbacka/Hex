#!/usr/bin/env python3
"""
GeoServer Schema Listener - Lyssnar på pg_notify och hanterar workspace/store i GeoServer.

Processen lyssnar på två PostgreSQL-kanaler och hanterar schema-händelser automatiskt:

  Kanal 'geoserver_schema'  (utlöses av CREATE SCHEMA via SQL-triggern
                             notifiera_geoserver_trigger):
    1. Skapar en workspace i GeoServer med samma namn som schemat.
    2. Skapar en JNDI-datastore i workspace med samma namn som schemat.

  Kanal 'geoserver_schema_drop'  (utlöses av DROP SCHEMA via SQL-triggern
                                  notifiera_geoserver_borttagning_trigger):
    1. Tar bort workspace från GeoServer med recurse=true, vilket raderar
       alla datastores och publicerade lager i workspace.
       Det förhindrar att GeoServer gör upprepade anrop mot ett schema
       som inte längre existerar.

Båda kanalerna hanterar enbart scheman vars skyddsnivå har publiceras_geoserver = true
i tabellen standardiserade_skyddsnivaer (standardkonfiguration: sk0 och sk1).

Stödjer flera databaser - en lyssnartråd per databas.
Konfiguration laddas från miljövariabler eller .env-fil.

Användning:
    python geoserver_listener.py              # Starta lyssnaren
    python geoserver_listener.py --test       # Testa GeoServer-anslutning
    python geoserver_listener.py --dry-run    # Visa vad som skulle göras utan att göra det

Manuell återutsändning (om lyssnaren var nere när ett schema skapades/togs bort):
    NOTIFY geoserver_schema,      'sk0_kba_mittschema';   -- lägg till workspace
    NOTIFY geoserver_schema_drop, 'sk0_kba_mittschema';   -- ta bort workspace

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

# Lägg till en konsollhandler bara om ingen handler redan finns
# (geoserver_service.py lägger till en filhandler innan import)
if not log.handlers:
    _console = logging.StreamHandler()
    _console.setFormatter(logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    ))
    log.addHandler(_console)

# Förhindra dubbletter via root-loggern
log.propagate = False

# =============================================================================
# CONFIGURATION
# =============================================================================

def load_config():
    """Laddar konfiguration från miljövariabler.

    Söker först efter en .env-fil i samma katalog som skriptet.
    Miljövariabler som redan är satta har företräde framför .env-filen.

    Stödjer två format:
    1. Nytt flerdatabas-format: HEX_DB_1_DBNAME, HEX_DB_1_JNDI_sk0 osv.
    2. Gammalt enkeldatabas-format: HEX_PG_DBNAME, HEX_JNDI_sk0 osv.
    """
    # Försök ladda .env från samma katalog som skriptet
    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        try:
            from dotenv import load_dotenv
            load_dotenv(env_path, override=False)
            log.info("Laddade konfiguration från %s", env_path)
        except ImportError:
            log.warning(
                "python-dotenv är inte installerat - laddar enbart från miljövariabler. "
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
        # E-post (valfritt - inaktivt om HEX_SMTP_TO inte är satt)
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

    # Validera att kritiska variabler är satta
    missing = []
    if not config["gs_user"]:
        missing.append("HEX_GS_USER")
    if not config["gs_password"]:
        missing.append("HEX_GS_PASSWORD")
    if not config["databases"]:
        missing.append("HEX_DB_1_DBNAME (eller HEX_PG_DBNAME)")

    if missing:
        log.error("Saknade miljövariabler: %s", ", ".join(missing))
        log.error("Konfigurera dessa i .env eller som miljövariabler.")
        sys.exit(1)

    # Varna om någon databas saknar JNDI-kopplingar
    for db in config["databases"]:
        if not db["jndi_mappings"]:
            log.warning(
                "Databas '%s' har inga JNDI-kopplingar konfigurerade. "
                "Ange t.ex. HEX_DB_N_JNDI_sk0=java:comp/env/jdbc/server.database",
                db["dbname"],
            )

    return config


def _parse_database_configs():
    """Parsar databaskonfigurationer från miljövariabler.

    Försöker först det nya flerdatabas-formatet (HEX_DB_N_*).
    Faller tillbaka till det gamla formatet (HEX_PG_* + HEX_JNDI_*).
    """
    # Försöker nytt format: HEX_DB_1_DBNAME, HEX_DB_2_DBNAME osv.
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
    """Parsar HEX_DB_N_* grupper från miljövariabler.

    Delade standardvärden hämtas från HEX_PG_HOST, HEX_PG_PORT osv.
    Varje databas kan överskriva dessa med HEX_DB_N_HOST, HEX_DB_N_PORT osv.
    """
    default_host = os.environ.get("HEX_PG_HOST", "localhost")
    default_port = int(os.environ.get("HEX_PG_PORT", "5432"))
    default_user = os.environ.get("HEX_PG_USER", "postgres")
    default_password = os.environ.get("HEX_PG_PASSWORD", "")

    databases = []
    for n in sorted(db_numbers, key=int):
        prefix = f"HEX_DB_{n}_"

        # Parsa JNDI-kopplingar för denna databas
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
    """Parsar JNDI-kopplingar från miljövariabler (gammalt format).

    Laddar HEX_JNDI_sk0, HEX_JNDI_sk1 osv.
    Returnerar dict med prefix -> JNDI-namn.
    """
    mappings = {}
    for key, value in os.environ.items():
        if key.startswith("HEX_JNDI_"):
            prefix = key[len("HEX_JNDI_"):].lower()  # t.ex. "sk0"
            mappings[prefix] = value

    return mappings


def _load_env_file_fallback(env_path):
    """Enkel .env-laddare om python-dotenv inte är tillgängligt."""
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
    """Skickar e-postnotifieringar vid fel och återhämtning.

    Aktiveras genom att sätta HEX_SMTP_TO i miljövariabler.
    Använder STARTTLS (port 587) mot Exchange/Office 365 som standard.

    Har en enkel spam-spärr: samma ämne skickas inte oftare än var 5:e minut.
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
        self._last_sent = {}  # ämne -> tidpunkt
        self._lock = threading.Lock()

        if self.enabled:
            if self.user and self.password:
                log.info("E-postnotifieringar aktiverade (autentiserad) -> %s", self.to_addr)
            else:
                log.info("E-postnotifieringar aktiverade (anonym relay) -> %s", self.to_addr)

    def _should_send(self, subject):
        """Kontrollerar spam-spärren. Returnerar True om meddelandet får skickas."""
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
                if self.user and self.password:
                    server.starttls()
                    server.login(self.user, self.password)
                server.send_message(msg)
            log.info("E-postnotifiering skickad: %s", subject)
        except Exception as e:
            log.error("Kunde inte skicka e-post ('%s'): %s", subject, e)

    # -- Bekväma metoder för vanliga händelser ---------------------------------

    def notify_schema_failure(self, schema_name, db_label, error):
        """Notifierar om misslyckad schema-publicering till GeoServer."""
        self.send(
            f"[Hex] Schema-publicering misslyckades: {schema_name}",
            f"Schema '{schema_name}' kunde inte publiceras till GeoServer.\n\n"
            f"Databas: {db_label}\n"
            f"Fel: {error}\n\n"
            f"Åtgärd: Kontrollera att GeoServer är tillgängligt och skicka sedan "
            f"NOTIFY manuellt:\n"
            f"  NOTIFY {CHANNEL_SCHEMA_CREATE}, '{schema_name}';\n",
        )

    def notify_pg_connection_lost(self, db_label, error):
        """Notifierar om förlorad PostgreSQL-anslutning."""
        self.send(
            f"[Hex] PostgreSQL-anslutning förlorad: {db_label}",
            f"Lyssnaren tappade anslutningen till databas '{db_label}'.\n\n"
            f"Fel: {error}\n\n"
            f"Lyssnaren försöker återansluta automatiskt.\n"
            f"Under avbrottet kan schema-notifieringar gå förlorade.\n",
        )

    def notify_pg_reconnected(self, db_label):
        """Notifierar om lyckad återanslutning till PostgreSQL."""
        self.send(
            f"[Hex] PostgreSQL återansluten: {db_label}",
            f"Lyssnaren har återanslutit till databas '{db_label}'.\n\n"
            f"Schema-notifieringar hanteras nu som vanligt.\n"
            f"OBS: Notifieringar som skickades under avbrottet kan ha gått förlorade.\n",
        )

    def notify_schema_removal_failure(self, schema_name, db_label, error):
        """Notifierar om misslyckad workspace-borttagning i GeoServer."""
        self.send(
            f"[Hex] Workspace-borttagning misslyckades: {schema_name}",
            f"Schema '{schema_name}' togs bort från databasen men workspace/datastore "
            f"kunde inte tas bort från GeoServer.\n\n"
            f"Databas: {db_label}\n"
            f"Fel: {error}\n\n"
            f"Åtgärd: Kontrollera att GeoServer är tillgängligt och ta sedan bort "
            f"workspace manuellt i GeoServer, eller skicka NOTIFY manuellt:\n"
            f"  NOTIFY {CHANNEL_SCHEMA_DROP}, '{schema_name}';\n",
        )

    def notify_unexpected_error(self, db_label, error):
        """Notifierar om oväntat fel."""
        self.send(
            f"[Hex] Oväntat fel i lyssnaren: {db_label}",
            f"Ett oväntat fel uppstod i lyssnaren för databas '{db_label}'.\n\n"
            f"Fel: {error}\n\n"
            f"Lyssnaren försöker återansluta automatiskt.\n",
        )


# =============================================================================
# GEOSERVER REST API
# =============================================================================

class GeoServerClient:
    """Klient for GeoServer REST API."""

    # Timeout i sekunder för enskilda HTTP-anrop
    REQUEST_TIMEOUT = 30

    # Retry-konfiguration för transienta fel (timeout, anslutningsfel)
    MAX_RETRIES = 3
    RETRY_BACKOFF = [2, 5, 10]  # Sekunder mellan försök

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
        """Gör ett HTTP-anrop med retry vid transienta fel.

        Transienta fel (timeout, anslutningsfel) får upp till MAX_RETRIES
        nya försök med exponentiell backoff. Lyckade svar och HTTP-felkoder
        (4xx, 5xx) returneras direkt utan retry.

        Returns:
            requests.Response
        Raises:
            requests.exceptions.ConnectionError: Om alla försök misslyckats
            requests.exceptions.Timeout: Om alla försök timeout:at
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
                        "  GeoServer-anrop misslyckades (försök %d/%d): %s. "
                        "Försöker igen om %ds...",
                        attempt + 1,
                        1 + self.MAX_RETRIES,
                        e,
                        delay,
                    )
                    time.sleep(delay)
                else:
                    log.error(
                        "  GeoServer-anrop misslyckades efter %d försök: %s",
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
                gs_version = "okänd"
                for r in resources:
                    if r.get("@name") == "GeoServer":
                        gs_version = r.get("Version", "okänd")
                        break
                log.info("Ansluten till GeoServer %s på %s", gs_version, self.base_url)
                return True
            elif resp.status_code == 401:
                log.error("Autentisering misslyckades - kontrollera användarnamn/lösenord")
                return False
            else:
                log.error("Oväntad statuskod från GeoServer: %d", resp.status_code)
                return False
        except requests.ConnectionError:
            log.error("Kan inte ansluta till GeoServer på %s", self.base_url)
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
            log.info("  Workspace '%s' finns redan - hoppar över skapande", name)
            return True

        payload = {"workspace": {"name": name}}

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa workspace: %s", name)
            log.info("  [DRY-RUN] POST %s/workspaces", self.rest_url)
            log.info("  [DRY-RUN] Payload: %s", json.dumps(payload))
            ns_payload = {"namespace": {"prefix": name, "uri": f"https://geoserver.kungsbacka.se/{name}"}}
            log.info("  [DRY-RUN] Skulle sätta namespace URI: PUT %s/namespaces/%s", self.rest_url, name)
            log.info("  [DRY-RUN] Namespace payload: %s", json.dumps(ns_payload))
            return True

        resp = self._request_with_retry(
            "POST", f"{self.rest_url}/workspaces", json=payload
        )

        if resp.status_code != 201:
            log.error(
                "  Misslyckades att skapa workspace '%s': %d %s",
                name,
                resp.status_code,
                resp.text,
            )
            return False

        log.info("  Workspace '%s' skapad", name)

        # GeoServer auto-generates the namespace URI as "http://<name>" which is
        # not a valid URI. Update it to a proper URI after workspace creation.
        ns_payload = {"namespace": {"prefix": name, "uri": f"https://geoserver.kungsbacka.se/{name}"}}
        ns_resp = self._request_with_retry(
            "PUT", f"{self.rest_url}/namespaces/{name}", json=ns_payload
        )
        if ns_resp.status_code == 200:
            log.info("  Namespace URI satt för '%s'", name)
        else:
            log.warning(
                "  Workspace skapad men namespace URI kunde inte uppdateras för '%s': %d %s",
                name,
                ns_resp.status_code,
                ns_resp.text,
            )

        return True

    def delete_workspace(self, name):
        """Tar bort en workspace i GeoServer, inklusive alla datastores och lager.

        Använder recurse=true för att kaskadradera allt som tillhör workspace:
        datastores, publicerade lager och stilar som är knutna enbart till
        den här workspace tas bort automatiskt av GeoServer.

        Returnerar True om borttagningen lyckades eller om workspace inte hittades
        (404 behandlas som framgång - operationen är idempotent).
        """
        if self.dry_run:
            log.info("  [DRY-RUN] Skulle ta bort workspace (inkl. datastores/lager): %s", name)
            log.info("  [DRY-RUN] DELETE %s/workspaces/%s?recurse=true", self.rest_url, name)
            return True

        resp = self._request_with_retry(
            "DELETE", f"{self.rest_url}/workspaces/{name}?recurse=true"
        )

        if resp.status_code == 200:
            log.info("  Workspace '%s' borttagen (inkl. datastores och lager)", name)
            return True
        elif resp.status_code == 404:
            log.info("  Workspace '%s' hittades inte - inget att ta bort", name)
            return True
        else:
            log.error(
                "  Misslyckades att ta bort workspace '%s': %d %s",
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
            log.info("  Datastore '%s' finns redan i workspace '%s' - hoppar över", store_name, workspace)
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

# Regex som matchar giltiga schemanamn för GeoServer-publicering.
# Måste överensstämma med SQL-valideringen i validera_schemanamn(),
# men begränsat till sk0/sk1 (sk2 publiceras inte till GeoServer).
SCHEMA_PATTERN = re.compile(r"^sk[01]_(ext|kba|sys)_.+$")

# pg_notify-kanalnamn. Måste överensstämma med SQL-funktionerna
# notifiera_geoserver() och notifiera_geoserver_borttagning().
CHANNEL_SCHEMA_CREATE = "geoserver_schema"
CHANNEL_SCHEMA_DROP   = "geoserver_schema_drop"


def _db_tag(db_label):
    """Returnerar ett formaterat logg-prefix för en databas, t.ex. '[geodata_sk0] '."""
    return f"[{db_label}] " if db_label else ""


def _validate_schema_name(schema_name, tag):
    """Validerar att schemanamnet matchar det förväntade mönstret.

    SQL-triggern filtrerar redan, men pg_notify-kanalerna är öppna för
    alla med NOTIFY-rättighet. Den här valideringen är ett andra skyddslager.

    Args:
        schema_name: Schemanamnet från notifieringens payload.
        tag:         Logg-prefix (från _db_tag).

    Returns:
        True om schemanamnet är giltigt, annars False (efter loggning).
    """
    if not SCHEMA_PATTERN.match(schema_name):
        log.warning(
            "%sOgiltigt schemanamn '%s' - matchar inte mönster '%s'. Ignorerar.",
            tag,
            schema_name,
            SCHEMA_PATTERN.pattern,
        )
        return False
    return True


def handle_schema_notification(schema_name, jndi_mappings, gs_client, db_label=""):
    """Hanterar en notifiering om nytt schema (kanal: CHANNEL_SCHEMA_CREATE).

    Skapar workspace och JNDI-datastore i GeoServer.
    """
    tag = _db_tag(db_label)
    log.info("%sMottog notifiering for schema: %s", tag, schema_name)

    if not _validate_schema_name(schema_name, tag):
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


def handle_schema_removal_notification(schema_name, gs_client, db_label=""):
    """Hanterar en notifiering om borttaget schema (kanal: CHANNEL_SCHEMA_DROP).

    Tar bort workspace (inkl. datastores och publicerade lager) i GeoServer.
    Samma validering som handle_schema_notification — kanalen är öppen för
    alla med NOTIFY-rättighet så schemanamnet måste kontrolleras.
    """
    tag = _db_tag(db_label)
    log.info("%sMottog borttagningsnotifiering for schema: %s", tag, schema_name)

    if not _validate_schema_name(schema_name, tag):
        return False

    log.info("%s  Tar bort workspace '%s' från GeoServer...", tag, schema_name)
    if not gs_client.delete_workspace(schema_name):
        log.error("%s  Workspace '%s' kunde inte tas bort", tag, schema_name)
        return False

    log.info("%s  Schema '%s' avpublicerat från GeoServer", tag, schema_name)
    return True


# =============================================================================
# POSTGRESQL LISTENER
# =============================================================================

def _dispatch_notification_error(channel, db_label, schema_name, error, notifier, transient=False):
    """Centraliserad felhantering för schema-notifieringar.

    Loggar ett beskrivande felmeddelande och skickar e-postnotifiering via
    notifier (om konfigurerat). Beteendet skiljer sig beroende på kanal och
    om felet är transient (GeoServer otillgänglig) eller oväntat.

    Args:
        channel:   pg_notify-kanalen (CHANNEL_SCHEMA_CREATE eller CHANNEL_SCHEMA_DROP).
        db_label:  Databasnamn för logg-prefix.
        schema_name: Schemanamnet från notifieringens payload.
        error:     Undantaget eller felbeskrivningen.
        notifier:  EmailNotifier-instans eller None.
        transient: True om felet beror på timeout/anslutningsproblem mot GeoServer.
                   Dessa fel kan åtgärdas genom att skicka om notifieringen manuellt.
    """
    is_drop = channel == CHANNEL_SCHEMA_DROP

    if is_drop:
        if transient:
            log.error(
                "[%s] Borttagning av schema '%s' misslyckades efter alla retry-försök: %s. "
                "Skicka NOTIFY manuellt för att försöka igen: "
                "NOTIFY %s, '%s';",
                db_label, schema_name, error, CHANNEL_SCHEMA_DROP, schema_name,
            )
        else:
            log.error("[%s] Fel vid borttagning av schema '%s': %s", db_label, schema_name, error)
        if notifier:
            notifier.notify_schema_removal_failure(schema_name, db_label, error)
    else:
        if transient:
            log.error(
                "[%s] Schema '%s' misslyckades efter alla retry-försök: %s. "
                "Schemat ignoreras denna gång - skicka NOTIFY manuellt "
                "eller återskapa schemat för att försöka igen.",
                db_label, schema_name, error,
            )
        else:
            log.error("[%s] Fel vid hantering av schema '%s': %s", db_label, schema_name, error)
        if notifier:
            notifier.notify_schema_failure(schema_name, db_label, error)

def listen_loop(db_config, reconnect_delay, gs_client, stop_event=None, notifier=None):
    """Huvudloop som lyssnar på pg_notify och hanterar notifieringar för en databas.

    Args:
        db_config: Databaskonfiguration med host, port, dbname, user, password, jndi_mappings
        reconnect_delay: Sekunder att vänta innan återanslutning
        gs_client: GeoServerClient-instans
        stop_event: threading.Event som signalerar att loopen ska avslutas
                    (används av Windows-tjänsten för graceful shutdown)
        notifier: EmailNotifier-instans (eller None om e-post ej konfigurerats)
    """
    db_label = db_config["dbname"]
    was_disconnected = False  # Sparar om vi tappat anslutning för återhämtningsnotifiering

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
            cur.execute(f"LISTEN {CHANNEL_SCHEMA_CREATE};")
            cur.execute(f"LISTEN {CHANNEL_SCHEMA_DROP};")
            log.info("[%s] Lyssnar på kanaler '%s' och '%s'...",
                     db_label, CHANNEL_SCHEMA_CREATE, CHANNEL_SCHEMA_DROP)
            log.info("[%s] Väntar på schema-händelser...", db_label)

            # Skicka återhämtningsnotifiering om vi tappat anslutning tidigare
            if was_disconnected and notifier:
                notifier.notify_pg_reconnected(db_label)
                was_disconnected = False

            while not (stop_event and stop_event.is_set()):
                # Vänta på notifiering med 5s timeout
                # Kort timeout så att stop_event kontrolleras regelbundet
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
                        if notify.channel == CHANNEL_SCHEMA_DROP:
                            handle_schema_removal_notification(
                                schema_name,
                                gs_client,
                                db_label=db_label,
                            )
                        else:
                            handle_schema_notification(
                                schema_name,
                                db_config["jndi_mappings"],
                                gs_client,
                                db_label=db_label,
                            )
                    except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
                        # Transienta fel - alla retry i _request_with_retry är förbrukade.
                        _dispatch_notification_error(
                            notify.channel, db_label, schema_name, e, notifier, transient=True
                        )
                    except Exception as e:
                        _dispatch_notification_error(
                            notify.channel, db_label, schema_name, e, notifier, transient=False
                        )

        except psycopg2.OperationalError as e:
            log.error("[%s] PostgreSQL-anslutning förlorad: %s", db_label, e)
            was_disconnected = True
            if notifier:
                notifier.notify_pg_connection_lost(db_label, e)
        except Exception as e:
            log.error("[%s] Oväntat fel: %s", db_label, e)
            was_disconnected = True
            if notifier:
                notifier.notify_unexpected_error(db_label, e)
        finally:
            if conn and not conn.closed:
                conn.close()

        if stop_event and stop_event.is_set():
            break

        log.info("[%s] Återansluter om %d sekunder...", db_label, reconnect_delay)
        time.sleep(reconnect_delay)

    log.info("[%s] Lyssnaren avslutad.", db_label)


def run_all_listeners(config, dry_run=False, stop_event=None):
    """Startar lyssnare för alla konfigurerade databaser.

    En databas körs direkt i anropande tråd.
    Flera databaser får varsin tråd.
    """
    if stop_event is None:
        stop_event = threading.Event()

    databases = config["databases"]
    notifier = EmailNotifier(config["smtp"])

    if len(databases) == 1:
        # En databas - kör direkt utan extra tråd
        gs_client = GeoServerClient(
            base_url=config["gs_url"],
            user=config["gs_user"],
            password=config["gs_password"],
            dry_run=dry_run,
        )
        listen_loop(databases[0], config["reconnect_delay"], gs_client, stop_event, notifier)
        return

    # Flera databaser - en tråd per databas
    threads = []
    for db_config in databases:
        # Varje tråd får sin egen GeoServerClient (requests.Session är inte trådsäker)
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
        log.info("Startade lyssnartråd för databas '%s'", db_config["dbname"])

    try:
        while any(t.is_alive() for t in threads):
            for t in threads:
                t.join(timeout=1.0)
    except KeyboardInterrupt:
        log.info("Avbruten av användaren - avslutar alla lyssnare...")
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
        help="Visa vad som skulle göras utan att göra det",
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
        log.info("E-post:     avaktiverad (sätt HEX_SMTP_TO för att aktivera)")
    if args.dry_run:
        log.info("LÄGE: dry-run (inga ändringar görs)")
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

    # Starta lyssnare för alla databaser
    run_all_listeners(config, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
