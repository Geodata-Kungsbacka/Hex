#!/usr/bin/env python3
"""
Kör alla Hex-testsviter och skriver ut en samlad sammanfattning.

Användning:
    python3 tests/run_all_tests.py                 # kör allt
    python3 tests/run_all_tests.py --only sql      # bara SQL-sviterna
    python3 tests/run_all_tests.py --only python   # bara Python-sviterna
    python3 tests/run_all_tests.py -v              # visa utdata från varje svit

Anslutning styrs med standardvariablerna för libpq. Standardvärden nedan
matchar DATABASES i install_hex.py:

    PGDATABASE=hex_test PGUSER=postgres PGHOST=localhost PGPASSWORD=... \
        python3 tests/run_all_tests.py

Hex måste vara installerat i måldatabasen innan SQL-sviterna körs.

Avslutskod: 0 om alla sviter passerade, annars 1.

RESULTATKONVENTIONER
SQL-sviterna rapporterar på två sätt och båda tolkas här:
  1. NOTICE ... PASSED / GODKÄNT   respektive  WARNING ... FAILED / MISSLYCKAT
  2. En resultattabell med kolumnen status: PASS / FAIL / XFAIL

XFAIL betyder "förväntat fel" – att Hex korrekt blockerade något otillåtet –
och räknas som godkänt.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = TESTS_DIR.parent

# Sviter som behöver en riktig databas med Hex installerat
SQL_SUITES = sorted(p.name for p in TESTS_DIR.glob("*.sql"))

# Python-sviter körs som fristående unittest-skript
PYTHON_SUITES = sorted(
    p.name for p in TESTS_DIR.glob("test_*.py") if p.name != Path(__file__).name
)

# Rad i en resultattabell:  " 12 | PASS | ..."  eller  " 3 | namn | XFAIL | ..."
TABELL_RAD = re.compile(r"\|\s*(PASS|FAIL|XFAIL)\s*\|")

# NOTICE/WARNING-konventionen. Kräver psql-prefixet så att teckenförklaringar
# i sviternas rubriker ("NOTICE = PASSED/INFO, WARNING = FAILED") inte räknas.
NOTICE_PASS = re.compile(r"NOTICE:.*\b(PASSED|GODKÄNT)\b")
WARNING_FAIL = re.compile(r"WARNING:.*\b(FAILED|MISSLYCKAT|BUG)\b")


class Resultat:
    def __init__(self, namn):
        self.namn = namn
        self.passerade = 0
        self.misslyckade = 0
        self.xfail = 0
        self.exitkod = 0
        self.utdata = ""

    @property
    def ok(self):
        return self.exitkod == 0 and self.misslyckade == 0

    @property
    def antal(self):
        return self.passerade + self.misslyckade + self.xfail


def _psql_env():
    env = os.environ.copy()
    env.setdefault("PGDATABASE", "hex_test")
    env.setdefault("PGUSER", "postgres")
    env.setdefault("PGHOST", "localhost")
    return env


def kor_sql_svit(filnamn: str) -> Resultat:
    res = Resultat(filnamn)
    proc = subprocess.run(
        ["psql", "-q", "-v", "ON_ERROR_STOP=0", "-f", str(TESTS_DIR / filnamn)],
        capture_output=True,
        text=True,
        env=_psql_env(),
        cwd=PROJECT_ROOT,
    )
    res.exitkod = proc.returncode
    res.utdata = proc.stdout + proc.stderr

    for rad in res.utdata.splitlines():
        tabell = TABELL_RAD.search(rad)
        if tabell:
            status = tabell.group(1)
            if status == "PASS":
                res.passerade += 1
            elif status == "XFAIL":
                res.xfail += 1
            else:
                res.misslyckade += 1
            continue
        if NOTICE_PASS.search(rad):
            res.passerade += 1
        elif WARNING_FAIL.search(rad):
            res.misslyckade += 1

    # Ett SQL-fel betyder att sviten inte kördes klart, även om inget test
    # hann rapportera FAIL.
    if "ERROR:" in res.utdata:
        res.misslyckade += res.utdata.count("ERROR:")

    return res


def kor_python_svit(filnamn: str) -> Resultat:
    res = Resultat(filnamn)
    proc = subprocess.run(
        [sys.executable, str(TESTS_DIR / filnamn)],
        capture_output=True,
        text=True,
        env=_psql_env(),
        cwd=PROJECT_ROOT,
    )
    res.exitkod = proc.returncode
    res.utdata = proc.stdout + proc.stderr

    # unittest skriver "Ran N tests" och OK/FAILED till stderr
    matchning = re.search(r"^Ran (\d+) tests?", res.utdata, re.MULTILINE)
    antal = int(matchning.group(1)) if matchning else 0
    if res.exitkod == 0:
        res.passerade = antal
    else:
        fel = re.search(r"failures=(\d+)", res.utdata)
        errors = re.search(r"errors=(\d+)", res.utdata)
        res.misslyckade = int(fel.group(1) if fel else 0) + int(
            errors.group(1) if errors else 0
        ) or max(antal, 1)
        res.passerade = max(antal - res.misslyckade, 0)

    return res


def main():
    parser = argparse.ArgumentParser(description="Kör alla Hex-testsviter")
    parser.add_argument(
        "--only",
        choices=["sql", "python"],
        help="Kör bara en kategori av sviter",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Visa utdata från varje svit"
    )
    args = parser.parse_args()

    resultat = []

    if args.only != "python":
        print("=" * 72)
        print(f"SQL-sviter (databas: {_psql_env()['PGDATABASE']})")
        print("=" * 72)
        for namn in SQL_SUITES:
            print(f"  kör {namn} ...", flush=True)
            resultat.append(kor_sql_svit(namn))

    if args.only != "sql":
        print("=" * 72)
        print("Python-sviter")
        print("=" * 72)
        for namn in PYTHON_SUITES:
            print(f"  kör {namn} ...", flush=True)
            resultat.append(kor_python_svit(namn))

    print()
    print("=" * 72)
    print(f"{'SVIT':<34}{'PASS':>7}{'XFAIL':>7}{'FAIL':>7}   STATUS")
    print("=" * 72)
    for r in resultat:
        status = "OK" if r.ok else "MISSLYCKAD"
        print(
            f"{r.namn:<34}{r.passerade:>7}{r.xfail:>7}{r.misslyckade:>7}   {status}"
        )

    tot_pass = sum(r.passerade for r in resultat)
    tot_xfail = sum(r.xfail for r in resultat)
    tot_fail = sum(r.misslyckade for r in resultat)
    print("-" * 72)
    print(f"{'TOTALT':<34}{tot_pass:>7}{tot_xfail:>7}{tot_fail:>7}")
    print("=" * 72)

    misslyckade = [r for r in resultat if not r.ok]
    if args.verbose or misslyckade:
        for r in misslyckade:
            print()
            print(f"--- Utdata från {r.namn} (exitkod {r.exitkod}) ---")
            for rad in r.utdata.splitlines():
                if WARNING_FAIL.search(rad) or "ERROR:" in rad:
                    print(f"  {rad}")

    if args.verbose:
        for r in resultat:
            print()
            print(f"--- Fullständig utdata: {r.namn} ---")
            print(r.utdata)

    if misslyckade:
        print(f"\n{len(misslyckade)} svit(er) misslyckades.")
        return 1

    print(f"\nAlla {len(resultat)} sviter passerade.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
