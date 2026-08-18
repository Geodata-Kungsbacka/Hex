#!/usr/bin/env python3
"""
Hex Installer - kör SQL-filer i beroendeordning
Användning:
    python install_hex.py              # Installera alla konfigurerade databaser
    python install_hex.py --upgrade    # Uppgradera (bevarar inställningar, avinstallerar och installerar om)
    python install_hex.py --uninstall  # Ta bort alla Hex-objekt från alla databaser
"""

import argparse
import psycopg2
from psycopg2 import sql as pgsql
from pathlib import Path

# =============================================================================
# CONFIGURATION
# =============================================================================

# Lista med databaser att installera Hex i.
# OBS - anslutningen måste köras som postgres för att skapa event-triggers.
#
# Varje post är ett dict med psycopg2-anslutningsparametrar plus:
#   owner_role: ägarroll för alla skapade objekt (typer, tabeller, funktioner, triggers)
#               Saknas rollen skapar installern den som NOLOGIN utan lösenord.
#               Sätt till None för att använda den anslutande användaren som ägare.
#
# Exempel för tre sk-databaser:
# DATABASES = [
#     {"host": "localhost", "port": 5432, "dbname": "geodata_sk0", "user": "postgres", "password": "...", "owner_role": "gis_admin"},
#     {"host": "localhost", "port": 5432, "dbname": "geodata_sk1", "user": "postgres", "password": "...", "owner_role": "gis_admin"},
#     {"host": "localhost", "port": 5432, "dbname": "geodata_sk2", "user": "postgres", "password": "...", "owner_role": "gis_admin"},
# ]

DATABASES = [
    {
        "host": "localhost",       # Använd "127.0.0.1" på Windows Server
        "port": 5432,
        "dbname": "geodata",       # Databas att installera Hex i
        "user": "postgres",
        "password": "losenord_har",
        "owner_role": "gis_admin", # Ägarroll för Hex-objekt, skapas om den saknas
    },
]

# =============================================================================
# INSTALL ORDER
# =============================================================================

INSTALL_ORDER = [
    # Konfiguration
    "src/sql/00_config/hex_geoserver_roller.sql",
    # Typer
    "src/sql/01_types/hex_geom_info.sql",
    "src/sql/01_types/hex_kolumnkonfig.sql",
    "src/sql/01_types/hex_kolumnegenskaper.sql",
    "src/sql/01_types/hex_tabellregler.sql",
    # Tabeller
    "src/sql/02_tables/hex_standardiserade_skyddsnivaer.sql",
    # hex_schema_regex() läser hex_standardiserade_skyddsnivaer – måste skapas efter tabellen
    "src/sql/00_config/hex_schema_regex.sql",
    "src/sql/02_tables/hex_standardiserade_datakategorier.sql",
    "src/sql/02_tables/hex_standardiserade_kolumner.sql",
    "src/sql/02_tables/hex_standardiserade_roller.sql",
    "src/sql/02_tables/hex_metadata.sql",
    "src/sql/02_tables/hex_systemanvandare.sql",
    "src/sql/02_tables/hex_grupprattigheter.sql",
    "src/sql/02_tables/hex_afvaktande_geometri.sql",
    "src/sql/02_tables/hex_dummy_geometrier.sql",
    "src/sql/02_tables/hex_avvikande_srid.sql",
    "src/sql/02_tables/hex_rolluppgifter.sql",
    # Funktioner - Struktur
    "src/sql/03_functions/01_structure/hex_hamta_geometri_definition.sql",
    "src/sql/03_functions/01_structure/hex_hamta_kolumnstandard.sql",
    # Funktioner - Validering
    "src/sql/03_functions/02_validation/hex_validera_tabell.sql",
    "src/sql/03_functions/02_validation/hex_validera_vynamn.sql",
    "src/sql/03_functions/02_validation/hex_validera_schemanamn.sql",
    "src/sql/03_functions/02_validation/hex_blockera_schema_namnbyte.sql",
    "src/sql/03_functions/02_validation/hex_validera_geometri.sql",
    "src/sql/03_functions/02_validation/hex_forklara_geometrifel.sql",
    # Funktioner - Regler
    "src/sql/03_functions/03_rules/hex_spara_tabellregler.sql",
    "src/sql/03_functions/03_rules/hex_spara_kolumnegenskaper.sql",
    "src/sql/03_functions/03_rules/hex_aterskapa_tabellregler.sql",
    "src/sql/03_functions/03_rules/hex_aterskapa_kolumnegenskaper.sql",
    # Funktioner - Verktyg
    "src/sql/03_functions/04_utility/hex_byt_ut_tabell.sql",
    "src/sql/03_functions/04_utility/hex_uppdatera_sekvensnamn.sql",
    "src/sql/03_functions/04_utility/hex_skapa_historik_qa.sql",
    "src/sql/03_functions/04_utility/hex_aterskapa_qa_trigger.sql",
    "src/sql/03_functions/04_utility/hex_tilldela_rollrattigheter.sql",
    "src/sql/03_functions/04_utility/hex_tillampa_grupprattigheter.sql",
    "src/sql/03_functions/04_utility/hex_tvinga_gid_fran_sekvens.sql",
    "src/sql/03_functions/04_utility/hex_underhall.sql",
    # Funktioner - Triggerfunktioner
    "src/sql/03_functions/05_trigger_functions/hex_ta_bort_dummy_rad.sql",
    "src/sql/03_functions/04_utility/hex_lagg_till_dummy_geometri.sql",
    "src/sql/03_functions/05_trigger_functions/hex_kontrollera_geometri.sql",
    "src/sql/03_functions/05_trigger_functions/hex_hantera_ny_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/hex_hantera_ny_kolumn.sql",
    "src/sql/03_functions/05_trigger_functions/hex_hantera_ny_vy.sql",
    "src/sql/03_functions/05_trigger_functions/hex_ta_bort_schemaroller.sql",
    "src/sql/03_functions/05_trigger_functions/hex_hantera_std_roller.sql",
    "src/sql/03_functions/05_trigger_functions/hex_hantera_borttagen_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/hex_notifiera_gs.sql",
    "src/sql/03_functions/05_trigger_functions/hex_notifiera_gs_borttagning.sql",
    # Triggers
    "src/sql/04_triggers/hex_hantera_ny_tabell_trigger.sql",
    "src/sql/04_triggers/hex_hantera_ny_kolumn_trigger.sql",
    "src/sql/04_triggers/hex_hantera_ny_vy_trigger.sql",
    "src/sql/04_triggers/hex_ta_bort_schemaroller_trigger.sql",
    "src/sql/04_triggers/hex_hantera_std_roller_trigger.sql",
    "src/sql/04_triggers/hex_hantera_borttagen_tabell_trigger.sql",
    "src/sql/04_triggers/hex_validera_schemanamn_trigger.sql",
    "src/sql/04_triggers/hex_blockera_schema_namnbyte_trigger.sql",
    "src/sql/04_triggers/hex_notifiera_gs_trigger.sql",
    "src/sql/04_triggers/hex_notifiera_gs_borttagning_trigger.sql",
]

