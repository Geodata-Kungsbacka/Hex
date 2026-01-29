#!/usr/bin/env python3
"""
Praxis Installer - runs SQL files in dependency order
Usage: python install_praxis.py
"""

import psycopg2
from pathlib import Path

# =============================================================================
# CONFIGURATION
# =============================================================================

# Database connection
DB_CONFIG = {
    "host": "server",
    "port": 5432,
    "dbname": "database",
    "user": "user",
    "password": "password",
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
    # Functions - Structure
    "src/sql/03_functions/01_structure/hamta_geometri_definition.sql",
    "src/sql/03_functions/01_structure/hamta_kolumnstandard.sql",
    # Functions - Validation
    "src/sql/03_functions/02_validation/validera_tabell.sql",
    "src/sql/03_functions/02_validation/validera_vynamn.sql",
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
    "src/sql/03_functions/05_trigger_functions/skapa_ny_schemaroll_r.sql",
    "src/sql/03_functions/05_trigger_functions/skapa_ny_schemaroll_w.sql",
    "src/sql/03_functions/05_trigger_functions/ta_bort_schemaroller.sql",
    "src/sql/03_functions/05_trigger_functions/hantera_standardiserade_roller.sql",
    # Triggers
    "src/sql/04_triggers/hantera_ny_tabell_trigger.sql",
    "src/sql/04_triggers/hantera_kolumntillagg_trigger.sql",
    "src/sql/04_triggers/hantera_ny_vy_trigger.sql",
    "src/sql/04_triggers/ta_bort_schemaroller_trigger.sql",
    "src/sql/04_triggers/hantera_standardiserade_roller_trigger.sql",
]

# =============================================================================
# INSTALLER
# =============================================================================

def process_sql(sql: str) -> str:
    """Process SQL content - replace or strip OWNER TO statements."""
    lines = sql.split('\n')
    processed = []
    
    for line in lines:
        if 'OWNER TO' in line.upper():
            if OWNER_ROLE:
                # Replace postgres with configured owner
                import re
                line = re.sub(
                    r'OWNER TO \w+',
                    f'OWNER TO {OWNER_ROLE}',
                    line,
                    flags=re.IGNORECASE
                )
                processed.append(line)
            # else: skip the line entirely (owner defaults to connecting user)
        else:
            processed.append(line)
    
    return '\n'.join(processed)


def install(base_path="."):
    """Install all Praxis components to database."""
    print("=" * 60)
    print("Praxis Installer")
    print("=" * 60)
    print(f"Database: {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")
    print(f"Owner role: {OWNER_ROLE or '(connecting user)'}")
    print("=" * 60)
    
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    
    installed = 0
    failed = 0
    
    for sql_file in INSTALL_ORDER:
        path = Path(base_path) / sql_file
        if not path.exists():
            print(f"MISSING: {sql_file}")
            failed += 1
            continue
        
        print(f"Installing {path.name}...")
        try:
            sql = process_sql(path.read_text())
            cur.execute(sql)
            conn.commit()
            installed += 1
        except Exception as e:
            conn.rollback()
            print(f"  FAILED: {e}")
            failed += 1
            raise  # Stop on first error; remove this line to continue on errors
    
    cur.close()
    conn.close()
    
    print("=" * 60)
    print(f"Installed: {installed}")
    print(f"Failed: {failed}")
    print("=" * 60)


if __name__ == "__main__":
    install()