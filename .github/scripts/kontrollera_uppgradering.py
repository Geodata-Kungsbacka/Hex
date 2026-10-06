#!/usr/bin/env python3
"""
Kontrollerar att `install_hex.upgrade()` tar en databas installerad med en
äldre Hex-version till samma tillstånd som en ny installation.

Används av jobbet `uppgradering` i .github/workflows/test_hex.yml, men går
lika bra att köra lokalt:

    python3 .github/scripts/kontrollera_uppgradering.py --bas ../hex-main

där `--bas` är en utcheckning av basversionen (t.ex. `git worktree add
../hex-main origin/main`). Anslutningen styrs med PGHOST, PGPORT, PGUSER och
PGPASSWORD.

Flödet:

  1. Den uppgraderade databasen: basversionen installeras, användardata från
     uppgradering_seed.sql läggs in, och `upgrade()` körs med den här
     versionen.
  2. Referensdatabasen: den här versionen installeras och samma data läggs in.
  3. Användarobjekten i sk-schemana jämförs: kolumner, constraints, index,
     triggers, genererade triggerfunktioner, ägare, rättigheter, radantal och
     Hex-registren. Skiljer de sig åt saknas en migrering – en befintlig
     databas ser efter `--upgrade` inte ut som en ny (se avsnittet om
     migreringar i CLAUDE.md).

Den uppgraderade databasen lämnas kvar så att testsviterna kan köras mot den
efteråt. Roller är klustergemensamma och jämförs därför inte; de syns ändå
via rättigheterna.
"""

import argparse
import difflib
import os
import subprocess
import sys
from pathlib import Path

import psycopg2

PROJEKT = Path(__file__).resolve().parents[2]
SEED = Path(__file__).resolve().parent / "uppgradering_seed.sql"

# Körs i en egen process med basversionens katalog som cwd, så att rätt
# install_hex.py och rätt src/sql/ används. Att importera två versioner av
# samma modul i en process går inte rent.
INSTALL_SKRIPT = """
import os, sys
import install_hex
cfg = dict(host=os.environ.get('PGHOST', 'localhost'),
           port=os.environ.get('PGPORT', '5432'),
           dbname=sys.argv[2], user=os.environ.get('PGUSER', 'postgres'),
           password=os.environ.get('PGPASSWORD'), owner_role='gis_admin')
getattr(install_hex, sys.argv[1])(cfg)
"""

# Ett objekt per rad, sorterat, så att en skillnad blir en läsbar diff.
# OID:er och tidsstämplar utelämnas – de skiljer sig alltid.
#
# Två avsiktliga skillnader mellan uppgraderad och ny databas undantas, båda
# beskrivna i docs/10_avinstallera-hex.md:
#   * CHECK-villkor som anropar hex_validera_geometri() försvinner med
#     DROP FUNCTION ... CASCADE och återskapas inte. Triggern
#     hex_kontrollera_geom gör samma kontroll och jämförs som vanligt.
#   * hex_ta_bort_dummy är transient och harmlös när dummyraden är borta;
#     underhållet återkopplar den bara där en dummyrad finns kvar.
FINGERAVTRYCK_SQL = r"""
WITH s AS (
    SELECT oid, nspname FROM pg_namespace WHERE nspname ~ '^sk[0-9x]_'
), rel AS (
    SELECT c.oid, s.nspname, c.relname, c.relkind, c.relowner, c.relacl
    FROM pg_class c JOIN s ON s.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S')
)
SELECT rad FROM (
    SELECT format('schema   %s ägare=%s acl=%s', s.nspname,
                  pg_get_userbyid(n.nspowner),
                  (SELECT string_agg(a::text, ',' ORDER BY a::text)
                   FROM unnest(n.nspacl) a)) AS rad
    FROM s JOIN pg_namespace n ON n.oid = s.oid
  UNION ALL
    SELECT format('relation %s.%s typ=%s ägare=%s acl=%s', nspname, relname,
                  relkind, pg_get_userbyid(relowner),
                  (SELECT string_agg(a::text, ',' ORDER BY a::text)
                   FROM unnest(relacl) a))
    FROM rel
  UNION ALL
    SELECT format('kolumn   %s.%s #%s %s %s notnull=%s identity=%s default=%s',
                  rel.nspname, rel.relname,
                  lpad((row_number() OVER (PARTITION BY rel.oid ORDER BY a.attnum))::text, 3, '0'),
                  a.attname, format_type(a.atttypid, a.atttypmod),
                  a.attnotnull, a.attidentity,
                  pg_get_expr(d.adbin, d.adrelid))
    FROM rel
    JOIN pg_attribute a ON a.attrelid = rel.oid
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attnum > 0 AND NOT a.attisdropped AND rel.relkind <> 'S'
  UNION ALL
    SELECT format('villkor  %s.%s %s %s', rel.nspname, rel.relname,
                  con.conname, pg_get_constraintdef(con.oid))
    FROM rel JOIN pg_constraint con ON con.conrelid = rel.oid
    WHERE pg_get_constraintdef(con.oid) !~ 'hex_validera_geometri\('
  UNION ALL
    SELECT format('index    %s', pg_get_indexdef(i.indexrelid))
    FROM rel JOIN pg_index i ON i.indrelid = rel.oid
  UNION ALL
    SELECT format('trigger  %s', pg_get_triggerdef(t.oid))
    FROM rel JOIN pg_trigger t ON t.tgrelid = rel.oid
    WHERE NOT t.tgisinternal AND t.tgname <> 'hex_ta_bort_dummy'
  UNION ALL
    SELECT format('vy       %s.%s %s', nspname, relname,
                  pg_get_viewdef(oid))
    FROM rel WHERE relkind IN ('v', 'm')
  UNION ALL
    SELECT format('funktion %s.%s ägare=%s secdef=%s md5=%s', s.nspname,
                  p.proname, pg_get_userbyid(p.proowner), p.prosecdef,
                  md5(pg_get_functiondef(p.oid)))
    FROM pg_proc p JOIN s ON s.oid = p.pronamespace
  UNION ALL
    SELECT format('defacl   %s %s %s', s.nspname, d.defaclobjtype,
                  (SELECT string_agg(a::text, ',' ORDER BY a::text)
                   FROM unnest(d.defaclacl) a))
    FROM pg_default_acl d JOIN s ON s.oid = d.defaclnamespace
  UNION ALL
    SELECT format('hex_metadata %s.%s historik=%s.%s trigger=%s av=%s',
                  parent_schema, parent_table, history_schema, history_table,
                  trigger_funktion, created_by)
    FROM public.hex_metadata
  UNION ALL
    SELECT format('hex_afvaktande_geometri %s.%s av=%s',
                  schema_namn, tabell_namn, registrerad_av)
    FROM public.hex_afvaktande_geometri
) x
ORDER BY rad
"""