# =============================================================================
# AVINSTALLATION - omvänd ordning, DROP-satser
# =============================================================================

# -----------------------------------------------------------------------------
# ÄRVDA OBJEKT - namn från tiden före hex_-prefixet
#
# Databaser som installerades före namnbytet till hex_-prefix bär kvar objekt
# under sina gamla namn. DROP-satserna nedan nämner bara de nya namnen, så de
# gamla överlever både avinstallation och uppgradering.
#
# Kvarlämnade event-triggers är inte bara skräp - de är aktiva. En gammal
# hantera_ny_tabell() avfyras på CREATE TABLE under installationen och slår
# mot public.hex_systemanvandare innan tabellen hunnit skapas, vilket avbryter
# hela transaktionen med "relationen public.hex_systemanvandare existerar inte".
# Därför droppas event-triggarna först, separat från övriga ärvda objekt.
# -----------------------------------------------------------------------------

LEGACY_EVENT_TRIGGERS_SQL = """
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_borttagning_trigger;
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_trigger;
DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS blockera_schema_namnbyte_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger;
-- Mellansteg under namnbytet: tabellen hade fått hex_-prefix men inte funktionen.
DROP EVENT TRIGGER IF EXISTS hantera_hex_standardiserade_roller_trigger;
DROP EVENT TRIGGER IF EXISTS ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_borttagen_tabell_trigger;
"""

