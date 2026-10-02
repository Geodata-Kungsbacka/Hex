#!/usr/bin/env python3
"""
GeoServer Schema Listener - Lyssnar på pg_notify och hanterar workspaces/stores i GeoServer.

Processen lyssnar på två PostgreSQL-kanaler och hanterar schema-händelser automatiskt:

  Kanal 'geoserver_schema'  (utlöses av CREATE SCHEMA via SQL-triggern
                             hex_notifiera_gs_trigger):
    Per schema skapas två workspaces med varsin PostGIS-datastore:

    Läsworkspace  '{schema}'   — ansluter med gs_r_{schema} (SELECT-behörighet).
                                 Används av WMS/WFS-läsanrop.
    Skrivworkspace '{schema}_w' — ansluter med gs_w_{schema} (ALL-behörighet).
                                  Används av WFS-T-transaktioner (Insert/Update/Delete).

    Autentiseringsuppgifterna hämtas från tabellen hex_rolluppgifter där
    hex_hantera_std_roller() lagrar de autogenererade lösenorden vid CREATE SCHEMA.
    Vilka roller som är läs- och skrivkonto avgörs av
    hex_standardiserade_roller.geoserver_konto via hex_geoserver_rollnamn();
    gs_r_/gs_w_ är standardnamnen.

  Kanal 'geoserver_schema_drop'  (utlöses av DROP SCHEMA via SQL-triggern
                                  hex_notifiera_gs_borttagning_trigger):
    Tar bort båda workspaces ('{schema}' och '{schema}_w') med recurse=true,
    vilket raderar datastores och publicerade lager i respektive workspace.

Båda kanalerna hanterar enbart scheman vars skyddsnivå har publiceras_geoserver = true
i tabellen hex_standardiserade_skyddsnivaer. Standardkonfigurationen publicerar sk0 och sk1;
övriga prefix (sk2, skx m.fl.) kan aktiveras genom att sätta publiceras_geoserver = true
för respektive rad. Mönstret laddas om dynamiskt vid varje notifiering och
avstämning. Det finns inget hårdkodat reservmönster: kan det inte laddas hoppas
notifieringen över med ett ERROR, och avstämningen tar schemat senare.

Stödjer flera databaser - en lyssnartråd per databas.
Konfiguration laddas från miljövariabler eller .env-fil.

Användning:
    python geoserver_listener.py              # Starta lyssnaren
    python geoserver_listener.py --test       # Testa GeoServer-anslutning
    python geoserver_listener.py --dry-run    # Visa vad som skulle göras utan att göra det

Manuell återutsändning (om lyssnaren var nere när ett schema skapades/togs bort):
    NOTIFY geoserver_schema,      'sk0_kba_mittschema';   -- lägg till workspaces
    NOTIFY geoserver_schema_drop, 'sk0_kba_mittschema';   -- ta bort workspaces

Krav:
    pip install psycopg2 requests python-dotenv
"""

import argparse
import datetime
import hashlib
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
import psycopg2.errors
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

# Lägen för uppstädning av föräldralösa GeoServer-workspaces.
# Styrs av HEX_ORPHAN_CLEANUP och läses av _reconcile_geoserver_schemas.
CLEANUP_OFF     = "off"       # Endast varning i loggen (standard)
CLEANUP_DRY_RUN = "dry-run"   # Loggar vad som skulle tas bort, tar inte bort
CLEANUP_ON      = "on"        # Tar bort workspaces som Hex säkert äger

# Accepterade stavningar per läge – ett stavfel ska varken aktivera borttagning
# eller tyst avaktivera en uppstädning som driftansvarig tror är påslagen.
_CLEANUP_ALIASES = {
    "":         CLEANUP_OFF,
    "off":      CLEANUP_OFF,
    "false":    CLEANUP_OFF,
    "0":        CLEANUP_OFF,
    "nej":      CLEANUP_OFF,
    "dry-run":  CLEANUP_DRY_RUN,
    "dry_run":  CLEANUP_DRY_RUN,
    "dryrun":   CLEANUP_DRY_RUN,
    "on":       CLEANUP_ON,
    "true":     CLEANUP_ON,
    "1":        CLEANUP_ON,
    "ja":       CLEANUP_ON,
}


def resolve_env_path():
    """Returnerar sökvägen till .env-filen som ska laddas.

    HEX_ENV_FILE pekar ut en fil utanför kodkatalogen. Det gör att
    installationsmappen kan bytas ut vid uppgradering utan att konfigurationen
    följer med — och utan att en öppen .env i mappen blockerar utbytet.
    Utan variabeln används .env i skriptets katalog som tidigare.
    """
    override = os.environ.get("HEX_ENV_FILE", "").strip().strip('"')
    if override:
        return Path(override)
    return Path(__file__).parent / ".env"


def _read_cleanup_mode():
    """Läser HEX_ORPHAN_CLEANUP och översätter till ett giltigt uppstädningsläge.

    Okända värden ger CLEANUP_OFF plus en varning: borttagning aktiveras aldrig
    av ett värde vi inte känner igen.
    """
    raw = os.environ.get("HEX_ORPHAN_CLEANUP", "").strip().lower()
    mode = _CLEANUP_ALIASES.get(raw)
    if mode is None:
        log.warning(
            "HEX_ORPHAN_CLEANUP='%s' är inte ett giltigt värde (off | dry-run | on) – "
            "uppstädning av föräldralösa workspaces förblir avstängd.",
            raw,
        )
        return CLEANUP_OFF
    return mode


def _read_reconcile_schedule():
    """Läser schemat för den periodiska avstämningen ur miljön.

    Antingen HEX_RECONCILE_INTERVAL (sekunder) eller HEX_RECONCILE_TIME
    (HH:MM, lokal tid) – inte båda. Båda satta, eller ett ogiltigt klockslag,
    avbryter uppstarten: att tyst välja det ena skulle dölja ett
    konfigurationsfel som annars bara märks som uteblivna körningar.

    Standard när ingen är satt är intervallet 43200 (12 h). Avstämningen
    fångar bara notifieringar som missats medan lyssnaren varit uppe OCH
    ansluten, vilket är sällsynt – avstämningen vid varje (åter)anslutning
    täcker nedtidsfallet. Intervallet räknas från senaste avstämning, så
    klockslaget glider; HEX_RECONCILE_TIME håller körningen på natten.

    Returns:
        {"reconcile_interval": int, "reconcile_time": datetime.time | None}
    """
    raw_tid = os.environ.get("HEX_RECONCILE_TIME", "").strip()
    raw_intervall = os.environ.get("HEX_RECONCILE_INTERVAL", "").strip()

    if not raw_tid:
        return {
            "reconcile_interval": int(raw_intervall or "43200"),
            "reconcile_time": None,
        }

    if raw_intervall:
        log.error(
            "Både HEX_RECONCILE_INTERVAL och HEX_RECONCILE_TIME är satta. "
            "Ange antingen ett intervall eller ett klockslag – ta bort den ena."
        )
        sys.exit(1)

    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", raw_tid)
    if not m:
        log.error(
            "HEX_RECONCILE_TIME='%s' är inte ett giltigt klockslag – ange HH:MM, t.ex. 03:00.",
            raw_tid,
        )
        sys.exit(1)
    return {
        "reconcile_interval": 0,
        "reconcile_time": datetime.time(int(m.group(1)), int(m.group(2))),
    }


def load_config():
    """Laddar konfiguration från miljövariabler.

    Söker först efter en .env-fil i samma katalog som skriptet.
    Miljövariabler som redan är satta har företräde framför .env-filen.

    Stödjer två format:
    1. Nytt flerdatabas-format: HEX_DB_1_DBNAME, HEX_DB_1_HOST osv.
    2. Gammalt enkeldatabas-format: HEX_PG_DBNAME, HEX_PG_HOST osv.
    """
    # Försök ladda .env – sökvägen kan pekas ut med HEX_ENV_FILE
    env_path = resolve_env_path()
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
        # Namespace-URI-bas för GeoServer-workspaces.
        # Standard: GeoServer-URL:en (ger t.ex. http://geoserver.example.com/sk0_kba_test).
        # Sätt HEX_GS_NAMESPACE_BASE för ett eget prefix, t.ex. https://gis.min-org.se
        "gs_namespace_base": os.environ.get("HEX_GS_NAMESPACE_BASE", ""),
        # Reconnect
        "reconnect_delay": int(os.environ.get("HEX_RECONNECT_DELAY", "5")),
        # Periodisk avstämning: ANTINGEN ett intervall i sekunder
        # (HEX_RECONCILE_INTERVAL, 0 = avaktiverad) ELLER ett dagligt klockslag
        # (HEX_RECONCILE_TIME, t.ex. 03:00). Se _read_reconcile_schedule.
        **_read_reconcile_schedule(),
        # Uppstädning av föräldralösa workspaces: off | dry-run | on
        "orphan_cleanup": _read_cleanup_mode(),
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

    return config


