#!/usr/bin/env python3
"""
Hex Installer - kör SQL-filer i beroendeordning
Användning:
    python install_hex.py              # Installera alla konfigurerade databaser
    python install_hex.py --uninstall  # Ta bort alla Hex-objekt från alla databaser
"""

import argparse
import re
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
        "host": "localhost",
        "port": 5432,
        "dbname": "hex_test",
        "user": "postgres",
        "password": "testpass",
        "owner_role": "gis_admin",
    },
]

# =============================================================================
# INSTALL ORDER
# =============================================================================

INSTALL_ORDER = [
    # Konfiguration
    "src/sql/00_config/hex_geoserver_roller.sql",
    # Typer
    "src/sql/01_types/geom_info.sql",
    "src/sql/01_types/kolumnkonfig.sql",
    "src/sql/01_types/kolumnegenskaper.sql",
    "src/sql/01_types/tabellregler.sql",
    # Tabeller
    "src/sql/02_tables/standardiserade_skyddsnivaer.sql",
    # hex_schema_regex() läser standardiserade_skyddsnivaer – måste skapas efter tabellen
    "src/sql/00_config/hex_schema_regex.sql",
    "src/sql/02_tables/standardiserade_datakategorier.sql",
    "src/sql/02_tables/standardiserade_kolumner.sql",
    "src/sql/02_tables/standardiserade_roller.sql",
    "src/sql/02_tables/hex_metadata.sql",
    "src/sql/02_tables/hex_systemanvandare.sql",
    "src/sql/02_tables/hex_grupprattigheter.sql",
    "src/sql/02_tables/hex_afvaktande_geometri.sql",
    "src/sql/02_tables/hex_dummy_geometrier.sql",
    "src/sql/02_tables/hex_avvikande_srid.sql",
    "src/sql/02_tables/hex_role_credentials.sql",
    # Funktioner - Struktur
    "src/sql/03_functions/01_structure/hamta_geometri_definition.sql",
    "src/sql/03_functions/01_structure/hamta_kolumnstandard.sql",
    # Funktioner - Validering
    "src/sql/03_functions/02_validation/validera_tabell.sql",
    "src/sql/03_functions/02_validation/validera_vynamn.sql",
    "src/sql/03_functions/02_validation/validera_schemanamn.sql",
    "src/sql/03_functions/02_validation/blockera_schema_namnbyte.sql",
    "src/sql/03_functions/02_validation/validera_geometri.sql",
    "src/sql/03_functions/02_validation/forklara_geometrifel.sql",
    # Funktioner - Regler
    "src/sql/03_functions/03_rules/spara_tabellregler.sql",
    "src/sql/03_functions/03_rules/spara_kolumnegenskaper.sql",
    "src/sql/03_functions/03_rules/aterskapa_tabellregler.sql",
    "src/sql/03_functions/03_rules/aterskapa_kolumnegenskaper.sql",
    # Funktioner - Verktyg
    "src/sql/03_functions/04_utility/byt_ut_tabell.sql",
    "src/sql/03_functions/04_utility/uppdatera_sekvensnamn.sql",
    "src/sql/03_functions/04_utility/skapa_historik_qa.sql",
    "src/sql/03_functions/04_utility/tilldela_rollrattigheter.sql",
    "src/sql/03_functions/04_utility/tillampa_grupprattigheter.sql",
    "src/sql/03_functions/04_utility/tvinga_gid_fran_sekvens.sql",
    "src/sql/03_functions/04_utility/underhall_hex.sql",
    # Funktioner - Triggerfunktioner
    "src/sql/03_functions/05_trigger_functions/ta_bort_dummy_rad.sql",
    "src/sql/03_functions/04_utility/lagg_till_dummy_geometri.sql",
    "src/sql/03_functions/05_trigger_functions/kontrollera_geometri.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_ny_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_kolumntillagg.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_ny_vy.sql",
    "src/sql/03_functions/05_trigger_functions/ta_bort_schemaroller.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_standardiserade_roller.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_borttagen_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/notifiera_geoserver.sql",
    "src/sql/03_functions/05_trigger_functions/notifiera_geoserver_borttagning.sql",
    # Triggers
    "src/sql/04_triggers/hantera_ny_tabell_trigger.sql",
    "src/sql/04_triggers/hantera_kolumntillagg_trigger.sql",
    "src/sql/04_triggers/hantera_ny_vy_trigger.sql",
    "src/sql/04_triggers/ta_bort_schemaroller_trigger.sql",
    "src/sql/04_triggers/hantera_standardiserade_roller_trigger.sql",
    "src/sql/04_triggers/hantera_borttagen_tabell_trigger.sql",
    "src/sql/04_triggers/validera_schemanamn_trigger.sql",
    "src/sql/04_triggers/blockera_schema_namnbyte_trigger.sql",
    "src/sql/04_triggers/notifiera_geoserver_trigger.sql",
    "src/sql/04_triggers/notifiera_geoserver_borttagning_trigger.sql",
]