# Övriga ärvda objekt. Droppas bara vid avinstallation/uppgradering - en ren
# installation rör dem inte, eftersom tabellerna kan innehålla anpassad data
# som användaren inte bett oss kasta.
#
# CASCADE på triggerfunktionerna tar med sig de radtriggers de skapat på
# användartabeller. Utan det blir gamla och nya triggers kvar sida vid sida.
#
# OBS: DROP FUNCTION IF EXISTS med en argumenttyp som inte finns (geom_info,
# tabellregler, kolumnegenskaper) ger NOTICE och hoppas över - inte fel. Därför
# är listan säker att köra även mot en databas som aldrig haft de gamla typerna.
LEGACY_UNINSTALL_SQL = """
-- Triggerfunktioner
DROP FUNCTION IF EXISTS public.notifiera_geoserver_borttagning();
DROP FUNCTION IF EXISTS public.notifiera_geoserver();
DROP FUNCTION IF EXISTS public.hantera_standardiserade_roller();
DROP FUNCTION IF EXISTS public.hantera_hex_standardiserade_roller();
DROP FUNCTION IF EXISTS public.ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();
DROP FUNCTION IF EXISTS public.hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hantera_borttagen_tabell();
DROP FUNCTION IF EXISTS public.kontrollera_geometri_trigger() CASCADE;

-- Hjälpfunktioner
-- Äldre namn med icke-ASCII 'ä'.
DROP FUNCTION IF EXISTS public."tillämpa_grupprattigheter"();
DROP FUNCTION IF EXISTS public.tillampa_grupprattigheter();
DROP FUNCTION IF EXISTS public.lagg_till_dummy_geometri(text, text, geom_info);
DROP FUNCTION IF EXISTS public.lagg_till_dummy_geometri(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.ta_bort_dummy_rad() CASCADE;
DROP FUNCTION IF EXISTS public.tvinga_gid_fran_sekvens() CASCADE;
DROP FUNCTION IF EXISTS public.underhall_hex();
DROP FUNCTION IF EXISTS public.reparera_rad_triggers();
DROP FUNCTION IF EXISTS public.tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.byt_ut_tabell(text, text, text);

-- Regelfunktioner
DROP FUNCTION IF EXISTS public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper);
DROP FUNCTION IF EXISTS public.aterskapa_kolumnegenskaper(text, text, hex_kolumnegenskaper);
DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, tabellregler);
DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, hex_tabellregler);
DROP FUNCTION IF EXISTS public.spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.spara_tabellregler(text, text);

-- Valideringsfunktioner
DROP FUNCTION IF EXISTS public.forklara_geometrifel(geometry);
DROP FUNCTION IF EXISTS public.validera_geometri(geometry) CASCADE;
DROP FUNCTION IF EXISTS public.validera_schemanamn();
DROP FUNCTION IF EXISTS public.blockera_schema_namnbyte();
DROP FUNCTION IF EXISTS public.validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.validera_tabell(text, text);

-- Strukturfunktioner
DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, geom_info);
DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hamta_geometri_definition(text, text);

-- Konfigurationsfunktioner
DROP FUNCTION IF EXISTS public.system_owner();

-- Tabeller
DROP TABLE IF EXISTS public.hex_role_credentials;
DROP TABLE IF EXISTS public.standardiserade_roller;
DROP TABLE IF EXISTS public.standardiserade_kolumner;
DROP TABLE IF EXISTS public.standardiserade_skyddsnivaer;
DROP TABLE IF EXISTS public.standardiserade_datakategorier;

-- Typer (måste tas bort efter funktionerna som använder dem)
DROP TYPE IF EXISTS public.tabellregler;
DROP TYPE IF EXISTS public.kolumnegenskaper;
DROP TYPE IF EXISTS public.kolumnkonfig;
DROP TYPE IF EXISTS public.geom_info;
"""