def _env():
    env = os.environ.copy()
    env.setdefault("PGHOST", "localhost")
    env.setdefault("PGUSER", "postgres")
    return env


def _anslut(dbname):
    conn = psycopg2.connect(dbname=dbname, **{
        k: v for k, v in {
            "host": os.environ.get("PGHOST", "localhost"),
            "port": os.environ.get("PGPORT"),
            "user": os.environ.get("PGUSER", "postgres"),
            "password": os.environ.get("PGPASSWORD"),
        }.items() if v
    })
    conn.set_client_encoding("UTF8")
    return conn


def _ny_databas(namn):
    conn = _anslut("postgres")
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{namn}" WITH (FORCE)')
        cur.execute(f'CREATE DATABASE "{namn}"')
    conn.close()


def _steg(rubrik):
    print(f"\n== {rubrik}", flush=True)


def _kor(argv, cwd):
    subprocess.run(argv, cwd=cwd, env=_env(), check=True)


def _installera(funktion, katalog, dbname):
    _kor([sys.executable, "-c", INSTALL_SKRIPT, funktion, dbname], katalog)


def _seed(dbname):
    _kor(["psql", "-q", "-X", "-d", dbname, "-f", str(SEED)], PROJEKT)


def _underhall(dbname):
    _kor(["psql", "-q", "-X", "-v", "ON_ERROR_STOP=1", "-d", dbname,
          "-o", os.devnull, "-c", "SELECT * FROM public.hex_underhall()"],
         PROJEKT)


def _radantal(cur):
    cur.execute("""
        SELECT n.nspname, c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname ~ '^sk[0-9x]_' AND c.relkind IN ('r', 'p')
    """)
    rader = []
    for schema, tabell in cur.fetchall():
        cur.execute(f'SELECT count(*) FROM "{schema}"."{tabell}"')
        rader.append(f"radantal {schema}.{tabell} = {cur.fetchone()[0]}")
    return rader


def fingeravtryck(dbname):
    conn = _anslut(dbname)
    try:
        with conn.cursor() as cur:
            cur.execute(FINGERAVTRYCK_SQL)
            rader = [r[0] for r in cur.fetchall()]
            rader += _radantal(cur)
        return sorted(rader)
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bas", required=True, type=Path,
                        help="Utcheckning av basversionen")
    parser.add_argument("--db", default="hex_uppgraderad",
                        help="Databasen som uppgraderas (lämnas kvar)")
    parser.add_argument("--referens", default="hex_referens",
                        help="Referensdatabas med ny installation")
    args = parser.parse_args()

    bas = args.bas.resolve()
    if not (bas / "install_hex.py").is_file():
        parser.error(f"{bas} saknar install_hex.py")

    _steg(f"Installerar basversionen i {args.db}")
    _ny_databas(args.db)
    _installera("install", bas, args.db)
    _seed(args.db)

    _steg(f"Uppgraderar {args.db} till den här versionen")
    _installera("upgrade", PROJEKT, args.db)

    _steg(f"Installerar den här versionen i {args.referens}")
    _ny_databas(args.referens)
    _installera("install", PROJEKT, args.referens)
    _seed(args.referens)
    # upgrade() avslutar med hex_underhall(), som bl.a. tar över ägarskapet
    # för vyer. Utan samma körning här skulle jämförelsen visa underhållets
    # effekt i stället för uppgraderingens.
    _underhall(args.referens)

    _steg("Jämför användarobjekten")
    uppgraderad = fingeravtryck(args.db)
    referens = fingeravtryck(args.referens)
    diff = list(difflib.unified_diff(
        referens, uppgraderad,
        fromfile=f"{args.referens} (ny installation)",
        tofile=f"{args.db} (uppgraderad från bas)",
        lineterm="",
    ))
    if diff:
        print("\n".join(diff))
        print(
            "\nUPPGRADERINGEN MISSLYCKADES: den uppgraderade databasen skiljer "
            "sig från en ny installation.\nRader med '-' finns bara i den nya "
            "installationen, rader med '+' bara i den uppgraderade.\n"
            "Saknas en HEX-MIGRERING? Se avsnittet om migreringar i CLAUDE.md."
        )
        return 1

    print(f"OK: {len(uppgraderad)} objekt identiska efter uppgraderingen.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