# =============================================================================
# AVINSTALLATION - omvänd ordning, DROP-satser
# =============================================================================

UNINSTALL_SQL = """
-- Event-triggers (måste tas bort först)
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_borttagning_trigger;
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_trigger;
DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS blockera_schema_namnbyte_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger;
DROP EVENT TRIGGER IF EXISTS ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_borttagen_tabell_trigger;

-- Triggerfunktioner
DROP FUNCTION IF EXISTS public.notifiera_geoserver_borttagning();
DROP FUNCTION IF EXISTS public.notifiera_geoserver();
DROP FUNCTION IF EXISTS public.hantera_standardiserade_roller();
DROP FUNCTION IF EXISTS public.ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();
DROP FUNCTION IF EXISTS public.hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hantera_borttagen_tabell();
DROP FUNCTION IF EXISTS public.kontrollera_geometri_trigger() CASCADE;

-- Hjälpfunktioner
DROP FUNCTION IF EXISTS public.tillämpa_grupprattigheter();
DROP FUNCTION IF EXISTS public.lagg_till_dummy_geometri(text, text, geom_info);
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
DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, tabellregler);
DROP FUNCTION IF EXISTS public.spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.spara_tabellregler(text, text);

-- Valideringsfunktioner
DROP FUNCTION IF EXISTS public.forklara_geometrifel(geometry, float);
DROP FUNCTION IF EXISTS public.validera_geometri(geometry, float) CASCADE;
DROP FUNCTION IF EXISTS public.validera_schemanamn();
DROP FUNCTION IF EXISTS public.blockera_schema_namnbyte();
DROP FUNCTION IF EXISTS public.validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.validera_tabell(text, text);

-- Strukturfunktioner
DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, geom_info);
DROP FUNCTION IF EXISTS public.hamta_geometri_definition(text, text);

-- Konfigurationsfunktioner
DROP FUNCTION IF EXISTS public.hex_schema_regex();
DROP FUNCTION IF EXISTS public.system_owner();
-- OBS: hex_geoserver_roller tas INTE bort här. Rollen är kluster-nivå och delas
-- av alla databaser som kör Hex. Om du avinstallerar Hex från alla databaser och
-- vill ta bort rollen helt, kör manuellt: DROP ROLE hex_geoserver_roller;

-- Tabeller
DROP TABLE IF EXISTS public.hex_role_credentials;
DROP TABLE IF EXISTS public.hex_avvikande_srid;
DROP TABLE IF EXISTS public.hex_dummy_geometrier;
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_grupprattigheter;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.standardiserade_roller;
DROP TABLE IF EXISTS public.standardiserade_kolumner;
DROP TABLE IF EXISTS public.standardiserade_skyddsnivaer;
DROP TABLE IF EXISTS public.standardiserade_datakategorier;

-- Typer (måste tas bort efter funktioner som använder dem)
DROP TYPE IF EXISTS public.tabellregler;
DROP TYPE IF EXISTS public.kolumnegenskaper;
DROP TYPE IF EXISTS public.kolumnkonfig;
DROP TYPE IF EXISTS public.geom_info;
"""

# =============================================================================
# PRESERVE CONFIG — tables with default rows the user can customise.
# key: natural unique column; restore: data columns to carry across upgrade.
# =============================================================================