UNINSTALL_SQL = """
-- Event-triggers (måste tas bort först)
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_borttagning_trigger;
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_trigger;
DROP EVENT TRIGGER IF EXISTS hex_validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_blockera_schema_namnbyte_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_std_roller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_kolumn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_borttagen_tabell_trigger;

-- Triggerfunktioner
DROP FUNCTION IF EXISTS public.hex_notifiera_gs_borttagning();
DROP FUNCTION IF EXISTS public.hex_notifiera_gs();
DROP FUNCTION IF EXISTS public.hex_hantera_std_roller();
DROP FUNCTION IF EXISTS public.hex_ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_kolumn();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hex_hantera_borttagen_tabell();
DROP FUNCTION IF EXISTS public.hex_kontrollera_geometri_trigger() CASCADE;

-- Hjälpfunktioner
DROP FUNCTION IF EXISTS public.hex_tillampa_grupprattigheter();
DROP FUNCTION IF EXISTS public.hex_aterskapa_qa_trigger(text, text, text);
DROP FUNCTION IF EXISTS public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_ta_bort_dummy_rad() CASCADE;
DROP FUNCTION IF EXISTS public.hex_tvinga_gid_fran_sekvens() CASCADE;
DROP FUNCTION IF EXISTS public.hex_underhall();
DROP FUNCTION IF EXISTS public.hex_tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.hex_skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.hex_uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.hex_byt_ut_tabell(text, text, text);

-- Regelfunktioner
DROP FUNCTION IF EXISTS public.hex_aterskapa_kolumnegenskaper(text, text, hex_kolumnegenskaper);
DROP FUNCTION IF EXISTS public.hex_aterskapa_tabellregler(text, text, hex_tabellregler);
DROP FUNCTION IF EXISTS public.hex_spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.hex_spara_tabellregler(text, text);

-- Valideringsfunktioner
DROP FUNCTION IF EXISTS public.hex_forklara_geometrifel(geometry);
DROP FUNCTION IF EXISTS public.hex_validera_geometri(geometry) CASCADE;
DROP FUNCTION IF EXISTS public.hex_validera_schemanamn();
DROP FUNCTION IF EXISTS public.hex_blockera_schema_namnbyte();
DROP FUNCTION IF EXISTS public.hex_validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.hex_validera_tabell(text, text);

-- Strukturfunktioner
DROP FUNCTION IF EXISTS public.hex_hamta_kolumnstandard(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_hamta_geometri_definition(text, text);

-- Konfigurationsfunktioner
DROP FUNCTION IF EXISTS public.hex_schema_regex();
DROP FUNCTION IF EXISTS public.hex_systemagare();
-- OBS: hex_geoserver_roller tas INTE bort här. Rollen är kluster-nivå och delas
-- av alla databaser som kör Hex. Om du avinstallerar Hex från alla databaser och
-- vill ta bort rollen helt, kör manuellt: DROP ROLE hex_geoserver_roller;

-- Tabeller
DROP TABLE IF EXISTS public.hex_rolluppgifter;
DROP TABLE IF EXISTS public.hex_avvikande_srid;
DROP TABLE IF EXISTS public.hex_dummy_geometrier;
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_grupprattigheter;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.hex_standardiserade_roller;
DROP TABLE IF EXISTS public.hex_standardiserade_kolumner;
DROP TABLE IF EXISTS public.hex_standardiserade_skyddsnivaer;
DROP TABLE IF EXISTS public.hex_standardiserade_datakategorier;

-- Typer (måste tas bort efter funktioner som använder dem)
DROP TYPE IF EXISTS public.hex_tabellregler;
DROP TYPE IF EXISTS public.hex_kolumnegenskaper;
DROP TYPE IF EXISTS public.hex_kolumnkonfig;
DROP TYPE IF EXISTS public.hex_geom_info;
"""

# =============================================================================
# PRESERVE CONFIG — tables with default rows the user can customise.
# key: natural unique column; restore: data columns to carry across upgrade.
# =============================================================================

PRESERVE_CONFIG = {
    "hex_standardiserade_skyddsnivaer": {
        "key": "prefix",
        "restore": ["beskrivning", "publiceras_geoserver", "anonym_las"],
    },
    "hex_standardiserade_datakategorier": {
        "key": "prefix",
        "restore": ["beskrivning", "hex_validera_geometri"],
    },
    "hex_standardiserade_kolumner": {
        "key": "kolumnnamn",
        "restore": ["ordinal_position", "datatyp", "default_varde", "schema_uttryck", "historik_qa", "beskrivning"],
    },
    "hex_standardiserade_roller": {
        "key": "rollnamn",
        "restore": ["rolltyp", "schema_uttryck", "ta_bort_med_schema", "kan_logga_in", "arvs_fran", "beskrivning"],
    },
}

# Purely user-managed tables — no system defaults; fully re-inserted on upgrade.
# id/skapad/created_at etc. are left to regenerate automatically.
PRESERVE_USER_DATA = {
    "hex_systemanvandare": ["anvandare", "beskrivning"],
    "hex_grupprattigheter": ["ad_grupproll", "hex_roll", "beskrivning"],
    "hex_rolluppgifter": ["rollnamn", "losenord", "kan_logga_in"],
}

# =============================================================================
# HELPERS
# =============================================================================