def _parse_database_configs():
    """Parsar databaskonfigurationer från miljövariabler.

    Försöker först det nya flerdatabas-formatet (HEX_DB_N_*).
    Faller tillbaka till det gamla formatet (HEX_PG_*).
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
        dbname = os.environ.get(f"{prefix}DBNAME", "")
        if not dbname:
            continue

        databases.append({
            "host": os.environ.get(f"{prefix}HOST", default_host),
            "port": int(os.environ.get(f"{prefix}PORT", str(default_port))),
            "dbname": dbname,
            "user": os.environ.get(f"{prefix}USER", default_user),
            "password": os.environ.get(f"{prefix}PASSWORD", default_password),
        })

    return databases


def _tolka_env_varde(ravarde):
    """Tolkar värdet i en .env-rad enligt samma regler som python-dotenv.

    Reglerna är dotenv:s, inte påhittade – hela poängen med reservläsaren är
    att en .env ska betyda samma sak oavsett om python-dotenv råkar vara
    installerat på maskinen:

      värde   # kommentar   ->  "värde"      (# efter blanktecken inleder kommentar)
      lo#sen                ->  "lo#sen"     (# utan blanktecken före tillhör värdet)
      #värde                ->  "#värde"     (samma sak i början av värdet)
      "värde # här"         ->  "värde # här" (citerat värde tas ordagrant)
      slutar_med_citat"     ->  'slutar_med_citat"' (oparat citattecken behålls)

    Den gamla varianten strippade varken kommentarer eller citattecken parvis.
    Följden var att raderna SETUP.md och docs/08 visar –
    HEX_RECONCILE_INTERVAL=43200   # sekunder mellan kontroller – gav värdet
    "43200   # sekunder mellan kontroller", och int() på det avbröt uppstarten.
    """
    varde = ravarde.strip()

    # Citerat värde: allt mellan citattecknen tas ordagrant, allt efter det
    # avslutande citattecknet ignoreras.
    if varde[:1] in ('"', "'"):
        citat = varde[0]
        slut = varde.find(citat, 1)
        if slut != -1:
            return varde[1:slut]
        # Oavslutat citattecken – behandla raden som ociterad.

    # Ociterat värde: en kommentar inleds av # föregånget av blanktecken.
    return re.split(r"\s+#", varde, maxsplit=1)[0].rstrip()


def _load_env_file_fallback(env_path):
    """Enkel .env-laddare om python-dotenv inte är tillgängligt.

    Sätter bara variabler som inte redan finns i miljön, precis som
    load_dotenv(override=False).
    """
    try:
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                # "export NYCKEL=värde" är giltigt i en .env och hanteras av
                # python-dotenv. Utan det här blir nyckeln "export NYCKEL".
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                key, _, value = line.partition("=")
                key = key.strip()
                if key and key not in os.environ:
                    os.environ[key] = _tolka_env_varde(value)
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

# GeoServer-versioner som lyssnaren är verifierad mot. Intervallet anges som
# (major, minor) och är inklusivt i båda ändar. Lyssnarens REST-anrop är
# testade mot 2.28.0 och 3.0.0; 2.27 ingår eftersom regressionshanteringen av
# 404 "already exists" härrör därifrån.
GS_VERSION_TESTAD_LAGST = (2, 27)
GS_VERSION_TESTAD_HOGST = (3, 0)


def _parsa_gs_version(gs_version):
    """Plockar ut (major, minor) ur en GeoServer-versionssträng.

    Hanterar former som '2.28.0', '3.0.0', '3.1-SNAPSHOT' och '2.28-RC'.
    Returnerar None om strängen inte går att tolka (t.ex. 'okänd').
    """
    if not isinstance(gs_version, str):
        return None
    m = re.match(r"^\s*(\d+)\.(\d+)", gs_version)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)))


def _varna_om_otestad_gs_version(gs_version):
    """Loggar en varning om GeoServer-versionen ligger utanför testat intervall.

    Rent informativt – lyssnaren fortsätter alltid. Syftet är att en
    GeoServer-uppgradering ska synas direkt i loggen i stället för att visa
    sig som svårtolkade fel längre fram.
    """
    version = _parsa_gs_version(gs_version)
    if version is None:
        log.warning(
            "Kunde inte tolka GeoServer-versionen '%s' - fortsätter ändå",
            gs_version,
        )
        return

    if version < GS_VERSION_TESTAD_LAGST or version > GS_VERSION_TESTAD_HOGST:
        log.warning(
            "GeoServer %s ligger utanför det testade intervallet %d.%d-%d.%d. "
            "Lyssnaren fortsätter, men verifiera särskilt roll- och ACL-hanteringen.",
            gs_version,
            GS_VERSION_TESTAD_LAGST[0], GS_VERSION_TESTAD_LAGST[1],
            GS_VERSION_TESTAD_HOGST[0], GS_VERSION_TESTAD_HOGST[1],
        )


class GeoServerClient:
    """Klient för GeoServer REST API."""

    # Timeout i sekunder för enskilda HTTP-anrop
    REQUEST_TIMEOUT = 30

    # Retry-konfiguration för transienta fel (timeout, anslutningsfel)
    MAX_RETRIES = 3
    RETRY_BACKOFF = [2, 5, 10]  # Sekunder mellan försök

    # Tröskel i sekunder för att logga ett anrop som långsamt. Normala
    # REST-anrop mot GeoServer svarar på bråkdelar av en sekund, så allt
    # över några sekunder är värt en varning.
    LANGSAM_ANROP_SEKUNDER = 5

    def __init__(self, base_url, user, password, dry_run=False, namespace_uri_base=""):
        self.base_url = base_url.rstrip("/")
        self.rest_url = f"{self.base_url}/rest"
        self.auth = HTTPBasicAuth(user, password)
        self.dry_run = dry_run
        # Bas-URI för namespace-identifierare; standard är GeoServer-URL:en.
        self.namespace_uri_base = (namespace_uri_base or self.base_url).rstrip("/")
        self.session = requests.Session()
        self.session.auth = self.auth
        # Enbart Accept sätts sessionsbrett. Content-Type hör till kroppen och
        # sätts av requests själv för varje anrop som skickar json=, så ett
        # sessionsbrett värde skulle bara påstå att kroppslösa GET-, DELETE-
        # och POST-anrop har en JSON-kropp de inte har. GeoServer 2.28 och 3.0
        # svarar identiskt med och utan headern (verifierat mot båda), men
        # Spring blir strängare för varje version och påståendet är ändå fel.
        self.session.headers.update({
            "Accept": "application/json",
        })
        # Tidpunkt (monotont) då föregående anrop på den här sessionen
        # avslutades. Används enbart för att sätta långsamma anrop i relation
        # till hur länge sessionen stått oanvänd (se _request_with_retry).
        # Varje tråd har sin egen klient, så värdet delas aldrig mellan trådar.
        self._senaste_anrop = None

    def _logga_langsamt_anrop(self, method, url, start):
        """Varnar om ett GeoServer-anrop tog onormalt lång tid.

        Uppdaterar samtidigt tidsstämpeln för föregående anrop, så att nästa
        varning kan ange hur länge sessionen stått oanvänd. Anropas både när
        anropet lyckades och när det gav ett transient fel – ett anrop som
        hänger sig och sedan misslyckas är minst lika intressant.

        Args:
            method: HTTP-metod, för loggraden.
            url:    Anropad URL, för loggraden.
            start:  time.monotonic() taget precis före anropet.
        """
        slut = time.monotonic()
        varaktighet = slut - start
        vilotid = self._senaste_anrop
        self._senaste_anrop = slut

        if varaktighet < self.LANGSAM_ANROP_SEKUNDER:
            return

        if vilotid is None:
            paus = "sessionens första anrop"
        else:
            paus = "föregående anrop avslutades för %.0f s sedan" % (start - vilotid)

        log.warning(
            "  Långsamt GeoServer-anrop: %s %s tog %.1f s (%s)",
            method, url, varaktighet, paus,
        )

    def _request_with_retry(self, method, url, **kwargs):
        """Gör ett HTTP-anrop med retry vid transienta fel.

        Transienta fel (timeout, anslutningsfel) får upp till MAX_RETRIES
        nya försök med exponentiell backoff. Lyckade svar och HTTP-felkoder
        (4xx, 5xx) returneras direkt utan retry.

        Anrop som tar längre än LANGSAM_ANROP_SEKUNDER loggas som varning
        tillsammans med hur länge sessionen stått oanvänd. Tolkning: är det
        långsamma anropet alltid det första efter en lång paus, medan
        efterföljande anrop i samma svep går snabbt, ligger kostnaden i att
        bygga upp anslutningen och inte i anropet. Vanligaste orsaken är att
        HEX_GS_URL pekar på ett värdnamn vars första adress inte svarar
        (t.ex. 'localhost' som slår upp ::1 medan GeoServer bara lyssnar på
        IPv4) – då får varje ny anslutning vänta ut TCP-timeouten först.

        Returns:
            requests.Response
        Raises:
            requests.exceptions.ConnectionError: Om alla försök misslyckats
            requests.exceptions.Timeout: Om alla försök timeout:at
        """
        kwargs.setdefault("timeout", self.REQUEST_TIMEOUT)
        last_exc = None

        for attempt in range(1 + self.MAX_RETRIES):
            start = time.monotonic()
            try:
                resp = self.session.request(method, url, **kwargs)
                self._logga_langsamt_anrop(method, url, start)
                return resp
            except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
                self._logga_langsamt_anrop(method, url, start)
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
                _varna_om_otestad_gs_version(gs_version)
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
            self._ensure_namespace_uri(name)
            log.info("  Workspace '%s' finns redan", name)
            return True

        payload = {"workspace": {"name": name}}

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa workspace: %s", name)
            log.info("  [DRY-RUN] POST %s/workspaces", self.rest_url)
            log.info("  [DRY-RUN] Payload: %s", json.dumps(payload))
            ns_payload = {"namespace": {"prefix": name, "uri": f"{self.namespace_uri_base}/{name}"}}
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
        ns_payload = {"namespace": {"prefix": name, "uri": f"{self.namespace_uri_base}/{name}"}}
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

    # REST-resurser per lagringstyp: (URL-segment, JSON-rotnyckel, JSON-postnyckel).
    # Används av list_store_names för att inventera en workspace innan uppstädning.
    STORE_RESOURCES = {
        "datastores":     ("dataStores",     "dataStore"),
        "coveragestores": ("coverageStores", "coverageStore"),
        "wmsstores":      ("wmsStores",      "wmsStore"),
        "wmtsstores":     ("wmtsStores",     "wmtsStore"),
    }

    def list_store_names(self, workspace, store_type):
        """Listar namnen på en workspaces lagringar av en given typ.

        Args:
            workspace:  Workspace-namn.
            store_type: Nyckel i STORE_RESOURCES, t.ex. 'datastores' eller
                        'coveragestores'.

        Returns:
            Lista med namn (tom lista om inga finns), eller None om GeoServer
            inte kunde svara. None betyder "vet inte" och ska aldrig tolkas som
            "tom" av anropande kod — uppstädning måste avstå vid osäkerhet.
        """
        root_key, item_key = self.STORE_RESOURCES[store_type]
        try:
            resp = self._request_with_retry(
                "GET", f"{self.rest_url}/workspaces/{workspace}/{store_type}.json"
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            log.warning("  Kunde inte lista %s i workspace '%s': %s", store_type, workspace, e)
            return None

        # 404 = workspace eller resurstyp saknas helt; det är detsamma som tomt.
        if resp.status_code == 404:
            return []
        if resp.status_code != 200:
            log.warning(
                "  Kunde inte lista %s i workspace '%s': HTTP %d",
                store_type, workspace, resp.status_code,
            )
            return None

        try:
            payload = resp.json().get(root_key)
        except ValueError:
            log.warning("  Ogiltigt JSON-svar vid listning av %s i '%s'", store_type, workspace)
            return None

        # GeoServer serialiserar en tom samling som strängen "" i stället för {}.
        if not isinstance(payload, dict):
            return []
        entries = payload.get(item_key) or []
        return [e.get("name") for e in entries if e.get("name")]

    def get_datastore_parameters(self, workspace, store_name):
        """Hämtar en datastores connectionParameters som en dict.

        Returns:
            Dict med parametrar (t.ex. {'dbtype': 'postgis', 'host': ...}),
            eller None om datastoren inte kunde läsas.
        """
        try:
            resp = self._request_with_retry(
                "GET", f"{self.rest_url}/workspaces/{workspace}/datastores/{store_name}.json"
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            log.warning("  Kunde inte läsa datastore '%s/%s': %s", workspace, store_name, e)
            return None

        if resp.status_code != 200:
            log.warning(
                "  Kunde inte läsa datastore '%s/%s': HTTP %d",
                workspace, store_name, resp.status_code,
            )
            return None

        try:
            entries = (
                resp.json()
                .get("dataStore", {})
                .get("connectionParameters", {})
                .get("entry", [])
            )
        except ValueError:
            log.warning("  Ogiltigt JSON-svar för datastore '%s/%s'", workspace, store_name)
            return None

        return {e.get("@key"): e.get("$") for e in entries if e.get("@key")}

    def get_namespace_uri(self, name):
        """Hämtar namespace-URI för en workspace, eller None om ej hittad."""
        resp = self._request_with_retry(
            "GET", f"{self.rest_url}/namespaces/{name}.json"
        )
        if resp.status_code != 200:
            return None
        return resp.json().get("namespace", {}).get("uri")

    def _ensure_namespace_uri(self, name):
        """Verifierar och korrigerar namespace-URI för en befintlig workspace.

        Förväntat format: {self.namespace_uri_base}/{name}
        Om URI:n avviker loggas en WARNING och en PUT skickas för att korrigera.
        Fel loggas men kastas aldrig — metoden är alltid icke-fatal.
        """
        expected_uri = f"{self.namespace_uri_base}/{name}"
        current_uri = self.get_namespace_uri(name)

        if current_uri is None:
            log.warning(
                "  Kunde inte kontrollera namespace URI för workspace '%s'", name
            )
            return

        if current_uri == expected_uri:
            return

        if self.dry_run:
            log.info(
                "  [DRY-RUN] Workspace '%s': namespace URI är '%s', förväntas '%s' – skulle korrigera",
                name, current_uri, expected_uri,
            )
            return

        log.warning(
            "  Workspace '%s': namespace URI är '%s', förväntas '%s' – korrigerar...",
            name, current_uri, expected_uri,
        )
        ns_payload = {"namespace": {"prefix": name, "uri": expected_uri}}
        resp = self._request_with_retry(
            "PUT", f"{self.rest_url}/namespaces/{name}", json=ns_payload
        )
        if resp.status_code == 200:
            log.info("  Namespace URI korrigerad för '%s'", name)
        else:
            log.warning(
                "  Kunde inte korrigera namespace URI för '%s': %d %s",
                name, resp.status_code, resp.text,
            )

    # Prefix för lösenordsavtrycket i datastorens description. Se
    # _losenordsavtryck och _datastore_avvikelser.
    AVTRYCK_PREFIX = "Hex-lösenordsavtryck"

    @staticmethod
    def _losenordsavtryck(pg_user, pg_password):
        """Returnerar ett avtryck (sha256) av användare och lösenord.

        GeoServer lagrar datastorens lösenord krypterat (crypt1:/crypt2:) och
        returnerar det så via REST, så det går inte att jämföra med lösenordet
        i hex_rolluppgifter. Avtrycket skrivs därför i datastorens description
        när Hex skapar eller skriver om den, och jämförs vid nästa avstämning.

        Avtrycket röjer inte lösenordet: tjänstekontonas lösenord är 18
        slumpade byte (144 bitar), vilket inte går att gissa fram ur en hash.
        """
        data = f"{pg_user}\n{pg_password}".encode("utf-8")
        return f"{GeoServerClient.AVTRYCK_PREFIX} sha256:{hashlib.sha256(data).hexdigest()}"

    def _datastore_payload(self, workspace, store_name, host, port, dbname, schema_name,
                           pg_user, pg_password):
        """Bygger payloaden för en PostGIS-datastore (samma för POST och PUT)."""
        return {
            "dataStore": {
                "name": store_name,
                "type": "PostGIS",
                "enabled": True,
                "description": self._losenordsavtryck(pg_user, pg_password),
                "connectionParameters": {
                    # Poolinställningarna gäller per datastore och lever i
                    # GeoServers JVM, inte i lyssnaren. min connections = 0
                    # gör att en oanvänd datastore inte håller kvar någon
                    # anslutning; evictor-raderna styr hur snabbt den töms.
                    # Evictor tests per run måste vara minst max connections
                    # för att en körning ska hinna gå igenom hela poolen.
                    #
                    # Max connection idle time är 60 s. Med ett 40-tal scheman
                    # och två datastores per schema håller varje datastore som
                    # använts inom idle-tiden kvar minst en anslutning, så
                    # idle-tiden styr hur många anslutningar beståndet håller
                    # mot max_connections vid spridd, gles användning. 300 s
                    # (GeoTools standard) höll poolerna varmare men band fler
                    # anslutningar. Priset för 60 s: en ny anslutning kostar
                    # ~33 ms serverarbete mot PostgreSQL på Windows
                    # (backend-start ~27 ms plus SCRAM ~6 ms, enstaka utfall
                    # på flera hundra ms), och det blir normalfallet för lager
                    # som ses mer sällan än en gång i minuten. Evictor run
                    # periodicity är 60 s, så en oanvänd anslutning stängs
                    # inom 60-120 s.
                    #
                    # max connections är 10, inte 8. Det var golvet som fick
                    # beståndet att äta max_connections oberoende av last, och
                    # det är borta med min connections = 0. Taket styr bara hur
                    # många samtidiga frågor en enskild datastore klarar, så
                    # att sänka det köper nästan ingenting mot max_connections
                    # men gör att en kakelskur lättare slår i Connection
                    # timeout.
                    "entry": [
                        {"@key": "dbtype",                   "$": "postgis"},
                        {"@key": "namespace",                "$": f"{self.namespace_uri_base}/{workspace}"},
                        {"@key": "host",                     "$": host},
                        {"@key": "port",                     "$": str(port)},
                        {"@key": "database",                 "$": dbname},
                        {"@key": "schema",                   "$": schema_name},
                        {"@key": "user",                     "$": pg_user},
                        {"@key": "passwd",                   "$": pg_password},
                        {"@key": "Expose primary keys",      "$": "true"},
                        {"@key": "fetch size",               "$": "1000"},
                        {"@key": "Loose bbox",               "$": "true"},
                        {"@key": "Estimated extends",        "$": "true"},
                        {"@key": "encode functions",         "$": "true"},
                        {"@key": "validate connections",     "$": "true"},
                        {"@key": "max connections",          "$": "10"},
                        {"@key": "min connections",          "$": "0"},
                        {"@key": "Connection timeout",       "$": "10"},
                        {"@key": "Test while idle",          "$": "true"},
                        {"@key": "Evictor run periodicity",  "$": "60"},
                        {"@key": "Max connection idle time", "$": "60"},
                        {"@key": "Evictor tests per run",    "$": "10"},
                    ]
                },
            }
        }

    def _get_datastore(self, workspace, store_name):
        """Hämtar en befintlig datastore som dict (innehållet under 'dataStore').

        Returns:
            Dict, eller None om datastoren inte finns eller inte kunde läsas.
            None leder till POST; finns datastoren ändå faller
            create_pg_datastore tillbaka på PUT (se 'already exists' nedan).
        """
        resp = self._request_with_retry(
            "GET", f"{self.rest_url}/workspaces/{workspace}/datastores/{store_name}.json"
        )
        if resp.status_code != 200:
            return None
        try:
            ds = resp.json().get("dataStore")
        except ValueError:
            return None
        return ds if isinstance(ds, dict) else None

    @staticmethod
    def _datastore_avvikelser(befintlig, payload, pg_password):
        """Jämför en befintlig datastore mot den payload Hex skulle skriva.

        Varje PUT får GeoServer att stänga datastorens anslutningspool (mätt
        med log_connections: PUT och disconnect i samma sekund). Pågående
        frågor bryts, och nästa förfrågan får betala för en ny anslutning.
        Avstämningen skrev tidigare om varje datastore varje gång och
        återställde därmed samtliga pooler i onödan. Därför skrivs datastoren
        bara om när något faktiskt skiljer.

        Alla parametrar Hex sätter jämförs utom lösenordet, som GeoServer
        returnerar krypterat. Lösenordet räknas som lika om GeoServer ändå
        returnerar det i klartext, eller om description bär avtrycket av
        aktuell användare och lösenord. En datastore skapad innan avtrycket
        infördes saknar det och skrivs om en gång.

        Parametrar som GeoServer själv lagt till ignoreras.

        Returns:
            Lista med namnen på det som skiljer (tom lista = i synk). Värdena
            loggas aldrig, eftersom ett av dem kan vara lösenordet.
        """
        forvantad = payload["dataStore"]
        entries = (befintlig.get("connectionParameters") or {}).get("entry") or []
        if isinstance(entries, dict):
            entries = [entries]
        nuvarande = {e.get("@key"): e.get("$") for e in entries if isinstance(e, dict)}

        avvikelser = []
        if str(befintlig.get("enabled", True)).lower() != "true":
            avvikelser.append("enabled")
        for entry in forvantad["connectionParameters"]["entry"]:
            nyckel = entry["@key"]
            if nyckel == "passwd":
                continue
            if nuvarande.get(nyckel) != entry["$"]:
                avvikelser.append(nyckel)

        lagrat = nuvarande.get("passwd")
        losenord_lika = (
            lagrat in (pg_password, f"plain:{pg_password}")
            or befintlig.get("description") == forvantad["description"]
        )
        if not losenord_lika:
            avvikelser.append("passwd")
        return avvikelser

    def _update_pg_datastore(self, workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password):
        """Skriver om en befintlig PostGIS-datastore (PUT).

        Anropas bara när något skiljer (se create_pg_datastore). En PUT får
        GeoServer att kasta datastorens anslutningspool.
        """
        payload = self._datastore_payload(
            workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password
        )

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle uppdatera PG-datastore: %s", store_name)
            log.info("  [DRY-RUN] PUT %s/workspaces/%s/datastores/%s.json", self.rest_url, workspace, store_name)
            log.info("  [DRY-RUN] Användare: %s", pg_user)
            return True

        resp = self._request_with_retry(
            "PUT",
            f"{self.rest_url}/workspaces/{workspace}/datastores/{store_name}.json",
            json=payload,
        )
        if resp.status_code in (200, 201):
            log.info("  Datastore '%s' uppdaterad (användare: %s)", store_name, pg_user)
            return True
        else:
            log.error(
                "  Misslyckades att uppdatera datastore '%s': %d %s",
                store_name,
                resp.status_code,
                resp.text,
            )
            return False

    def create_pg_datastore(self, workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password):
        """Skapar en PostGIS-datastore, eller skriver om en befintlig som avviker.

        Finns datastoren jämförs den mot det Hex skulle skriva (se
        _datastore_avvikelser). Bara om något skiljer – värd, port, databas,
        schema, användare, lösenord eller poolparametrar – skickas en PUT.
        En datastore som redan är i synk lämnas orörd, så att GeoServer inte
        kastar dess anslutningspool vid varje avstämning.

        Args:
            workspace:   Workspace-namn
            store_name:  Datastore-namn (samma som schema)
            host:        PostgreSQL-host
            port:        PostgreSQL-port
            dbname:      Databasnamn
            schema_name: PostgreSQL-schemanamn att exponera
            pg_user:     PostgreSQL-användare (gs_r_-rollen för schemat)
            pg_password: Lösenord för pg_user
        """
        payload = self._datastore_payload(
            workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password
        )
        befintlig = self._get_datastore(workspace, store_name)

        if befintlig is not None:
            avvikelser = self._datastore_avvikelser(befintlig, payload, pg_password)
            if not avvikelser:
                log.info("  Datastore '%s' är i synk – lämnas orörd", store_name)
                return True
            log.info(
                "  Datastore '%s' avviker (%s) – uppdaterar",
                store_name, ", ".join(avvikelser),
            )
            return self._update_pg_datastore(workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password)

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa PG-datastore: %s", store_name)
            log.info("  [DRY-RUN] POST %s/workspaces/%s/datastores", self.rest_url, workspace)
            log.info("  [DRY-RUN] Host: %s:%d/%s, Schema: %s, Användare: %s",
                     host, port, dbname, schema_name, pg_user)
            return True

        resp = self._request_with_retry(
            "POST", f"{self.rest_url}/workspaces/{workspace}/datastores", json=payload
        )

        if resp.status_code == 201:
            log.info("  Datastore '%s' skapad (direkt PG, användare: %s)", store_name, pg_user)
            return True
        elif resp.status_code in (409, 500) and "already exists" in resp.text:
            log.warning(
                "  Datastore '%s' existerar redan men kunde inte läsas (troligen bruten konfiguration)"
                " – försöker uppdatera med nya uppgifter...",
                store_name,
            )
            return self._update_pg_datastore(
                workspace, store_name, host, port, dbname, schema_name, pg_user, pg_password
            )
        else:
            log.error(
                "  Misslyckades att skapa datastore '%s': %d %s",
                store_name,
                resp.status_code,
                resp.text,
            )
            return False

    # Statuskoder där GeoServer kan mena "rollen fanns redan" respektive
    # "rollen fanns inte", utan att svaret går att skilja från ett äkta fel.
    # GeoServer 2.x svarar 404 med orsaken i klartext ("... already exists").
    # GeoServer 3.x svarar 400 med ett generiskt meddelande som bara hänvisar
    # till serverloggen, så svarstexten går inte längre att matcha på.
    # Se _gs_role_finns för hur tvetydigheten löses.
    ROLL_TVETYDIGA_STATUSAR = (400, 404, 500)

    def list_gs_roles(self):
        """Hämtar samtliga rollnamn från GeoServers aktiva rolltjänst.

        Endpointen är '/rest/security/roles.json' och svarar {"roles": [...]}
        identiskt i 2.27, 2.28 och 3.0. (Användarhandboken anger '/rest/roles/',
        vilket ger 404 i samtliga versioner – använd inte den sökvägen. Notera
        också att avslutande snedstreck ger 404 i 3.x.)

        Returns:
            Mängd med rollnamn, eller None om GeoServer inte kunde svara.
            None betyder "vet inte" och får aldrig tolkas som "tom".
        """
        try:
            resp = self._request_with_retry(
                "GET", f"{self.rest_url}/security/roles.json"
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            log.warning("  Kunde inte hämta GeoServer-roller: %s", e)
            return None

        if resp.status_code != 200:
            log.warning(
                "  Kunde inte hämta GeoServer-roller: HTTP %d", resp.status_code
            )
            return None

        try:
            roller = resp.json().get("roles")
        except ValueError:
            log.warning("  Ogiltigt JSON-svar vid hämtning av GeoServer-roller")
            return None

        if not isinstance(roller, list):
            return None

        return {r for r in roller if isinstance(r, str)}

    def _gs_role_finns(self, role_name):
        """Kontrollerar mot GeoServer om en roll existerar.

        Används för att tolka tvetydiga felsvar från rollendpointen: i stället
        för att gissa utifrån statuskod och svarstext frågar vi GeoServer vad
        som faktiskt gäller.

        Returns:
            True om rollen finns, False om den inte finns, None om GeoServer
            inte kunde svara (då är utfallet okänt och får inte antas).
        """
        roller = self.list_gs_roles()
        if roller is None:
            return None
        return role_name in roller

    def create_gs_role(self, role_name):
        """Skapar en GeoServer-roll om den inte redan finns.

        Returnerar True om rollen skapades eller redan existerar.

        Idempotensen måste hålla över flera GeoServer-generationer eftersom
        avstämningen kör om anropet för varje publicerat schema:

          201                        Rollen skapades.
          409                        Rollen fanns redan.
          404 + "already exists"     GeoServer 2.x: rollen fanns redan.
          400 (generiskt meddelande) GeoServer 3.x: kan vara "fanns redan" –
                                     verifieras mot /security/roles.

        De tre första fallen avgörs direkt på svaret, precis som tidigare.
        Först när svaret är tvetydigt görs ett extra anrop för att kontrollera
        om rollen finns; det sker alltså aldrig i det normala flödet.
        """
        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa GeoServer-roll: %s", role_name)
            return True

        resp = self._request_with_retry(
            "POST", f"{self.rest_url}/security/roles/role/{role_name}"
        )
        if resp.status_code == 201:
            log.info("  GeoServer-roll '%s' skapad", role_name)
            return True
        elif resp.status_code == 409 or (
            resp.status_code == 404 and "already exists" in resp.text
        ):
            log.info("  GeoServer-roll '%s' finns redan - hoppar över", role_name)
            return True
        elif resp.status_code in self.ROLL_TVETYDIGA_STATUSAR and (
            self._gs_role_finns(role_name) is True
        ):
            log.info(
                "  GeoServer-roll '%s' finns redan (HTTP %d, bekräftat via"
                " /security/roles) - hoppar över",
                role_name, resp.status_code,
            )
            return True
        else:
            log.error(
                "  Misslyckades att skapa GeoServer-roll '%s': %d %s",
                role_name, resp.status_code, resp.text,
            )
            return False

    def delete_gs_role(self, role_name):
        """Tar bort en GeoServer-roll.

        Returnerar True om rollen togs bort eller inte hittades (idempotent).

        Samma versionsskillnad som i create_gs_role gäller här: en roll som
        inte finns ger 404 i GeoServer 2.x men 400 i 3.x. Ett 400-svar
        verifieras därför mot /security/roles innan det underkänns.
        """
        if self.dry_run:
            log.info("  [DRY-RUN] Skulle ta bort GeoServer-roll: %s", role_name)
            return True

        resp = self._request_with_retry(
            "DELETE", f"{self.rest_url}/security/roles/role/{role_name}"
        )
        if resp.status_code == 200:
            log.info("  GeoServer-roll '%s' borttagen", role_name)
            return True
        elif resp.status_code == 404:
            log.info("  GeoServer-roll '%s' hittades inte - inget att ta bort", role_name)
            return True
        elif resp.status_code in self.ROLL_TVETYDIGA_STATUSAR and (
            self._gs_role_finns(role_name) is False
        ):
            log.info(
                "  GeoServer-roll '%s' hittades inte (HTTP %d, bekräftat via"
                " /security/roles) - inget att ta bort",
                role_name, resp.status_code,
            )
            return True
        else:
            log.error(
                "  Misslyckades att ta bort GeoServer-roll '%s': %d %s",
                role_name, resp.status_code, resp.text,
            )
            return False

    def create_workspace_acl(self, workspace, anonymous_read=False):
        """Skapar ACL-regler för läs-workspace.

        Ger r_{workspace} läsrättighet till alla lager i workspace.
        Om anonymous_read är True läggs ROLE_ANONYMOUS till i läsregeln
        så att oautentiserade anrop tillåts (förutsätter att åtkomst
        begränsas på nätverksnivå, t.ex. IP-vitlista).

        Skrivrättigheter hanteras av skriv-workspacet (se create_write_workspace_acl).
        """
        read_role = f"r_{workspace},ROLE_ANONYMOUS" if anonymous_read else f"r_{workspace}"
        rules = {
            f"{workspace}.*.r": read_role,
        }

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa ACL-regler för läs-workspace '%s':", workspace)
            for rule, role in rules.items():
                log.info("  [DRY-RUN]   %s = %s", rule, role)
            return True

        return self._ensure_acl_rules(workspace, rules)

    def create_write_workspace_acl(self, schema_name):
        """Skapar ACL-regler för skriv-workspace ('{schema}_w').

        Ger w_{schema_name} både läs- och skrivrättighet till alla lager i
        skriv-workspacet. Det innebär att enbart användare med skrivrollen kan
        nå workspacet — WFS-T-anrop (Insert/Update/Delete) riktas dit och når
        en datastore med gs_w_{schema_name}-uppgifter (ALL-behörighet i PostgreSQL).
        """
        write_workspace = f"{schema_name}{WRITE_WORKSPACE_SUFFIX}"
        write_role = f"w_{schema_name}"
        rules = {
            f"{write_workspace}.*.r": write_role,
            f"{write_workspace}.*.w": write_role,
        }

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle skapa ACL-regler för skriv-workspace '%s':", write_workspace)
            for rule, role in rules.items():
                log.info("  [DRY-RUN]   %s = %s", rule, role)
            return True

        return self._ensure_acl_rules(write_workspace, rules)

    def delete_workspace_acl(self, workspace):
        """Tar bort ACL-regler för en workspace.

        Tar bort {workspace}.*.r och (om den finns) {workspace}.*.w.
        Returnerar True om reglerna togs bort eller inte hittades (idempotent).
        """
        rules = [f"{workspace}.*.r", f"{workspace}.*.w"]
        all_ok = True

        if self.dry_run:
            log.info("  [DRY-RUN] Skulle ta bort ACL-regler för workspace '%s':", workspace)
            for rule in rules:
                log.info("  [DRY-RUN]   %s", rule)
            return True

        for rule in rules:
            resp = self._request_with_retry(
                "DELETE", f"{self.rest_url}/security/acl/layers/{rule}"
            )
            if resp.status_code == 200:
                log.info("  ACL-regel '%s' borttagen", rule)
            elif resp.status_code == 404:
                log.info("  ACL-regel '%s' hittades inte - inget att ta bort", rule)
            else:
                log.error(
                    "  Misslyckades att ta bort ACL-regel '%s': %d %s",
                    rule, resp.status_code, resp.text,
                )
                all_ok = False

        return all_ok

    def get_acl_rules(self):
        """Hämtar alla ACL-regler för lager.

        Returnerar en dict {regelnyckeln: rollnamn} eller None vid fel.
        Exempel: {"sk0_kba_foo.*.r": "r_sk0_kba_foo", "sk0_kba_foo.*.w": "w_sk0_kba_foo"}
        """
        resp = self._request_with_retry(
            "GET", f"{self.rest_url}/security/acl/layers.json"
        )
        if resp.status_code != 200:
            return None
        return resp.json()

    @staticmethod
    def _rollmangd(varde):
        """Delar upp en ACL-regels rollista i en mängd rollnamn.

        GeoServer lagrar flera roller som en kommaseparerad sträng, men
        returnerar dem inte nödvändigtvis i den ordning de skickades in:
        'r_sk0_ext_sgu,ROLE_ANONYMOUS' kommer tillbaka som
        'ROLE_ANONYMOUS,r_sk0_ext_sgu'. Ordningen saknar betydelse för
        behörigheten, så jämförelsen måste ske på mängden — annars tror
        lyssnaren att regeln är fel vid varje avstämning och skriver om den
        i all evighet.

        None (regeln saknas) ger en tom mängd.
        """
        if not varde:
            return frozenset()
        return frozenset(
            del_.strip() for del_ in varde.split(",") if del_.strip()
        )

    def _ensure_acl_rules(self, workspace, expected_rules):
        """Verifierar och korrigerar ACL-regler mot förväntat utfall.

        Anropas av create_workspace_acl när POST returnerar 409 (minst en regel
        finns redan). Hämtar nuvarande regler via GET, jämför mot expected_rules
        och korrigerar avvikande eller saknade regler.

        Args:
            workspace:      Workspace-namn (används bara för loggning).
            expected_rules: Dict {regelnyckeln: förväntad_roll}.

        Returns:
            True om alla förväntade regler är korrekta (eller korrigerades), annars False.
        """
        all_rules = self.get_acl_rules()
        if all_rules is None:
            log.error(
                "  Kunde inte hämta ACL-regler för att verifiera workspace '%s'", workspace
            )
            return False

        all_ok = True

        for rule_key, expected_role in expected_rules.items():
            current_role = all_rules.get(rule_key)

            # Mängdjämförelse, inte strängjämförelse: GeoServer normaliserar
            # ordningen på flerrollsregler (se _rollmangd).
            if self._rollmangd(current_role) == self._rollmangd(expected_role):
                log.info("  ACL-regel '%s' är korrekt – hoppar över", rule_key)
                continue

            if current_role is not None:
                # Felaktig roll – ta bort gammal regel, skapa ny
                log.warning(
                    "  ACL-regel '%s': är '%s', förväntas '%s' – korrigerar...",
                    rule_key, current_role, expected_role,
                )
                del_resp = self._request_with_retry(
                    "DELETE", f"{self.rest_url}/security/acl/layers/{rule_key}"
                )
                if del_resp.status_code not in (200, 404):
                    log.error(
                        "  Misslyckades att ta bort felaktig ACL-regel '%s': %d %s",
                        rule_key, del_resp.status_code, del_resp.text,
                    )
                    all_ok = False
                    continue
            else:
                log.info("  ACL-regel '%s' saknas – skapar...", rule_key)

            post_resp = self._request_with_retry(
                "POST", f"{self.rest_url}/security/acl/layers",
                json={rule_key: expected_role},
            )
            if post_resp.status_code in (200, 201):
                log.info("  ACL-regel '%s' = '%s' skapad/korrigerad", rule_key, expected_role)
            else:
                log.error(
                    "  Misslyckades att skapa ACL-regel '%s': %d %s",
                    rule_key, post_resp.status_code, post_resp.text,
                )
                all_ok = False

        return all_ok


# =============================================================================
# SCHEMA HANDLER
# =============================================================================

# Suffix som läggs till schemanamnet för att bilda skriv-workspace-namnet.
# Läs-workspace: '{schema}',  skriv-workspace: '{schema}{WRITE_WORKSPACE_SUFFIX}'.
WRITE_WORKSPACE_SUFFIX = "_w"

# Regex som matchar giltiga schemanamn för GeoServer-publicering. Varje
# lyssnartråd håller sitt eget mönster i _thread_local.schema_pattern, laddat
# från sin egen databas, så att skilda publiceras_geoserver-konfigurationer i
# olika databaser inte skriver över varandra.
#
# Det finns inget hårdkodat reservmönster. Ett sådant (tidigare
# ^sk[01]_(ext|kba|sys)_) avvisade scheman med egna prefix och kategorier när
# laddningen misslyckades. Är mönstret okänt hoppar lyssnaren i stället över
# notifieringen och loggar ett fel – start- och den periodiska avstämningen
# fångar schemat när databasen svarar igen.
_thread_local = threading.local()


def _get_schema_pattern():
    """Returnerar det aktuella trådlokala mönstret, eller None om det aldrig laddats."""
    return getattr(_thread_local, "schema_pattern", None)


def _load_schema_pattern(cur):
    """Laddar schemanamnsmönstret från konfigurationstabellerna och sparar det trådlokalt.

    Bygger ett regex baserat på:
      - hex_standardiserade_skyddsnivaer WHERE publiceras_geoserver = true  → tillåtna prefix
      - hex_standardiserade_datakategorier                                  → tillåtna kategorier

    Mönstret sparas i _thread_local.schema_pattern så att varje lyssnartråd
    använder sin egen databas konfiguration utan att påverka övriga trådar.
    Om tabellerna är tomma eller ett fel uppstår behålls det befintliga mönstret
    – som är None om inget mönster laddats tidigare i tråden.
    Anropas före varje notifiering och i varje avstämning, så att mönstret hålls
    i synk med konfigurationen utan omstart av tjänsten.

    Returns:
        Det mönster som gäller efter anropet, eller None.
    """
    current = _get_schema_pattern()
    nuvarande = current.pattern if current is not None else "(inget)"
    try:
        cur.execute(
            "SELECT prefix FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE publiceras_geoserver = true ORDER BY prefix"
        )
        skyddsnivaer = [row[0] for row in cur.fetchall()]

        cur.execute(
            "SELECT prefix FROM public.hex_standardiserade_datakategorier ORDER BY prefix"
        )
        kategorier = [row[0] for row in cur.fetchall()]

        if not skyddsnivaer or not kategorier:
            log.warning(
                "Schemanamnsmönster: konfigurationstabellerna är tomma – "
                "behåller nuvarande mönster '%s'",
                nuvarande,
            )
            return current

        prefix_alts = "|".join(re.escape(p) for p in skyddsnivaer)
        kat_alts    = "|".join(re.escape(k) for k in kategorier)
        pattern = re.compile(rf"^({prefix_alts})_({kat_alts})_.+$")

        _thread_local.schema_pattern = pattern
        log.info("Schemanamnsmönster uppdaterat från DB: %s", pattern.pattern)
        return pattern

    except Exception as e:
        log.warning(
            "Kunde inte ladda schemanamnsmönster från DB: %s – "
            "behåller nuvarande mönster '%s'",
            e, nuvarande,
        )
        return current

# pg_notify-kanalnamn. Måste överensstämma med SQL-funktionerna
# hex_notifiera_gs() och hex_notifiera_gs_borttagning().
CHANNEL_SCHEMA_CREATE = "geoserver_schema"
CHANNEL_SCHEMA_DROP   = "geoserver_schema_drop"


def _db_tag(db_label):
    """Returnerar ett formaterat logg-prefix för en databas, t.ex. '[geodata_sk0] '."""
    return f"[{db_label}] " if db_label else ""


def _fetch_account_credentials(conn, schema_name, konto):
    """Hämtar autentiseringsuppgifter för GeoServers tjänstekonto för ett schema.

    Kontot slås upp via hex_geoserver_rollnamn(schema, konto), som läser
    markeringen hex_standardiserade_roller.geoserver_konto. Namnet (standard
    gs_r_/gs_w_) är alltså inte hårdkodat här, och en DBA kan döpa om
    rollmallen utan att publiceringen slutar fungera.

    Args:
        conn:        psycopg2-anslutning till databasen (AUTOCOMMIT)
        schema_name: Schemanamn (t.ex. 'sk1_kba_bygg')
        konto:       'las' eller 'skriv'

    Returns:
        (rollnamn, losenord) tuple, eller (None, None) om ej hittad.
    """
    try:
        with conn.cursor() as cur:
            try:
                cur.execute(
                    "SELECT rollnamn, losenord FROM public.hex_rolluppgifter"
                    " WHERE rollnamn = public.hex_geoserver_rollnamn(%s, %s)",
                    (schema_name, konto),
                )
            except psycopg2.errors.UndefinedFunction:
                # HEX-MIGRERING 2026-09: hex_geoserver_rollnamn() finns bara i
                # databaser som kört --upgrade med den här versionen. Lyssnaren
                # betjänar flera databaser och kan uppdateras före dem, så faller
                # den tillbaka på de gamla fasta namnen. Tas bort när samtliga
                # databaser kört --upgrade med hex_geoserver_rollnamn().
                # Förutsätter AUTOCOMMIT, annars är transaktionen avbruten här.
                prefix = {"las": "gs_r_", "skriv": "gs_w_"}[konto]
                cur.execute(
                    "SELECT rollnamn, losenord FROM public.hex_rolluppgifter"
                    " WHERE rollnamn = %s",
                    (f"{prefix}{schema_name}",),
                )
            row = cur.fetchone()
        if row:
            return row[0], row[1]
        return None, None
    except Exception as e:
        log.error(
            "Kunde inte hämta autentiseringsuppgifter för %s-kontot i '%s': %s",
            konto, schema_name, e,
        )
        return None, None


def _fetch_role_credentials(conn, schema_name):
    """Hämtar autentiseringsuppgifter för läs-tjänstekontot (standard gs_r_{schema}).

    Se _fetch_account_credentials.
    """
    return _fetch_account_credentials(conn, schema_name, "las")


def _fetch_write_role_credentials(conn, schema_name):
    """Hämtar autentiseringsuppgifter för skriv-tjänstekontot (standard gs_w_{schema}).

    Returnerar (None, None) om raden saknas — t.ex. för äldre scheman skapade
    innan skrivkontot lades till. Se _fetch_account_credentials.
    """
    return _fetch_account_credentials(conn, schema_name, "skriv")


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
    pattern = _get_schema_pattern()
    if pattern is None:
        log.error(
            "%sSchemanamnsmönstret har inte kunnat laddas från databasen – "
            "hoppar över schema '%s'. Avstämningen publicerar det när "
            "databasen svarar igen.",
            tag,
            schema_name,
        )
        return False
    if not pattern.match(schema_name):
        log.warning(
            "%sOgiltigt schemanamn '%s' - matchar inte mönster '%s'. Ignorerar.",
            tag,
            schema_name,
            pattern.pattern,
        )
        return False
    return True


def _fetch_anonymous_read(conn, schema_name):
    """Returnerar True om prefixet för schema_name har anonym_las aktiverat.

    Slår upp hex_standardiserade_skyddsnivaer.anonym_las för prefixet (första
    segmentet i schemanamnet, t.ex. 'sk0' ur 'sk0_kba_fg'). Returnerar False
    vid databasfel eller om prefixet inte hittas.
    """
    prefix = schema_name.split('_')[0]
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT anonym_las FROM public.hex_standardiserade_skyddsnivaer"
                " WHERE prefix = %s",
                (prefix,),
            )
            row = cur.fetchone()
            return bool(row[0]) if row else False
    except Exception:
        return False


def handle_schema_notification(schema_name, db_config, pg_conn, gs_client, db_label=""):
    """Hanterar en notifiering om nytt schema (kanal: CHANNEL_SCHEMA_CREATE).

    Skapar två workspaces med varsin PostGIS-datastore i GeoServer:
      - Läs-workspace  '{schema}'   med gs_r_{schema}-uppgifter (SELECT).
      - Skriv-workspace '{schema}_w' med gs_w_{schema}-uppgifter (ALL),
        som möjliggör WFS-T (Insert/Update/Delete) via rätt databasanslutning.

    Args:
        schema_name: Schemanamnet från pg_notify-payloaden
        db_config:   Databaskonfiguration med host/port/dbname
        pg_conn:     Öppen psycopg2-anslutning (används för att slå upp credentials)
        gs_client:   GeoServerClient-instans
        db_label:    Databasnamn för logg-prefix
    """
    tag = _db_tag(db_label)
    log.info("%sMottog notifiering för schema: %s", tag, schema_name)

    # Ladda om mönstret innan validering så att ändringar i
    # hex_standardiserade_skyddsnivaer (t.ex. publiceras_geoserver = true för ett
    # nytt prefix) slår igenom utan omstart av tjänsten.
    with pg_conn.cursor() as cur:
        _load_schema_pattern(cur)

    if not _validate_schema_name(schema_name, tag):
        return False

    # Hämta autentiseringsuppgifter för läs- och skriv-tjänstekontona
    r_role, r_password = _fetch_role_credentials(pg_conn, schema_name)
    if not r_role:
        log.error(
            "%sIngen autentiseringsuppgifter hittades för läskontot i schema '%s' i hex_rolluppgifter - "
            "hoppar över schema '%s'",
            tag, schema_name, schema_name,
        )
        return False
    log.info("%s  Hittade autentiseringsuppgifter för läsroll: %s", tag, r_role)

    w_role, w_password = _fetch_write_role_credentials(pg_conn, schema_name)
    if not w_role:
        log.warning(
            "%sIngen autentiseringsuppgifter hittades för skrivkontot i schema '%s' i hex_rolluppgifter - "
            "skriv-workspace utelämnas för schema '%s'",
            tag, schema_name, schema_name,
        )

    write_workspace = f"{schema_name}{WRITE_WORKSPACE_SUFFIX}"
    anonymous_read = _fetch_anonymous_read(pg_conn, schema_name)

    # 1. Skapa läs-workspace
    log.info("%s  Steg 1: Skapar läs-workspace '%s'...", tag, schema_name)
    if not gs_client.create_workspace(schema_name):
        log.error("%s  Avbryter - läs-workspace kunde inte skapas", tag)
        return False

    # 2. Skapa PostGIS-datastore med läsrollens uppgifter
    log.info("%s  Steg 2: Skapar läs-datastore '%s'...", tag, schema_name)
    if not gs_client.create_pg_datastore(
        workspace=schema_name,
        store_name=schema_name,
        host=db_config["host"],
        port=db_config["port"],
        dbname=db_config["dbname"],
        schema_name=schema_name,
        pg_user=r_role,
        pg_password=r_password,
    ):
        log.error("%s  Avbryter - läs-datastore kunde inte skapas", tag)
        return False

    # 3. Skapa skriv-workspace och skriv-datastore (kräver gs_w_-uppgifter)
    if w_role:
        log.info("%s  Steg 3: Skapar skriv-workspace '%s'...", tag, write_workspace)
        if not gs_client.create_workspace(write_workspace):
            log.error("%s  Avbryter - skriv-workspace kunde inte skapas", tag)
            return False

        log.info("%s  Steg 4: Skapar skriv-datastore '%s'...", tag, write_workspace)
        if not gs_client.create_pg_datastore(
            workspace=write_workspace,
            store_name=write_workspace,
            host=db_config["host"],
            port=db_config["port"],
            dbname=db_config["dbname"],
            schema_name=schema_name,
            pg_user=w_role,
            pg_password=w_password,
        ):
            log.error("%s  Avbryter - skriv-datastore kunde inte skapas", tag)
            return False
    else:
        log.info("%s  Steg 3-4: Hoppar över skriv-workspace (saknade gs_w_-uppgifter)", tag)

    # 5. Skapa GeoServer-roller (r_ och w_) som speglar PostgreSQL-rollerna
    log.info("%s  Steg 5: Skapar GeoServer-roller för '%s'...", tag, schema_name)
    for gs_role in (f"r_{schema_name}", f"w_{schema_name}"):
        if not gs_client.create_gs_role(gs_role):
            log.error("%s  Avbryter - GeoServer-roll '%s' kunde inte skapas", tag, gs_role)
            return False

    # 6. Skapa ACL-regler för läs-workspace (r_-rollen läser)
    log.info("%s  Steg 6: Skapar ACL-regler för läs-workspace '%s'...", tag, schema_name)
    if not gs_client.create_workspace_acl(schema_name, anonymous_read=anonymous_read):
        log.error("%s  Avbryter - ACL-regler för läs-workspace kunde inte skapas", tag)
        return False

    # 7. Skapa ACL-regler för skriv-workspace (w_-rollen läser och skriver)
    if w_role:
        log.info("%s  Steg 7: Skapar ACL-regler för skriv-workspace '%s'...", tag, write_workspace)
        if not gs_client.create_write_workspace_acl(schema_name):
            log.error("%s  Avbryter - ACL-regler för skriv-workspace kunde inte skapas", tag)
            return False
    else:
        log.info("%s  Steg 7: Hoppar över ACL för skriv-workspace (saknade gs_w_-uppgifter)", tag)

    log.info("%s  Schema '%s' publicerat till GeoServer", tag, schema_name)
    return True


def handle_schema_removal_notification(schema_name, gs_client, pg_conn=None, db_label=""):
    """Hanterar en notifiering om borttaget schema (kanal: CHANNEL_SCHEMA_DROP).

    Tar bort workspace (inkl. datastores och publicerade lager) i GeoServer.
    Samma validering som handle_schema_notification — kanalen är öppen för
    alla med NOTIFY-rättighet så schemanamnet måste kontrolleras.

    Args:
        schema_name: Schemanamnet från pg_notify-payloaden
        gs_client:   GeoServerClient-instans
        pg_conn:     Öppen psycopg2-anslutning för att ladda om schemanamnsmönstret
                     från rätt databas. Om None används nuvarande globalt mönster.
        db_label:    Databasnamn för logg-prefix
    """
    tag = _db_tag(db_label)
    log.info("%sMottog borttagningsnotifiering för schema: %s", tag, schema_name)

    # Ladda om mönstret från rätt databas så att konfigurationsändringar och
    # prefixskillnader mellan databaser (t.ex. skx bara i sk0-databasen) inte
    # gör att DROP-notifieringar avvisas p.g.a. ett inaktuellt globalt mönster.
    if pg_conn is not None:
        with pg_conn.cursor() as cur:
            _load_schema_pattern(cur)

    if not _validate_schema_name(schema_name, tag):
        return False

    write_workspace = f"{schema_name}{WRITE_WORKSPACE_SUFFIX}"

    # 1. Ta bort ACL-regler för läs-workspace innan workspace raderas
    log.info("%s  Steg 1: Tar bort ACL-regler för läs-workspace '%s'...", tag, schema_name)
    gs_client.delete_workspace_acl(schema_name)

    # 2. Ta bort ACL-regler för skriv-workspace
    log.info("%s  Steg 2: Tar bort ACL-regler för skriv-workspace '%s'...", tag, write_workspace)
    gs_client.delete_workspace_acl(write_workspace)

    # 3. Ta bort läs-workspace (kaskadraderar datastores och publicerade lager)
    log.info("%s  Steg 3: Tar bort läs-workspace '%s' från GeoServer...", tag, schema_name)
    if not gs_client.delete_workspace(schema_name):
        log.error("%s  Läs-workspace '%s' kunde inte tas bort", tag, schema_name)
        return False

    # 4. Ta bort skriv-workspace (kaskadraderar datastores och publicerade lager)
    log.info("%s  Steg 4: Tar bort skriv-workspace '%s' från GeoServer...", tag, write_workspace)
    gs_client.delete_workspace(write_workspace)

    # 5. Ta bort GeoServer-rollerna
    log.info("%s  Steg 5: Tar bort GeoServer-roller för '%s'...", tag, schema_name)
    for gs_role in (f"r_{schema_name}", f"w_{schema_name}"):
        gs_client.delete_gs_role(gs_role)

    log.info("%s  Schema '%s' avpublicerat från GeoServer", tag, schema_name)
    return True


def _fetch_publishable_schemas(db_config):
    """Hämtar mängden publicerbara schemanamn från en databas.

    Används av run_all_listeners för att bygga en samlad schema-mängd över
    alla övervakade databaser, så att startavstämningens varplansvarning
    inte slår falskt vid multi-databaskonfiguration.

    Returnerar en mängd schemanamn (tom om databasen saknar publicerbara
    scheman) eller None om databasen inte kunde läsas. Skillnaden är viktig:
    en tom mängd är ett svar, None är avsaknad av svar, och uppstädning av
    föräldralösa workspaces får aldrig köras på avsaknad av svar.
    """
    try:
        conn = psycopg2.connect(
            host=db_config["host"],
            port=db_config["port"],
            dbname=db_config["dbname"],
            user=db_config["user"],
            password=db_config["password"],
            connect_timeout=10,
            client_encoding="utf8",
        )
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT nspname"
                    " FROM pg_namespace"
                    " WHERE EXISTS ("
                    "   SELECT 1"
                    "   FROM public.hex_standardiserade_skyddsnivaer n,"
                    "        public.hex_standardiserade_datakategorier d"
                    "   WHERE n.publiceras_geoserver = true"
                    "     AND nspname ~ ('^' || n.prefix || '_' || d.prefix || '_')"
                    " )"
                )
                return {row[0] for row in cur.fetchall()}
        finally:
            conn.close()
    except Exception as e:
        log.warning(
            "Kunde inte hämta scheman från '%s' för startavstämning: %s",
            db_config["dbname"], e,
        )
        return None


def _fetch_skyddsnivaer_config(db_config):
    """Hämtar hex_standardiserade_skyddsnivaer-konfigurationen från en databas.

    Returnerar en frozenset av (prefix, publiceras_geoserver, anonym_las)-tupler,
    eller None vid anslutningsfel.  Används av run_all_listeners för att
    redovisa vilken skyddsnivåkonfiguration varje databas kör med.
    """
    try:
        conn = psycopg2.connect(
            host=db_config["host"],
            port=db_config["port"],
            dbname=db_config["dbname"],
            user=db_config["user"],
            password=db_config["password"],
            connect_timeout=10,
            client_encoding="utf8",
        )
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT prefix, publiceras_geoserver, anonym_las"
                    " FROM public.hex_standardiserade_skyddsnivaer"
                    " ORDER BY prefix"
                )
                return frozenset(cur.fetchall())
        finally:
            conn.close()
    except Exception as e:
        log.warning(
            "Kunde inte hämta skyddsnivaer-konfiguration från '%s': %s",
            db_config["dbname"], e,
        )
        return None


# =============================================================================
# FÖRÄLDRALÖSA WORKSPACES
# =============================================================================

# Klassificering av en workspace som saknar motsvarande PostgreSQL-schema.
WS_HEX     = "hex"      # Innehåller bara PostGIS-datastores mot ett övervakat schema
WS_FOREIGN = "foreign"  # Innehåller något Hex inte skapat (raster, WMS, annan databas)
WS_EMPTY   = "empty"    # Saknar lagringar helt
WS_UNKNOWN = "unknown"  # Kunde inte inventeras – GeoServer svarade inte


def _publishable_prefixes(cur, tag=""):
    """Hämtar de skyddsnivåprefix databasen publicerar till GeoServer.

    Läser hex_standardiserade_skyddsnivaer i stället för att härleda prefixen ur
    de scheman som råkar finnas. En databas som är tömd (eller nyinstallerad)
    äger fortfarande sina prefix och ska larma om workspaces som blivit kvar i
    GeoServer — härledning ur befintliga scheman gav tystnad i just det läget.

    Returnerar en mängd prefix, eller en tom mängd om frågan misslyckades.
    """
    try:
        cur.execute(
            "SELECT prefix FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE publiceras_geoserver = true"
        )
        return {row[0] for row in cur.fetchall()}
    except Exception as e:
        log.warning(
            "%sKunde inte läsa publicerbara prefix ur hex_standardiserade_skyddsnivaer: %s",
            tag, e,
        )
        return set()


def _collect_known_schemas(pg_schemas, db_config, all_db_configs, all_pg_schemas, tag=""):
    """Bygger mängden schemanamn som finns i någon övervakad databas just nu.

    Args:
        pg_schemas:     Färska scheman från denna databas (redan hämtade).
        db_config:      Denna databas konfiguration.
        all_db_configs: Samtliga övervakade databaser, eller None.
        all_pg_schemas: Startmängden från run_all_listeners (kan vara inaktuell).
        tag:            Logg-prefix.

    Returns:
        (kända scheman, complete) där complete är False om minst en annan
        övervakad databas inte kunde läsas. Vid False får ingen borttagning
        ske — ett schema kan finnas i databasen vi inte nådde.

    Startmängden all_pg_schemas byggs en gång vid uppstart och blir inaktuell
    i takt med att scheman skapas. Den läggs bara till mängden (aldrig
    ersätter den), eftersom en för stor känd-mängd bara ger färre borttagningar.
    """
    known = set(pg_schemas)
    if all_pg_schemas:
        known |= set(all_pg_schemas)

    others = [
        db for db in (all_db_configs or [])
        if (db.get("host"), db.get("port"), db.get("dbname"))
        != (db_config.get("host"), db_config.get("port"), db_config.get("dbname"))
    ]
    if not others:
        # Enkeldatabasläge: pg_schemas är färskt och fullständigt.
        return known, True

    complete = True
    for other in others:
        fetched = _fetch_publishable_schemas(other)
        if fetched is None:
            complete = False
            log.warning(
                "%sAvstämning: databasen '%s' kunde inte läsas – "
                "föräldralösa workspaces kan inte avgöras säkert denna gång",
                tag, other.get("dbname"),
            )
        else:
            known |= fetched
    return known, complete


def _classify_workspace(gs_client, ws_names, schema_name, db_targets):
    """Avgör om en föräldralös workspace är skapad av Hex och trygg att ta bort.

    En workspace räknas som Hex:s egen (WS_HEX) bara om samtliga dessa gäller
    för varje workspace-namn i ws_names:

      - Den innehåller inga coverage-, WMS- eller WMTS-lagringar. Det skyddar
        en manuell rasterpublicering vars namn råkar matcha schemamönstret.
      - Den innehåller minst en datastore.
      - Varje datastore är av typen postgis, pekar på en av de övervakade
        databaserna (host, port, databas) och exponerar exakt schema_name.

    Allt annat ger WS_FOREIGN (rör inte), WS_EMPTY (inga lagringar alls) eller
    WS_UNKNOWN (GeoServer svarade inte – vi vet inget och avstår).
    """
    saw_datastore = False

    for ws in sorted(ws_names):
        for store_type in ("coveragestores", "wmsstores", "wmtsstores"):
            names = gs_client.list_store_names(ws, store_type)
            if names is None:
                return WS_UNKNOWN, f"kunde inte lista {store_type} i '{ws}'"
            if names:
                return WS_FOREIGN, f"'{ws}' innehåller {store_type}: {', '.join(sorted(names))}"

        datastores = gs_client.list_store_names(ws, "datastores")
        if datastores is None:
            return WS_UNKNOWN, f"kunde inte lista datastores i '{ws}'"

        for store in sorted(datastores):
            params = gs_client.get_datastore_parameters(ws, store)
            if params is None:
                return WS_UNKNOWN, f"kunde inte läsa datastore '{ws}/{store}'"

            dbtype = (params.get("dbtype") or "").lower()
            if dbtype != "postgis":
                return WS_FOREIGN, (
                    f"datastore '{ws}/{store}' har dbtype "
                    f"'{dbtype or 'okänd'}', inte postgis"
                )

            target = (params.get("host"), str(params.get("port")), params.get("database"))
            if target not in db_targets:
                return WS_FOREIGN, (
                    f"datastore '{ws}/{store}' pekar på {target[0]}:{target[1]}/{target[2]} "
                    "som inte är en övervakad databas"
                )

            if params.get("schema") != schema_name:
                return WS_FOREIGN, (
                    f"datastore '{ws}/{store}' exponerar schemat "
                    f"'{params.get('schema')}', inte '{schema_name}'"
                )
            saw_datastore = True

    if not saw_datastore:
        return WS_EMPTY, "inga lagringar alls"
    return WS_HEX, "endast PostGIS-datastores mot det saknade schemat"


def _handle_orphan_workspace(schema_name, ws_names, gs_client, pg_conn, db_targets,
                             cleanup_mode, verification_complete, db_label="", tag=""):
    """Varnar om — och städar eventuellt bort — en föräldralös workspace.

    Args:
        schema_name:           Schemat som saknas i samtliga övervakade databaser.
        ws_names:              Workspace-namn som hör till schemat ('X' och 'X_w').
        gs_client:             GeoServerClient-instans.
        pg_conn:               PG-anslutning (används av borttagningsflödet).
        db_targets:            Mängd (host, port, dbnamn) för övervakade databaser.
        cleanup_mode:          CLEANUP_OFF | CLEANUP_DRY_RUN | CLEANUP_ON.
        verification_complete: False om någon övervakad databas inte kunde läsas.
        db_label, tag:         Loggetiketter.
    """
    namn = ", ".join(sorted(ws_names))

    if cleanup_mode == CLEANUP_OFF:
        log.warning(
            "%sAvstämning: workspace %s finns i GeoServer men PG-schemat '%s' "
            "saknas i samtliga övervakade databaser – kräver manuell DBA-granskning "
            "(sätt HEX_ORPHAN_CLEANUP=dry-run för att se vad en uppstädning skulle göra)",
            tag, namn, schema_name,
        )
        return

    if not verification_complete:
        log.warning(
            "%sAvstämning: workspace %s ser föräldralös ut men minst en övervakad "
            "databas kunde inte läsas – ingen uppstädning görs denna gång",
            tag, namn,
        )
        return

    verdict, reason = _classify_workspace(gs_client, ws_names, schema_name, db_targets)

    if verdict == WS_UNKNOWN:
        log.warning(
            "%sAvstämning: workspace %s kunde inte inventeras (%s) – lämnas orörd",
            tag, namn, reason,
        )
        return

    if verdict == WS_FOREIGN:
        log.warning(
            "%sAvstämning: workspace %s matchar schemamönstret men %s – "
            "lämnas orörd, Hex städar bara det Hex har skapat",
            tag, namn, reason,
        )
        return

    if verdict == WS_EMPTY:
        log.warning(
            "%sAvstämning: workspace %s saknar PG-schema och har %s – "
            "lämnas orörd, kräver manuell DBA-granskning",
            tag, namn, reason,
        )
        return

    if cleanup_mode == CLEANUP_DRY_RUN:
        log.warning(
            "%sAvstämning [DRY-RUN]: skulle ta bort workspace %s "
            "(PG-schemat '%s' saknas, %s). Sätt HEX_ORPHAN_CLEANUP=on för skarp körning.",
            tag, namn, schema_name, reason,
        )
        return

    log.warning(
        "%sAvstämning: tar bort föräldralös workspace %s – PG-schemat '%s' saknas i "
        "samtliga övervakade databaser (%s)",
        tag, namn, schema_name, reason,
    )
    if handle_schema_removal_notification(schema_name, gs_client, pg_conn=pg_conn, db_label=db_label):
        log.info("%sAvstämning: workspace %s borttagen", tag, namn)
    else:
        log.error("%sAvstämning: workspace %s kunde inte tas bort", tag, namn)


def _reconcile_geoserver_schemas(cur, db_config, gs_client, db_label="", all_pg_schemas=None,
                                 all_db_configs=None, cleanup_mode=CLEANUP_OFF):
    """Avstämning: skapar saknade GeoServer-workspaces och datastores för befintliga PG-scheman.

    Körs vid varje (åter)anslutning och periodiskt (se Avstamningsschema), båda
    gångerna i lyssnartråden på LISTEN-anslutningens cursor, så att ingen extra
    PG-anslutning öppnas för den egna databasen.

    Args:
        cur:            Öppen psycopg2-cursor (autocommit OK)
        db_config:      Databaskonfiguration för denna databas
        gs_client:      GeoServerClient-instans
        db_label:       Logg-prefix
        all_pg_schemas: Samlad mängd scheman från ALLA övervakade databaser,
                        förbyggd av run_all_listeners vid uppstart. Används som
                        säkerhetsnät i orphan-kontrollen. Om None används endast
                        denna databas scheman.
        all_db_configs: Samtliga övervakade databaser. Används för att läsa om
                        schemamängden färskt vid varje avstämning (startmängden
                        blir inaktuell) och för att avgöra vilka datastores som
                        pekar på en övervakad databas. Om None antas enkeldatabas.
        cleanup_mode:   CLEANUP_OFF (endast varning), CLEANUP_DRY_RUN (loggar vad
                        som skulle tas bort) eller CLEANUP_ON (tar bort).

    Logik:
      a) Hämtar publicerbara scheman från denna databas (pg_namespace).
      b) Hämtar befintliga workspaces via GeoServer REST GET /rest/workspaces.json.
      c) Kör handle_schema_notification för ALLA PG-scheman (inte bara saknade).
         Saknade workspaces och datastores skapas. Befintliga datastores
         skrivs om bara om de avviker från hex_rolluppgifter och Hex
         standardparametrar (se GeoServerClient._datastore_avvikelser).
      d) Loggar INFO för varje nyskapad workspace.
      e) Varnar för varje GeoServer-workspace som saknar PG-schema i SAMTLIGA
         övervakade databaser, och tar bort den om cleanup_mode tillåter det
         OCH workspacen bevisligen är skapad av Hex (se _classify_workspace).
      f) Alla fel loggas; funktionen avbryter aldrig LISTEN-loopen.

    Returns:
        True om avstämningen gick igenom, False om den avbröts (GeoServer eller
        databasen svarade inte). Vid False försöker Avstamningsschema igen
        inom några minuter i stället för att vänta ett helt intervall.
    """
    tag = _db_tag(db_label)
    log.info("%sStartavstämning: kontrollerar GeoServer mot PostgreSQL-scheman...", tag)

    try:
        # a) Hämta publicerbara scheman från PostgreSQL – styrt av konfigurationstabellerna
        cur.execute(
            "SELECT nspname"
            " FROM pg_namespace"
            " WHERE EXISTS ("
            "   SELECT 1"
            "   FROM public.hex_standardiserade_skyddsnivaer n,"
            "        public.hex_standardiserade_datakategorier d"
            "   WHERE n.publiceras_geoserver = true"
            "     AND nspname ~ ('^' || n.prefix || '_' || d.prefix || '_')"
            " )"
            " ORDER BY nspname"
        )
        pg_schemas = {row[0] for row in cur.fetchall()}
        log.info(
            "%sStartavstämning: %d PG-schema(n) matchade mönstret",
            tag, len(pg_schemas),
        )

        # b) Hämta befintliga workspaces från GeoServer
        try:
            resp = gs_client._request_with_retry(
                "GET", f"{gs_client.rest_url}/workspaces.json"
            )
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            log.error(
                "%sStartavstämning: GeoServer är inte tillgänglig (%s) – "
                "hoppar över startavstämning och fortsätter till LISTEN-loopen",
                tag, e,
            )
            return False

        if resp.status_code != 200:
            log.error(
                "%sStartavstämning: GeoServer svarade %d vid hämtning av workspaces – "
                "hoppar över startavstämning",
                tag, resp.status_code,
            )
            return False

        ws_data = resp.json().get("workspaces") or {}
        gs_workspaces = {ws["name"] for ws in ws_data.get("workspace", [])}
        log.info(
            "%sStartavstämning: %d workspace(s) hittades i GeoServer",
            tag, len(gs_workspaces),
        )

        # c) Alla scheman: skapa det som saknas och rätta det som avviker.
        #    handle_schema_notification är idempotent: en datastore som redan
        #    stämmer med hex_rolluppgifter skrivs inte om. En PUT får GeoServer
        #    att stänga datastorens anslutningspool, så att skriva om allt vid
        #    varje avstämning återställde samtliga pooler i onödan.
        missing_in_gs = pg_schemas - gs_workspaces
        for schema_name in sorted(pg_schemas):
            try:
                ok = handle_schema_notification(
                    schema_name,
                    db_config,
                    cur.connection,
                    gs_client,
                    db_label=db_label,
                )
                # d) Logga nyligen skapade workspaces (befintliga uppdateras tyst)
                if ok and schema_name in missing_in_gs:
                    log.info(
                        "%sStartavstämning: skapat saknat GeoServer-workspace '%s'",
                        tag, schema_name,
                    )
            except Exception as e:
                log.error(
                    "%sStartavstämning: fel vid hantering av workspace '%s': %s",
                    tag, schema_name, e,
                )

        # e) Workspaces i GeoServer utan motsvarande PG-schema.
        #    Kända scheman läses färskt från samtliga övervakade databaser – den
        #    förbyggda startmängden blir inaktuell så fort ett schema skapas.
        known_schemas, verification_complete = _collect_known_schemas(
            pg_schemas, db_config, all_db_configs, all_pg_schemas, tag
        )

        #    I multi-DB-läge begränsas kontrollen till de prefix denna databas
        #    publicerar, så att varje tråd rapporterar sina egna workspaces.
        #    Prefixen läses ur konfigurationen (hex_standardiserade_skyddsnivaer),
        #    inte ur befintliga scheman: en tömd databas äger fortfarande sina
        #    prefix och måste kunna larma om kvarlämnade workspaces.
        own_prefixes = None
        if all_db_configs and len(all_db_configs) > 1:
            own_prefixes = _publishable_prefixes(cur, tag) or {
                name.split("_")[0] for name in pg_schemas
            }

        #    Gruppera per schema: läs-workspacen '<schema>' och skriv-workspacen
        #    '<schema>_w' hör ihop och ska bedömas och städas som en enhet.
        #    Mönstret laddas av anroparen (listen_loop) från samma databas.
        _pattern = _get_schema_pattern()
        orphans = {}
        if _pattern is None:
            log.warning(
                "%sStartavstämning: schemanamnsmönstret är okänt – hoppar över "
                "kontrollen av workspaces utan PG-schema",
                tag,
            )
        for ws in (gs_workspaces if _pattern is not None else ()):
            if ws in known_schemas:
                continue                      # workspacen har ett levande schema
            if ws.endswith(WRITE_WORKSPACE_SUFFIX):
                base = ws[: -len(WRITE_WORKSPACE_SUFFIX)]
                if base in known_schemas:
                    continue                  # skriv-workspace till ett levande schema
            else:
                base = ws
            if not _pattern.match(base):
                continue                      # inte ett Hex-schemanamn – rör inte
            if own_prefixes is not None and base.split("_")[0] not in own_prefixes:
                continue                      # en annan databas prefix
            orphans.setdefault(base, set()).add(ws)

        db_targets = {
            (db["host"], str(db["port"]), db["dbname"])
            for db in (all_db_configs or [db_config])
        }
        for schema_name in sorted(orphans):
            try:
                _handle_orphan_workspace(
                    schema_name,
                    orphans[schema_name],
                    gs_client,
                    cur.connection,
                    db_targets,
                    cleanup_mode,
                    verification_complete,
                    db_label=db_label,
                    tag=tag,
                )
            except Exception as e:
                log.error(
                    "%sAvstämning: fel vid hantering av föräldralös workspace '%s': %s",
                    tag, schema_name, e,
                )

        if not missing_in_gs and not orphans:
            log.info("%sStartavstämning: GeoServer och PostgreSQL är i synk", tag)
        return True

    except Exception as e:
        # f) Startavstämning får aldrig avbryta uppstarten
        log.error(
            "%sStartavstämning misslyckades oväntat: %s – "
            "fortsätter till LISTEN-loopen",
            tag, e,
        )
        return False


# =============================================================================
# POSTGRESQL LISTENER
# =============================================================================

# Hur länge listen_loop väntar på en notifiering innan den skickar keepalive
# och kontrollerar stop_event och avstämningsschemat.
LISTEN_TIMEOUT_SEKUNDER = 5

class Avstamningsschema:
    """Avgör när den periodiska avstämningen ska köras.

    Två lägen, varav högst ett är aktivt:

      - Intervall (HEX_RECONCILE_INTERVAL): nästa körning ligger ett intervall
        efter den senaste, inklusive avstämningen vid (åter)anslutning.
      - Klockslag (HEX_RECONCILE_TIME): en körning per dygn vid det lokala
        klockslaget. Tiden räknas om mot väggklockan inför varje körning, så
        den glider inte med körningarnas längd eller tjänstens starttid, och
        sommartidsbyten hanteras av operativsystemets tidszon.

    Avstämningen körs i lyssnartråden på LISTEN-anslutningen (se listen_loop).
    Den behöver alltså ingen egen anslutning och fungerar även när PostgreSQL
    har fyllt max_connections. Misslyckas en körning ändå (t.ex. GeoServer
    svarar inte) görs ett nytt försök efter OMFORSOK_SEKUNDER i stället för
    att vänta ett helt intervall eller dygn.
    """

    OMFORSOK_SEKUNDER = 300

    def __init__(self, intervall=0, klockslag=None, klocka=None):
        """
        Args:
            intervall: Sekunder mellan körningar (0 = intervalläget av).
            klockslag: datetime.time för daglig körning, eller None.
                       Har företräde framför intervall.
            klocka:    Funktion som returnerar aktuell tid som tidszonsmedveten
                       datetime. Bara för tester.
        """
        self.klockslag = klockslag
        self.intervall = 0 if klockslag is not None else max(0, intervall or 0)
        self._klocka = klocka or (lambda: datetime.datetime.now().astimezone())
        self._nasta = None

    @property
    def aktiv(self):
        return self.klockslag is not None or self.intervall > 0

    def beskrivning(self):
        if self.klockslag is not None:
            return f"dagligen kl. {self.klockslag.strftime('%H:%M')} (lokal tid)"
        if self.intervall > 0:
            return f"var {self.intervall:g} sekund ({self.intervall / 60:.0f} min)"
        return "avaktiverad"

    def _nasta_klockslag(self, nu):
        """Nästa tillfälle för klockslaget, strikt efter nu, i lokal tid."""
        dag = nu.date()
        while True:
            # astimezone() på en naiv datetime tolkar den som lokal tid med
            # den förskjutning som gäller just den dagen (sommar/vinter).
            kandidat = datetime.datetime.combine(dag, self.klockslag).astimezone()
            if kandidat > nu:
                return kandidat
            dag += datetime.timedelta(days=1)

    def efter_korning(self, lyckad):
        """Planerar nästa körning efter en avstämning (lyckad eller inte)."""
        if not self.aktiv:
            return
        nu = self._klocka()
        if not lyckad:
            vanta = self.OMFORSOK_SEKUNDER
            if self.intervall > 0:
                vanta = min(vanta, self.intervall)
            self._nasta = nu + datetime.timedelta(seconds=vanta)
        elif self.klockslag is not None:
            self._nasta = self._nasta_klockslag(nu)
        else:
            self._nasta = nu + datetime.timedelta(seconds=self.intervall)

    def ar_dags(self):
        return self.aktiv and self._nasta is not None and self._klocka() >= self._nasta

    @property
    def nasta(self):
        return self._nasta


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

def listen_loop(db_config, reconnect_delay, gs_client, stop_event=None, notifier=None,
                all_pg_schemas=None, reconcile_interval=0, all_db_configs=None,
                cleanup_mode=CLEANUP_OFF, reconcile_time=None):
    """Huvudloop som lyssnar på pg_notify och hanterar notifieringar för en databas.

    Args:
        db_config:          Databaskonfiguration med host, port, dbname, user, password
        reconnect_delay:    Sekunder att vänta innan återanslutning
        gs_client:          GeoServerClient-instans
        stop_event:         threading.Event som signalerar att loopen ska avslutas
                            (används av Windows-tjänsten för graceful shutdown)
        notifier:           EmailNotifier-instans (eller None om e-post ej konfigurerats)
        all_pg_schemas:     Samlad schema-mängd från alla övervakade databaser,
                            förbyggd av run_all_listeners för korrekt orphan-kontroll.
        reconcile_interval: Sekunder mellan periodiska avstämningar (0 = avaktiverat).
        all_db_configs:     Samtliga övervakade databaser (se _reconcile_geoserver_schemas).
        cleanup_mode:       Uppstädningsläge för föräldralösa workspaces.
        reconcile_time:     datetime.time för daglig avstämning, eller None.
                            Ersätter reconcile_interval när det är satt.
    """
    db_label = db_config["dbname"]
    was_disconnected = False  # Sparar om vi tappat anslutning för återhämtningsnotifiering

    if stop_event is None:
        stop_event = threading.Event()

    # Den periodiska avstämningen körs här i lyssnartråden, på LISTEN-
    # anslutningen, i stället för i en egen tråd med egen anslutning. Den egna
    # anslutningen gick inte att öppna när PostgreSQL hade fyllt
    # max_connections, och då väntade tråden ett helt intervall innan nästa
    # försök. Notifieringar som kommer under avstämningen köas av PostgreSQL
    # och hanteras direkt efteråt, precis som vid avstämningen vid anslutning.
    schema = Avstamningsschema(reconcile_interval, reconcile_time)
    if schema.aktiv:
        log.info("[%s] Periodisk avstämning: %s.", db_label, schema.beskrivning())

    def avstam(cur):
        ok = _reconcile_geoserver_schemas(
            cur, db_config, gs_client, db_label, all_pg_schemas,
            all_db_configs=all_db_configs, cleanup_mode=cleanup_mode,
        )
        schema.efter_korning(ok)
        if schema.nasta is not None:
            log.info(
                "[%s] Nästa periodiska avstämning: %s",
                db_label, schema.nasta.strftime("%Y-%m-%d %H:%M"),
            )

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
                connect_timeout=10,
                client_encoding="utf8",
            )
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

            cur = conn.cursor()
            cur.execute(f"LISTEN {CHANNEL_SCHEMA_CREATE};")
            cur.execute(f"LISTEN {CHANNEL_SCHEMA_DROP};")
            log.info("[%s] Lyssnar på kanaler '%s' och '%s'...",
                     db_label, CHANNEL_SCHEMA_CREATE, CHANNEL_SCHEMA_DROP)
            log.info("[%s] Väntar på schema-händelser...", db_label)

            # Ladda schemanamnsmönster från konfigurationstabellerna
            _load_schema_pattern(cur)

            # Startavstämning – körs vid varje (åter)anslutning för att fånga upp
            # scheman som skapades medan lyssnaren var nere.
            avstam(cur)

            # Skicka återhämtningsnotifiering om vi tappat anslutning tidigare
            if was_disconnected:
                if notifier:
                    notifier.notify_pg_reconnected(db_label)
                was_disconnected = False

            while not (stop_event and stop_event.is_set()):
                if schema.ar_dags():
                    log.info("[%s] Periodisk avstämning: startar kontroll...", db_label)
                    # Ladda om mönstret så att ändrad konfiguration slår igenom.
                    _load_schema_pattern(cur)
                    avstam(cur)

                # Vänta på notifiering med kort timeout så att stop_event och
                # schemat för den periodiska avstämningen kontrolleras regelbundet
                if select.select([conn], [], [], LISTEN_TIMEOUT_SEKUNDER) == ([], [], []):
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
                            ok = handle_schema_removal_notification(
                                schema_name,
                                gs_client,
                                pg_conn=conn,
                                db_label=db_label,
                            )
                        else:
                            ok = handle_schema_notification(
                                schema_name,
                                db_config,
                                conn,
                                gs_client,
                                db_label=db_label,
                            )
                        if not ok:
                            log.warning(
                                "[%s] Hantering av schema '%s' misslyckades - "
                                "se tidigare loggposter för detaljer",
                                db_label, schema_name,
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
    cleanup_mode = config.get("orphan_cleanup", CLEANUP_OFF)
    if cleanup_mode == CLEANUP_ON:
        log.info(
            "Uppstädning av föräldralösa workspaces: PÅ – workspaces som bara "
            "innehåller PostGIS-datastores mot ett saknat schema tas bort automatiskt."
        )
    elif cleanup_mode == CLEANUP_DRY_RUN:
        log.info(
            "Uppstädning av föräldralösa workspaces: DRY-RUN – loggar vad som "
            "skulle tas bort, tar inte bort något."
        )

    # Bygg en samlad schema-mängd över alla databaser för korrekt orphan-kontroll
    # i startavstämningen. Varje enskild databas-tråd jämför annars bara mot sina
    # egna scheman och larmar falskt om workspaces som tillhör en annan databas.
    all_pg_schemas = set()
    for db_config in databases:
        fetched = _fetch_publishable_schemas(db_config)
        if fetched:
            all_pg_schemas |= fetched

    # Redovisa hex_standardiserade_skyddsnivaer per databas vid start.
    #
    # Varje skyddsniva har sin egen databas och sin egen lyssnartråd, och varje
    # tråd använder sin egen databas konfiguration (via _thread_local). Att
    # konfigurationerna skiljer sig åt är alltså designat, inte ett fel — det är
    # hela poängen med uppdelningen. Raden är därför en inventering av vad som
    # faktiskt gäller per databas, inte en avvikelsekontroll.
    if len(databases) > 1:
        skyddsnivaer_per_db = {
            db["dbname"]: _fetch_skyddsnivaer_config(db) for db in databases
        }
        for db_name, cfg in skyddsnivaer_per_db.items():
            if cfg is None:
                continue
            log.info(
                "Skyddsnivåer i %s: %s",
                db_name,
                ", ".join(
                    f"{prefix}(geoserver={pub}, anonym={anon})"
                    for prefix, pub, anon in sorted(cfg)
                ),
            )

    if len(databases) == 1:
        # En databas - kör direkt utan extra tråd
        gs_client = GeoServerClient(
            base_url=config["gs_url"],
            user=config["gs_user"],
            password=config["gs_password"],
            dry_run=dry_run,
            namespace_uri_base=config.get("gs_namespace_base", ""),
        )
        listen_loop(
            databases[0], config["reconnect_delay"], gs_client, stop_event, notifier,
            all_pg_schemas, config.get("reconcile_interval", 0),
            all_db_configs=databases, cleanup_mode=cleanup_mode,
            reconcile_time=config.get("reconcile_time"),
        )
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
            namespace_uri_base=config.get("gs_namespace_base", ""),
        )
        t = threading.Thread(
            target=listen_loop,
            args=(db_config, config["reconnect_delay"], gs_client, stop_event, notifier, all_pg_schemas, config.get("reconcile_interval", 0)),
            kwargs={"all_db_configs": databases, "cleanup_mode": cleanup_mode,
                    "reconcile_time": config.get("reconcile_time")},
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
    log.info("Anslutning: direkt PostGIS (autentiseringsuppgifter från hex_rolluppgifter)")
    log.info("Databaser:  %d st", len(config["databases"]))
    for db in config["databases"]:
        log.info("  [%s] %s@%s:%d/%s",
                 db["dbname"], db["user"], db["host"], db["port"], db["dbname"])
    log.info("Uppstädning: %s (HEX_ORPHAN_CLEANUP)", config["orphan_cleanup"])
    log.info("Avstämning: %s", Avstamningsschema(
        config["reconcile_interval"], config["reconcile_time"]).beskrivning())
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
        namespace_uri_base=config.get("gs_namespace_base", ""),
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