PRESERVE_CONFIG = {
    "standardiserade_skyddsnivaer": {
        "key": "prefix",
        "restore": ["beskrivning", "publiceras_geoserver"],
    },
    "standardiserade_datakategorier": {
        "key": "prefix",
        "restore": ["beskrivning", "validera_geometri"],
    },
    "standardiserade_kolumner": {
        "key": "kolumnnamn",
        "restore": ["ordinal_position", "datatyp", "default_varde", "schema_uttryck", "historik_qa", "beskrivning"],
    },
    "standardiserade_roller": {
        "key": "rollnamn",
        "restore": ["rolltyp", "schema_uttryck", "ta_bort_med_schema", "with_login", "arvs_fran", "beskrivning"],
    },
}

# Purely user-managed tables — no system defaults; fully re-inserted on upgrade.
# id/skapad/created_at etc. are left to regenerate automatically.
PRESERVE_USER_DATA = {
    "hex_systemanvandare": ["anvandare", "beskrivning"],
    "hex_grupprattigheter": ["ad_grupproll", "hex_roll", "beskrivning"],
    "hex_role_credentials": ["rolname", "password", "rolcanlogin"],
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


def process_sql(sql: str, owner_role: str | None) -> str:
    """Bearbetar SQL-innehåll - ersätter eller tar bort OWNER TO-satser.

    Event-triggers måste ägas av en superuser och behåller därför postgres-ägande.
    """
    # Event-triggers och SECURITY DEFINER-funktioner kräver superuser-ägande
    needs_superuser = ('CREATE EVENT TRIGGER' in sql.upper() or
                       'SECURITY DEFINER' in sql.upper())

    if needs_superuser:
        # Behåll postgres-ägande för superuser-beroende objekt
        return sql

    if not owner_role:
        # Ta bort OWNER TO-rader helt
        lines = [line for line in sql.split('\n') if 'OWNER TO' not in line.upper()]
        return '\n'.join(lines)

    # Ersätt alla OWNER TO med konfigurerad roll
    return re.sub(r'OWNER TO \w+', f'OWNER TO {owner_role}', sql, flags=re.IGNORECASE)


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
        cur.execute(UNINSTALL_SQL)
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
        # Säkerställ att PostGIS finns
        print("Kontrollerar PostGIS-tillägget...")
        cur.execute("CREATE EXTENSION IF NOT EXISTS postgis")

        # Säkerställ att pgcrypto finns (krävs av hantera_standardiserade_roller
        # för gen_random_bytes() vid lösenordsgenerering)
        print("Kontrollerar pgcrypto-tillägget...")
        cur.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

        # Validera att owner_role existerar om angiven
        effective_owner = owner_role or 'postgres'
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (effective_owner,))
        if not cur.fetchone():
            raise ValueError(f"owner_role '{effective_owner}' finns inte i databasen")

        # Skapa system_owner()-funktionen dynamiskt
        system_owner_sql = f"""
CREATE OR REPLACE FUNCTION public.system_owner()
    RETURNS text
    LANGUAGE 'sql'
    IMMUTABLE
AS $BODY$
    SELECT '{effective_owner}'::text;
$BODY$;

ALTER FUNCTION public.system_owner() OWNER TO postgres;

COMMENT ON FUNCTION public.system_owner()
    IS 'Returnerar ägarrollen för Hex-skapade roller. Genererad av installer.';
"""
        print("Installerar system_owner()...")
        cur.execute(system_owner_sql)
        installed += 1

        for sql_file in INSTALL_ORDER:
            path = Path(base_path) / sql_file
            if not path.exists():
                raise FileNotFoundError(f"Saknas: {sql_file}")

            print(f"Installerar {path.name}...")
            sql = process_sql(path.read_text(encoding='utf-8'), owner_role)
            cur.execute(sql)
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
                " FROM public.underhall_hex()"
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
            print(f"  Varning: underhåll misslyckades: {repair_err}")
            print("  Hex är installerat. Kör SELECT * FROM public.underhall_hex() manuellt.")

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
        except Exception:
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