def _table_exists(cur, table: str) -> bool:
    """Returnerar True om tabellen finns i public-schemat."""
    cur.execute(
        "SELECT 1 FROM information_schema.tables"
        " WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return cur.fetchone() is not None


def _table_columns(cur, table: str) -> set:
    """Returnerar mängden kolumnnamn för en tabell i public-schemat."""
    cur.execute(
        "SELECT column_name FROM information_schema.columns"
        " WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return {row[0] for row in cur.fetchall()}


def _conn_params(db: dict) -> dict:
    """Returnerar psycopg2-anslutningsparametrar (exkluderar owner_role)."""
    return {k: v for k, v in db.items() if k != "owner_role"}


def _label(db: dict) -> str:
    """Kort etikett för utskrift: dbname@host."""
    return f"{db['dbname']}@{db['host']}"


MINSTA_SERVERVERSION = 160000  # PostgreSQL 16


def skriv_varning(text: str):
    """Skriver ut en varning med indrag på fortsättningsrader."""
    rader = text.splitlines()
    print(f"  VARNING: {rader[0]}")
    for rad in rader[1:]:
        print(f"           {rad}")


def kontrollera_forutsattningar(cur) -> list[str]:
    """Kontrollerar databasens förutsättningar innan Hex installeras.

    1. Serverversion. Hex kräver PostgreSQL 16 eller senare. Avbryter installationen.
    2. CREATE på schema public för PUBLIC. Hex:s SECURITY DEFINER-funktioner låser
       sitt search_path till 'public, pg_temp'. Den låsningen skyddar bara om public
       inte är skrivbart för vem som helst — annars kan en godtycklig användare lägga
       ett objekt i public som skuggar ett Hex-objekt och får det kört som postgres.
       PostgreSQL 15 tog bort den rättigheten som standard, men databaser som
       uppgraderats (pg_upgrade eller dump/restore) från äldre versioner behåller
       sin gamla ACL oavsett vilken version de körs på i dag. Versionsgolvet är
       alltså inte det som skyddar mot skuggning — den här kontrollen är det.
       Varnar men avbryter inte — åtgärden är ett medvetet beslut för databasägaren.

    Returnerar varningstexterna. De skrivs ut direkt men samlas också in så att
    install() kan upprepa dem sist — annars drunknar de i installationsloggen.
    """
    cur.execute("SELECT current_setting('server_version_num')::int, version()")
    versionsnummer, versionstext = cur.fetchone()
    if versionsnummer < MINSTA_SERVERVERSION:
        raise RuntimeError(
            f"Hex kräver PostgreSQL {MINSTA_SERVERVERSION // 10000} eller senare. "
            f"Ansluten server: {versionstext.split(',')[0]}"
        )

    # grantee = 0 betyder PUBLIC i aclexplode().
    cur.execute("""
        SELECT EXISTS (
            SELECT 1
            FROM pg_namespace n, aclexplode(n.nspacl) a
            WHERE n.nspname = 'public'
              AND a.grantee = 0
              AND a.privilege_type = 'CREATE'
        )
    """)
    varningar: list[str] = []
    if cur.fetchone()[0]:
        varningar.append(
            "PUBLIC har CREATE på schema public.\n"
            "Hex:s SECURITY DEFINER-funktioner körs som postgres och slår upp\n"
            "objekt i public. Så länge vem som helst kan skapa objekt där kan\n"
            "ett Hex-objekt skuggas och den skuggande koden köras som postgres.\n"
            "Åtgärda med:  REVOKE CREATE ON SCHEMA public FROM PUBLIC;\n"
            "(Databasen är sannolikt uppgraderad från PostgreSQL 14 eller äldre.)"
        )

    for varning in varningar:
        skriv_varning(varning)
    return varningar


# =============================================================================
# UPGRADE HELPERS
# =============================================================================

def snapshot_settings(cur) -> dict:
    """Läser alla rader från PRESERVE_*-tabeller innan avinstallation."""
    snapshot = {}

    for table, cfg in PRESERVE_CONFIG.items():
        if not _table_exists(cur, table):
            continue
        cols = _table_columns(cur, table)
        key = cfg["key"]
        restore_cols = [c for c in cfg["restore"] if c in cols]
        all_cols = [key] + restore_cols
        cur.execute(
            pgsql.SQL("SELECT {} FROM public.{}").format(
                pgsql.SQL(", ").join(pgsql.Identifier(c) for c in all_cols),
                pgsql.Identifier(table),
            )
        )
        snapshot[table] = {"rows": cur.fetchall(), "cols": all_cols}

    for table, user_cols in PRESERVE_USER_DATA.items():
        if not _table_exists(cur, table):
            continue
        cols = _table_columns(cur, table)
        available_cols = [c for c in user_cols if c in cols]
        if not available_cols:
            continue
        cur.execute(
            pgsql.SQL("SELECT {} FROM public.{}").format(
                pgsql.SQL(", ").join(pgsql.Identifier(c) for c in available_cols),
                pgsql.Identifier(table),
            )
        )
        snapshot[table] = {"rows": cur.fetchall(), "cols": available_cols}

    return snapshot


def restore_settings(cur, snapshot: dict):
    """Återställer rader från snapshot efter en ny installation.

    PRESERVE_CONFIG: UPDATEar rader som matchar naturlig nyckel;
                     INSERTar rader som inte längre finns i nya defaults (användartillagda).
    PRESERVE_USER_DATA: INSERTar alla sparade rader med ON CONFLICT DO NOTHING.
    Strukturell difftolerens: återställer bara kolumner som finns i både snapshot och ny tabell.
    """
    for table, cfg in PRESERVE_CONFIG.items():
        if table not in snapshot:
            continue
        data = snapshot[table]
        if not data["rows"]:
            continue
        if not _table_exists(cur, table):
            continue

        new_cols = _table_columns(cur, table)
        key_col = cfg["key"]
        old_cols = data["cols"]

        # Only work with columns present in both snapshot and new schema
        restorable_cols = [c for c in old_cols if c in new_cols]
        if key_col not in restorable_cols:
            continue
        restore_cols = [c for c in restorable_cols if c != key_col]

        for row in data["rows"]:
            row_dict = dict(zip(old_cols, row))
            key_val = row_dict[key_col]

            if restore_cols:
                params = {c: row_dict[c] for c in restore_cols}
                params[key_col] = key_val
                cur.execute(
                    pgsql.SQL("UPDATE public.{} SET {} WHERE {} = {}").format(
                        pgsql.Identifier(table),
                        pgsql.SQL(", ").join(
                            pgsql.SQL("{} = {}").format(
                                pgsql.Identifier(c), pgsql.Placeholder(c)
                            )
                            for c in restore_cols
                        ),
                        pgsql.Identifier(key_col),
                        pgsql.Placeholder(key_col),
                    ),
                    params,
                )

            if cur.rowcount == 0:
                # User-added row — insert it back
                insert_cols = restorable_cols
                insert_params = {c: row_dict[c] for c in insert_cols}
                cur.execute(
                    pgsql.SQL(
                        "INSERT INTO public.{} ({}) VALUES ({}) ON CONFLICT ({}) DO NOTHING"
                    ).format(
                        pgsql.Identifier(table),
                        pgsql.SQL(", ").join(pgsql.Identifier(c) for c in insert_cols),
                        pgsql.SQL(", ").join(pgsql.Placeholder(c) for c in insert_cols),
                        pgsql.Identifier(key_col),
                    ),
                    insert_params,
                )

    for table, user_cols in PRESERVE_USER_DATA.items():
        if table not in snapshot:
            continue
        data = snapshot[table]
        if not data["rows"]:
            continue
        if not _table_exists(cur, table):
            continue

        new_cols = _table_columns(cur, table)
        old_cols = data["cols"]
        restorable_cols = [c for c in old_cols if c in new_cols]
        if not restorable_cols:
            continue

        for row in data["rows"]:
            row_dict = dict(zip(old_cols, row))
            insert_params = {c: row_dict[c] for c in restorable_cols if c in row_dict}
            if not insert_params:
                continue
            cur.execute(
                pgsql.SQL(
                    "INSERT INTO public.{} ({}) VALUES ({}) ON CONFLICT DO NOTHING"
                ).format(
                    pgsql.Identifier(table),
                    pgsql.SQL(", ").join(pgsql.Identifier(c) for c in insert_params),
                    pgsql.SQL(", ").join(pgsql.Placeholder(c) for c in insert_params),
                ),
                insert_params,
            )


def upgrade(db: dict, base_path="."):
    """Sparar inställningar, avinstallerar, installerar om och återställer inställningar."""
    print("=" * 60)
    print(f"Hex Uppgradering - {_label(db)}")
    print("=" * 60)

    # Snapshot before uninstall
    conn = psycopg2.connect(**_conn_params(db))
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()
    try:
        print("Sparar inställningar...")
        snapshot = snapshot_settings(cur)
        total = sum(len(d["rows"]) for d in snapshot.values())
        print(f"  {total} rad(er) sparade från {len(snapshot)} tabell(er).")
    finally:
        cur.close()
        conn.close()

    uninstall(db)
    install(db, base_path)

    # Restore in a fresh connection
    conn = psycopg2.connect(**_conn_params(db))
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()
    try:
        print("Återställer inställningar...")
        restore_settings(cur, snapshot)
        conn.commit()
        print("Uppgradering klar.")
        print("+++Upgrade Complete+++")
    except Exception as e:
        conn.rollback()
        print(f"MISSLYCKADES vid återställning: {e}")
        raise
    finally:
        cur.close()
        conn.close()


# =============================================================================
# INSTALLATION
# =============================================================================

def uninstall(db: dict):
    """Tar bort alla Hex-komponenter från en databas."""
    print("=" * 60)
    print(f"Hex Avinstallation - {_label(db)}")
    print("=" * 60)

    conn = psycopg2.connect(**_conn_params(db))
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()

    try:
        print("Tar bort Hex-objekt...")
        # Ärvda event-triggers först: en gammal hantera_ny_tabell() som ligger
        # kvar avfyras annars på nästa CREATE TABLE och stoppar installationen.
        cur.execute(LEGACY_EVENT_TRIGGERS_SQL)
        cur.execute(UNINSTALL_SQL)
        cur.execute(LEGACY_UNINSTALL_SQL)
        conn.commit()
        print("Avinstallation klar.")
        print("+++melon melon melon+++")
    except Exception as e:
        conn.rollback()
        print(f"MISSLYCKADES: {e}")
        raise
    finally:
        cur.close()
        conn.close()


def install(db: dict, base_path="."):
    """Installerar alla Hex-komponenter till en databas."""
    owner_role = db.get("owner_role")

    print("=" * 60)
    print(f"Hex Installation - {_label(db)}")
    print(f"Ägarroll: {owner_role or '(anslutande användare)'}")
    print("=" * 60)

    conn = psycopg2.connect(**_conn_params(db))
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()

    installed = 0

    try:
        # Serverversion och skrivskydd på public innan något installeras
        print("Kontrollerar databasens förutsättningar...")
        varningar = kontrollera_forutsattningar(cur)

        # Ta bort event-triggers från tiden före hex_-prefixet. De pekar på
        # funktioner som inte längre uppdateras, men avfyras fortfarande på
        # CREATE TABLE och avbryter då hela installationstransaktionen.
        #
        # Måste ske före CREATE EXTENSION: postgis skapar spatial_ref_sys, och
        # den tabellen räcker för att en ärvd trigger ska hinna fälla oss.
        #
        # Övriga ärvda objekt lämnas orörda här - de kan bära data, och en ren
        # installation ska inte kasta något. Avinstallationen tar hand om resten.
        print("Rensar ärvda event-triggers...")
        cur.execute(LEGACY_EVENT_TRIGGERS_SQL)

        # Säkerställ att PostGIS finns
        print("Kontrollerar PostGIS-tillägget...")
        cur.execute("CREATE EXTENSION IF NOT EXISTS postgis")

        # Säkerställ att pgcrypto finns (krävs av hex_hantera_std_roller
        # för gen_random_bytes() vid lösenordsgenerering)
        print("Kontrollerar pgcrypto-tillägget...")
        cur.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

        # Bestäm vilken roll som ska äga Hex:s objekt. Rollen bakas in i
        # hex_systemagare(), och SQL-filerna sätter sitt ägarskap mot den
        # funktionen i stället för mot ett hårdkodat rollnamn.
        #
        # Med ett konfigurerat owner_role säkerställs att rollen finns. Saknas
        # den skapas den här — annars kan Hex inte installeras i en ny databas
        # utan ett manuellt CREATE ROLE i förväg, vilket är lätt att missa.
        #
        # Rollen skapas NOLOGIN och utan lösenord. Den behöver aldrig logga in:
        # den äger Hex:s objekt och får ADMIN OPTION på schemats r_/w_-roller,
        # och båda delarna fungerar för en NOLOGIN-roll. En miljö som vill kunna
        # logga in som ägarrollen lägger själv till LOGIN och lösenord.
        #
        # OBS: roller är gemensamma för hela klustret, inte per databas. Skapas
        # rollen här finns den även för klustrets övriga databaser.
        if owner_role is None:
            # owner_role=None betyder "den anslutande användaren äger objekten".
            # Ägaren måste ändå ha ett namn: SQL-filerna sätter ägarskap via
            # hex_systemagare(), som bakas in nedan. Läs därför av den faktiska
            # anslutningen i stället för att anta 'postgres' — annars pekar
            # hex_systemagare() på fel roll så snart installationen körs som en
            # annan superuser än postgres.
            cur.execute("SELECT current_user")
            effective_owner = cur.fetchone()[0]
        else:
            effective_owner = owner_role
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (effective_owner,))
            if not cur.fetchone():
                print(f"Ägarrollen '{effective_owner}' saknas – skapar den (NOLOGIN)...")
                cur.execute(
                    pgsql.SQL("CREATE ROLE {} NOLOGIN").format(
                        pgsql.Identifier(effective_owner)
                    )
                )
                varningar.append(
                    f"Ägarrollen '{effective_owner}' fanns inte och skapades av installern.\n"
                    "Den är NOLOGIN och saknar lösenord. Kontrollera att namnet är rätt\n"
                    "stavat – ett felstavat owner_role skapar en ny roll i stället för\n"
                    "att återanvända den avsedda. Behöver rollen kunna logga in:\n"
                    f"  ALTER ROLE {effective_owner} LOGIN PASSWORD '...';"
                )
                skriv_varning(varningar[-1])

        # Skapa hex_systemagare()-funktionen dynamiskt
        system_owner_sql = f"""
CREATE OR REPLACE FUNCTION public.hex_systemagare()
    RETURNS text
    LANGUAGE 'sql'
    IMMUTABLE
AS $BODY$
    SELECT '{effective_owner}'::text;
$BODY$;

ALTER FUNCTION public.hex_systemagare() OWNER TO postgres;

COMMENT ON FUNCTION public.hex_systemagare()
    IS 'Returnerar ägarrollen för Hex-skapade roller. Genererad av installer.';
"""
        print("Installerar hex_systemagare()...")
        cur.execute(system_owner_sql)
        installed += 1

        for sql_file in INSTALL_ORDER:
            path = Path(base_path) / sql_file
            if not path.exists():
                raise FileNotFoundError(f"Saknas: {sql_file}")

            # Filerna körs precis som de står. Ägarskapet sätts i SQL:en mot
            # hex_systemagare(), som skapades ovan från effective_owner, så
            # installern har inget att skriva om.
            print(f"Installerar {path.name}...")
            cur.execute(path.read_text(encoding='utf-8'))
            installed += 1

        # Commit bara om allt lyckas
        conn.commit()
        print("=" * 60)
        print(f"Installerade {installed} komponenter.")
        print("=" * 60)

        # Underhåll: verifiera och reparera triggers, roller och behörigheter
        # på befintliga tabeller och scheman (separat steg så att ett fel här
        # aldrig rullar tillbaka huvudinstallationen).
        print("Underhåller Hex-struktur (triggers, roller, behörigheter)...")
        try:
            cur.execute(
                "SELECT schema_namn, tabell_namn, trigger_namn, atgard"
                " FROM public.hex_underhall()"
            )
            rows = cur.fetchall()
            conn.commit()
            created = [(s, t, tr, a) for s, t, tr, a in rows if a not in ("redan finns",)]
            if created:
                for s, t, tr, a in created:
                    prefix = f"{s}." if s and s != "-" else ""
                    print(f"  ✓ {prefix}{t} → {tr} ({a})")
                print(f"  {len(created)} åtgärd(er) genomförda.")
            else:
                print("  Inga åtgärder behövdes.")
        except Exception as repair_err:
            conn.rollback()
            varningar.append(
                f"Underhåll misslyckades: {str(repair_err).strip()}\n"
                "Hex är installerat. Kör SELECT * FROM public.hex_underhall() manuellt."
            )
            skriv_varning(varningar[-1])

        # Upprepa varningarna sist – annars försvinner de i loggen ovan.
        if varningar:
            print("=" * 60)
            print(f"{len(varningar)} varning(ar) kvar att åtgärda:")
            for varning in varningar:
                skriv_varning(varning)
            print("=" * 60)

        print("+++Anthill Inside+++")

    except Exception as e:
        conn.rollback()
        print(f"MISSLYCKADES: {e}")
        print("Transaktionen återställd - inga ändringar gjorda.")
        print("+++Divide By Cucumber Error. Please Reinstall Universe And Reboot+++")
        raise
    finally:
        cur.close()
        conn.close()


# =============================================================================
# ENTRYPOINT
# =============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Hex Installation")
    parser.add_argument("--uninstall", action="store_true", help="Ta bort alla Hex-objekt")
    parser.add_argument("--upgrade", action="store_true", help="Spara inställningar, avinstallera, installera om och återställ")
    args = parser.parse_args()

    if args.uninstall:
        action_name = "Avinstallation"
        def action(db): return uninstall(db)
    elif args.upgrade:
        action_name = "Uppgradering"
        def action(db): return upgrade(db)
    else:
        action_name = "Installation"
        def action(db): return install(db)

    succeeded = []
    failed = []

    for db in DATABASES:
        try:
            action(db)
            succeeded.append(_label(db))
        except Exception as e:
            # Felet måste skrivas ut här. Misslyckas redan psycopg2.connect()
            # hinner install() aldrig in i sin egen felhantering, och utan den
            # här utskriften avslutas installern tyst med exitkod 1.
            print(f"MISSLYCKADES: {_label(db)}: {e}")
            failed.append(_label(db))

    if len(DATABASES) > 1:
        print()
        print("=" * 60)
        print(f"Sammanfattning - {action_name}")
        print("=" * 60)
        for label in succeeded:
            print(f"  OK:       {label}")
        for label in failed:
            print(f"  MISSLYCKADES: {label}")
        print(f"  {len(succeeded)}/{len(DATABASES)} databaser lyckades.")
        print("=" * 60)

    if failed:
        raise SystemExit(1)
