#!/usr/bin/env python3
"""
Hex Installer - runs SQL files in dependency order
Usage: 
    python install_hex.py              # Install
    python install_hex.py --uninstall  # Remove all Hex objects
"""

import argparse
import re
import psycopg2
from pathlib import Path

# =============================================================================
# CONFIGURATION
# =============================================================================

# Database connection
# OBS - must run as postgres to create event triggers
DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "your_database",
    "user": "postgres",
    "password": "your_password",
    "client_encoding": "UTF8",
}

# Owner role for all created objects (types, tables, functions, triggers)
# Set to None to use the connecting user as owner
OWNER_ROLE = "gis_admin"

# =============================================================================
# INSTALL ORDER
# =============================================================================

INSTALL_ORDER = [
    # Types
    "src/sql/01_types/geom_info.sql",
    "src/sql/01_types/kolumnkonfig.sql",
    "src/sql/01_types/kolumnegenskaper.sql",
    "src/sql/01_types/tabellregler.sql",
    # Tables
    "src/sql/02_tables/standardiserade_kolumner.sql",
    "src/sql/02_tables/standardiserade_roller.sql",
    "src/sql/02_tables/hex_metadata.sql",
    "src/sql/02_tables/hex_systemanvandare.sql",
    "src/sql/02_tables/hex_afvaktande_geometri.sql",
    # Functions - Structure
    "src/sql/03_functions/01_structure/hamta_geometri_definition.sql",
    "src/sql/03_functions/01_structure/hamta_kolumnstandard.sql",
    # Functions - Validation
    "src/sql/03_functions/02_validation/validera_tabell.sql",
    "src/sql/03_functions/02_validation/validera_vynamn.sql",
    "src/sql/03_functions/02_validation/validera_schemanamn.sql",
    "src/sql/03_functions/02_validation/validera_geometri.sql",
    # Functions - Rules
    "src/sql/03_functions/03_rules/spara_tabellregler.sql",
    "src/sql/03_functions/03_rules/spara_kolumnegenskaper.sql",
    "src/sql/03_functions/03_rules/aterskapa_tabellregler.sql",
    "src/sql/03_functions/03_rules/aterskapa_kolumnegenskaper.sql",
    # Functions - Utility
    "src/sql/03_functions/04_utility/byt_ut_tabell.sql",
    "src/sql/03_functions/04_utility/uppdatera_sekvensnamn.sql",
    "src/sql/03_functions/04_utility/skapa_historik_qa.sql",
    "src/sql/03_functions/04_utility/tilldela_rollrattigheter.sql",
    # Functions - Trigger functions
    "src/sql/03_functions/05_trigger_functions/hantera_ny_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_kolumntillagg.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_ny_vy.sql",
    "src/sql/03_functions/05_trigger_functions/ta_bort_schemaroller.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_standardiserade_roller.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_borttagen_tabell.sql",
    "src/sql/03_functions/05_trigger_functions/notifiera_geoserver.sql",
    # Triggers
    "src/sql/04_triggers/hantera_ny_tabell_trigger.sql",
    "src/sql/04_triggers/hantera_kolumntillagg_trigger.sql",
    "src/sql/04_triggers/hantera_ny_vy_trigger.sql",
    "src/sql/04_triggers/ta_bort_schemaroller_trigger.sql",
    "src/sql/04_triggers/hantera_standardiserade_roller_trigger.sql",
    "src/sql/04_triggers/hantera_borttagen_tabell_trigger.sql",
    "src/sql/04_triggers/validera_schemanamn_trigger.sql",
    "src/sql/04_triggers/notifiera_geoserver_trigger.sql",
]

# =============================================================================
# UNINSTALL - reverse order, DROP statements
# =============================================================================

