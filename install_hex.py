#!/usr/bin/env python3
"""
Hex Installer - kör SQL-filer i beroendeordning
Användning:
    python install_hex.py              # Installera
    python install_hex.py --uninstall  # Ta bort alla Hex-objekt
"""

import argparse
import re
import psycopg2
from psycopg2 import sql as pgsql
from pathlib import Path

# =============================================================================
# CONFIGURATION
# =============================================================================

# Databasanslutning
# OBS - måste köras som postgres för att skapa event-triggers
DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "hex_test",
    "user": "postgres",
    "password": "testpass",
    "client_encoding": "UTF8",
}

# Ägarroll för alla skapade objekt (typer, tabeller, funktioner, triggers)
# Sätt till None för att använda den anslutande användaren som ägare
OWNER_ROLE = "gis_admin"

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
# INSTÄLLNINGSBEVARANDE (för --upgrade)
# =============================================================================

# Tabeller med förvalda rader som användaren kan anpassa.
# key       – naturlig nyckel som identifierar en rad unikt (matchar UNIQUE-constraint).
# data_cols – kolumner som ska återställas (utöver nyckeln) vid en uppgradering.
#             Rader vars nyckel inte längre finns i de nya förvalda raderna (dvs.
#             användarens egna tillagda rader) återinfogas i sin helhet.
PRESERVE_CONFIG = {
    'standardiserade_skyddsnivaer': {
        'key':       'prefix',
        'data_cols': ['beskrivning', 'publiceras_geoserver'],
    },
    'standardiserade_datakategorier': {
        'key':       'prefix',
        'data_cols': ['beskrivning', 'validera_geometri'],
    },
    'standardiserade_kolumner': {
        'key':       'kolumnnamn',
        'data_cols': ['ordinal_position', 'datatyp', 'default_varde',
                      'schema_uttryck', 'historik_qa', 'beskrivning'],
    },
    'standardiserade_roller': {
        'key':       'rollnamn',
        'data_cols': ['rolltyp', 'schema_uttryck', 'ta_bort_med_schema',
                      'with_login', 'arvs_fran', 'beskrivning'],
    },
}

# Tabeller som enbart innehåller användardata (inga systemförval).
# Alla rader återinfogas vid uppgradering med ON CONFLICT DO NOTHING.
# Kolumner med automatiska värden (skapad, id, …) ingår inte.
PRESERVE_USER_DATA = {
    'hex_systemanvandare':  ['anvandare', 'beskrivning'],
    'hex_grupprattigheter': ['ad_grupproll', 'hex_roll', 'beskrivning'],
    'hex_role_credentials': ['rolname', 'password', 'rolcanlogin'],
}


