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
    # Typer
    "src/sql/01_types/geom_info.sql",
    "src/sql/01_types/kolumnkonfig.sql",
    "src/sql/01_types/kolumnegenskaper.sql",
    "src/sql/01_types/tabellregler.sql",
    # Tabeller
    "src/sql/02_tables/standardiserade_skyddsnivaer.sql",
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
    "src/sql/03_functions/04_utility/reparera_rad_triggers.sql",
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
DROP FUNCTION IF EXISTS public.system_owner();

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

        # Reparera rad-triggers på befintliga tabeller (separat steg så att
        # ett fel här aldrig rullar tillbaka huvudinstallationen).
        print("Reparerar rad-triggers på befintliga tabeller...")
        try:
            cur.execute(
                "SELECT schema_namn, tabell_namn, trigger_namn, atgard"
                " FROM public.reparera_rad_triggers()"
            )
            rows = cur.fetchall()
            conn.commit()
            created = [(s, t, tr) for s, t, tr, a in rows if a == "skapad"]
            if created:
                for s, t, tr in created:
                    print(f"  ✓ {s}.{t} → {tr}")
                print(f"  {len(created)} trigger(s) återkopplade.")
            else:
                print("  Inga triggers behövde återkopplas.")
        except Exception as repair_err:
            conn.rollback()
            print(f"  Varning: trigger-reparation misslyckades: {repair_err}")
            print("  Hex är installerat. Kör SELECT * FROM public.reparera_rad_triggers() manuellt.")

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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Hex Installation")
    parser.add_argument("--uninstall", action="store_true", help="Ta bort alla Hex-objekt")
    args = parser.parse_args()
    
    if args.uninstall:
        uninstall()
    else:
        install()