UNINSTALL_SQL = """
-- Event Triggers (must be dropped first)
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_trigger;
DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger;
DROP EVENT TRIGGER IF EXISTS ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_borttagen_tabell_trigger;

-- Trigger Functions
DROP FUNCTION IF EXISTS public.notifiera_geoserver();
DROP FUNCTION IF EXISTS public.hantera_standardiserade_roller();
DROP FUNCTION IF EXISTS public.ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();
DROP FUNCTION IF EXISTS public.hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hantera_borttagen_tabell();

-- Utility Functions
DROP FUNCTION IF EXISTS public.tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.byt_ut_tabell(text, text, text);

-- Rules Functions
DROP FUNCTION IF EXISTS public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper);
DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, tabellregler);
DROP FUNCTION IF EXISTS public.spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.spara_tabellregler(text, text);

-- Validation Functions
DROP FUNCTION IF EXISTS public.validera_geometri(geometry, float) CASCADE;
DROP FUNCTION IF EXISTS public.validera_schemanamn();
DROP FUNCTION IF EXISTS public.validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.validera_tabell(text, text);

-- Structure Functions
DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, geom_info);
DROP FUNCTION IF EXISTS public.hamta_geometri_definition(text, text);

-- Config Functions
DROP FUNCTION IF EXISTS public.system_owner();

-- Tables
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.standardiserade_roller;
DROP TABLE IF EXISTS public.standardiserade_kolumner;

-- Types (must be dropped after functions that use them)
DROP TYPE IF EXISTS public.tabellregler;
DROP TYPE IF EXISTS public.kolumnegenskaper;
DROP TYPE IF EXISTS public.kolumnkonfig;
DROP TYPE IF EXISTS public.geom_info;
"""

# =============================================================================
# INSTALLER
# =============================================================================

def process_sql(sql: str) -> str:
    """Process SQL content - replace or strip OWNER TO statements.
    
    Event triggers must be owned by a superuser, so those keep postgres ownership.
    """
    # Event triggers and SECURITY DEFINER functions must keep superuser ownership
    needs_superuser = ('CREATE EVENT TRIGGER' in sql.upper() or
                       'SECURITY DEFINER' in sql.upper())

    if needs_superuser:
        # Keep postgres ownership for superuser-dependent objects
        return sql
    
    if not OWNER_ROLE:
        # Strip OWNER TO lines entirely
        lines = [line for line in sql.split('\n') if 'OWNER TO' not in line.upper()]
        return '\n'.join(lines)
    
    # Replace all OWNER TO with configured role
    return re.sub(r'OWNER TO \w+', f'OWNER TO {OWNER_ROLE}', sql, flags=re.IGNORECASE)


def uninstall():
    """Remove all Hex components from database."""
    print("=" * 60)
    print("Hex Uninstaller")
    print("=" * 60)
    print(f"Database: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print("=" * 60)
    
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    
    try:
        print("Removing Hex objects...")
        cur.execute(UNINSTALL_SQL)
        conn.commit()
        print("Uninstall complete.")
        print("+++melon melon melon+++")
    except Exception as e:
        conn.rollback()
        print(f"FAILED: {e}")
        raise
    finally:
        cur.close()
        conn.close()


def install(base_path="."):
    """Install all Hex components to database."""
    print("=" * 60)
    print("Hex Installer")
    print("=" * 60)
    print(f"Database: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print(f"Owner role: {OWNER_ROLE or '(connecting user)'}")
    print("=" * 60)
    
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    
    installed = 0
    
    try:
        # Ensure PostGIS is available
        print("Ensuring PostGIS extension...")
        cur.execute("CREATE EXTENSION IF NOT EXISTS postgis")
        
        # Validate OWNER_ROLE exists if specified
        owner_role = OWNER_ROLE or 'postgres'
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (owner_role,))
        if not cur.fetchone():
            raise ValueError(f"OWNER_ROLE '{owner_role}' does not exist in database")
        
        # Create system_owner() function dynamically
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
        print("Installing system_owner()...")
        cur.execute(system_owner_sql)
        installed += 1
        
        for sql_file in INSTALL_ORDER:
            path = Path(base_path) / sql_file
            if not path.exists():
                raise FileNotFoundError(f"Missing: {sql_file}")
            
            print(f"Installing {path.name}...")
            sql = process_sql(path.read_text(encoding='utf-8'))
            cur.execute(sql)
            installed += 1
        
        # Commit only after all succeed
        conn.commit()
        print("=" * 60)
        print(f"Installed {installed} components successfully.")
        print("=" * 60)
        print("+++Anthill Inside+++")
        
    except Exception as e:
        conn.rollback()
        print(f"FAILED: {e}")
        print("Transaction rolled back - no changes made.")
        print("+++Divide By Cucumber Error. Please Reinstall Universe And Reboot+++")
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Hex Installer")
    parser.add_argument("--uninstall", action="store_true", help="Remove all Hex objects")
    args = parser.parse_args()
    
    if args.uninstall:
        uninstall()
    else:
        install()