def _table_exists(cur, table: str) -> bool:
    cur.execute(
        "SELECT 1 FROM information_schema.tables "
        "WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return cur.fetchone() is not None


def _table_columns(cur, table: str) -> set:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return {row[0] for row in cur.fetchall()}


def snapshot_settings(cur) -> dict:
    """Läser alla konfigurerbara tabeller och sparar dem i minnet.

    Returnerar ett dict:
      { tabell: { 'columns': [...], 'rows': [...] } }

    Anropas *innan* avinstallation. Strukturella skillnader (tillagda/borttagna
    kolumner i en ny version) hanteras automatiskt i restore_settings().
    """
    snapshot = {}
    all_tables = list(PRESERVE_CONFIG.keys()) + list(PRESERVE_USER_DATA.keys())

    for table in all_tables:
        if not _table_exists(cur, table):
            print(f"  {table}: saknas, hoppar över")
            continue
        cur.execute(pgsql.SQL("SELECT * FROM public.{}").format(pgsql.Identifier(table)))
        cols = [desc[0] for desc in cur.description]
        rows = cur.fetchall()
        snapshot[table] = {'columns': cols, 'rows': rows}
        print(f"  {table}: {len(rows)} rad(er) sparad(e)")

    return snapshot


def restore_settings(cur, snapshot: dict) -> None:
    """Återställer sparade inställningar efter en ny installation.

    Strategi per tabell:
    • PRESERVE_CONFIG  – UPDATE befintliga rader (matcha på nyckelkolumn),
                         INSERT rader som inte finns i de nya förvalda raderna.
    • PRESERVE_USER_DATA – INSERT alla sparade rader med ON CONFLICT DO NOTHING.

    Kolumner som inte finns i *både* snapshot och den nya tabellen hoppas över,
    vilket gör återställningen tolerant mot strukturförändringar mellan versioner.
    """
    # --- Konfigurationstabeller ---
    for table, cfg in PRESERVE_CONFIG.items():
        if table not in snapshot:
            continue

        saved      = snapshot[table]
        old_cols   = saved['columns']
        key_col    = cfg['key']
        new_cols   = _table_columns(cur, table)

        # Begränsa till kolumner som finns i bägge versioner
        restorable = [c for c in cfg['data_cols'] if c in new_cols and c in old_cols]

        if key_col not in old_cols or not restorable:
            print(f"  {table}: inga återställbara kolumner, hoppar över")
            continue

        key_idx  = old_cols.index(key_col)
        col_idxs = {c: old_cols.index(c) for c in restorable}

        updated = inserted = 0
        for row in saved['rows']:
            key_val  = row[key_idx]
            data     = {c: row[i] for c, i in col_idxs.items()}
            set_vals = list(data.values()) + [key_val]

            cur.execute(
                pgsql.SQL("UPDATE public.{tbl} SET {sets} WHERE {key} = %s").format(
                    tbl=pgsql.Identifier(table),
                    sets=pgsql.SQL(', ').join(
                        pgsql.SQL("{} = %s").format(pgsql.Identifier(c)) for c in data
                    ),
                    key=pgsql.Identifier(key_col),
                ),
                set_vals,
            )

            if cur.rowcount == 0:
                # Raden finns inte bland de nya förvalda raderna → användarens egna rad
                ins_cols = [key_col] + list(data.keys())
                ins_vals = [key_val] + list(data.values())
                cur.execute(
                    pgsql.SQL(
                        "INSERT INTO public.{tbl} ({cols}) VALUES ({phs}) "
                        "ON CONFLICT DO NOTHING"
                    ).format(
                        tbl=pgsql.Identifier(table),
                        cols=pgsql.SQL(', ').join(map(pgsql.Identifier, ins_cols)),
                        phs=pgsql.SQL(', ').join(pgsql.Placeholder() * len(ins_vals)),
                    ),
                    ins_vals,
                )
                inserted += 1
            else:
                updated += 1

        print(f"  {table}: {updated} uppdaterad(e), {inserted} infogad(e)")

    # --- Användardatatabeller ---
    for table, restore_cols in PRESERVE_USER_DATA.items():
        if table not in snapshot:
            continue

        saved    = snapshot[table]
        old_cols = saved['columns']
        new_cols = _table_columns(cur, table)
        actual   = [c for c in restore_cols if c in new_cols and c in old_cols]

        if not actual:
            print(f"  {table}: inga återställbara kolumner, hoppar över")
            continue

        col_idxs = [old_cols.index(c) for c in actual]
        inserted = 0
        for row in saved['rows']:
            vals = [row[i] for i in col_idxs]
            cur.execute(
                pgsql.SQL(
                    "INSERT INTO public.{tbl} ({cols}) VALUES ({phs}) "
                    "ON CONFLICT DO NOTHING"
                ).format(
                    tbl=pgsql.Identifier(table),
                    cols=pgsql.SQL(', ').join(map(pgsql.Identifier, actual)),
                    phs=pgsql.SQL(', ').join(pgsql.Placeholder() * len(vals)),
                ),
                vals,
            )
            inserted += cur.rowcount

        print(f"  {table}: {inserted} rad(er) återställd(er)")


# =============================================================================
# INSTALLATION
# =============================================================================

def process_sql(sql: str) -> str:
    """Bearbetar SQL-innehåll - ersätter eller tar bort OWNER TO-satser.

    Event-triggers måste ägas av en superuser och behåller därför postgres-ägande.
    """
    # Event-triggers och SECURITY DEFINER-funktioner kräver superuser-ägande
    needs_superuser = ('CREATE EVENT TRIGGER' in sql.upper() or
                       'SECURITY DEFINER' in sql.upper())

    if needs_superuser:
        # Behåll postgres-ägande för superuser-beroende objekt
        return sql

    if not OWNER_ROLE:
        # Ta bort OWNER TO-rader helt
        lines = [line for line in sql.split('\n') if 'OWNER TO' not in line.upper()]
        return '\n'.join(lines)

    # Ersätt alla OWNER TO med konfigurerad roll
    return re.sub(r'OWNER TO \w+', f'OWNER TO {OWNER_ROLE}', sql, flags=re.IGNORECASE)


def uninstall():
    """Tar bort alla Hex-komponenter från databasen."""
    print("=" * 60)
    print("Hex Avinstallation")
    print("=" * 60)
    print(f"Databas: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print("=" * 60)

    conn = psycopg2.connect(**DB_CONFIG)
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


def install(base_path="."):
    """Installerar alla Hex-komponenter till databasen."""
    print("=" * 60)
    print("Hex Installation")
    print("=" * 60)
    print(f"Databas: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print(f"Ägarroll: {OWNER_ROLE or '(anslutande användare)'}")
    print("=" * 60)

    conn = psycopg2.connect(**DB_CONFIG)
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

        # Validera att OWNER_ROLE existerar om angiven
        owner_role = OWNER_ROLE or 'postgres'
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (owner_role,))
        if not cur.fetchone():
            raise ValueError(f"OWNER_ROLE '{owner_role}' finns inte i databasen")

        # Skapa system_owner()-funktionen dynamiskt
        system_owner_sql = f"""
CREATE OR REPLACE FUNCTION public.system_owner()
    RETURNS text
    LANGUAGE 'sql'
    IMMUTABLE
AS $BODY$
    SELECT '{owner_role}'::text;
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
            sql = process_sql(path.read_text(encoding='utf-8'))
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


def upgrade(base_path="."):
    """Uppgraderar Hex med bevarade inställningar.

    Steg:
      1. Läs och spara alla konfigurerbara tabeller i minnet.
      2. Kör full avinstallation (tar bort allt).
      3. Kör ny installation (skapar allt från grunden med förvalda värden).
      4. Återställ sparade inställningar ovanpå de nya förvalda värdena.

    Använd detta istället för --uninstall + install när du vill bevara
    anpassade inställningar (t.ex. publiceras_geoserver, schema_uttryck)
    efter en versionsuppdatering av Hex.
    """
    print("=" * 60)
    print("Hex Uppgradering (bevarar inställningar)")
    print("=" * 60)
    print(f"Databas: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print("=" * 60)

    # Steg 1: Spara inställningar
    print("Steg 1: Sparar inställningar...")
    conn = psycopg2.connect(**DB_CONFIG)
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()
    try:
        snapshot = snapshot_settings(cur)
    finally:
        cur.close()
        conn.close()

    # Steg 2: Avinstallera
    print("\nSteg 2: Avinstallerar...")
    uninstall()

    # Steg 3: Installera
    print("\nSteg 3: Installerar...")
    install(base_path)

    # Steg 4: Återställ inställningar
    print("\nSteg 4: Återställer inställningar...")
    conn = psycopg2.connect(**DB_CONFIG)
    conn.set_client_encoding('UTF8')
    cur = conn.cursor()
    try:
        restore_settings(cur, snapshot)
        conn.commit()
        print("=" * 60)
        print("Uppgradering klar – inställningar återställda.")
        print("=" * 60)
    except Exception as e:
        conn.rollback()
        print(f"MISSLYCKADES vid återställning av inställningar: {e}")
        print("Hex är installerat med förvalda värden. Återställ inställningar manuellt.")
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Hex Installation")
    parser.add_argument("--uninstall", action="store_true", help="Ta bort alla Hex-objekt")
    parser.add_argument(
        "--upgrade",
        action="store_true",
        help="Uppgradera Hex: spara inställningar, avinstallera, installera, återställ",
    )
    args = parser.parse_args()

    if args.uninstall:
        uninstall()
    elif args.upgrade:
        upgrade()
    else:
        install()


