#!/bin/bash
# Förbereder en Claude Code-webbsession så att testsviterna kan köras direkt.
#
# Containern saknar körande PostgreSQL-kluster, PostGIS och Python-beroenden vid
# start. Utan det här skriptet måste varje session sätta upp samma sak för hand
# innan tests/run_all_tests.py kan köras.
#
# Skriptet är idempotent: varje steg hoppas över om det redan är gjort.
set -euo pipefail

# Kör bara i fjärrmiljön (Claude Code på webben). Lokala miljöer har sin egen
# PostgreSQL-installation som skriptet inte ska röra.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Båda sätts av Claude Code. `:?` ger ett namngivet fel här uppe i stället för
# ett kryptiskt "unbound variable" på sista raden — dvs. efter att apt, klustret
# och Hex-installationen redan har gjort sitt jobb.
: "${CLAUDE_PROJECT_DIR:?sätts av Claude Code}"
: "${CLAUDE_ENV_FILE:?sätts av Claude Code}"

cd "$CLAUDE_PROJECT_DIR"

# Version och klusternamn läses av från basbilden i stället för att hårdkodas.
# Hex stöder PostgreSQL 16 och 17, och versionen styr tre saker som måste följas
# åt: sökvägen till postgis.control, paketnamnet och anropet till pg_ctlcluster.
PGVER=$(pg_lsclusters -h 2>/dev/null | awk 'NR==1 {print $1}')
PGCLUSTER=$(pg_lsclusters -h 2>/dev/null | awk 'NR==1 {print $2}')
if [ -z "$PGVER" ]; then
  echo "== Hex: hittade inget PostgreSQL-kluster (pg_lsclusters gav inget svar)" >&2
  exit 1
fi

TESTDB=hex_test
# Lokalt engångslösenord för den efemära containern. Klustret lyssnar bara på
# loopback och containern rivs när sessionen tar slut.
PGPASS=hex_local_dev

echo "== Hex: förbereder testmiljö =="

# 1. PostGIS. Serverpaketet finns i basbilden, men inte PostGIS-tillägget.
#    apt-indexet i bilden är gammalt nog att ge 404 på enskilda paket, så en
#    update måste köras först.
if [ ! -f "/usr/share/postgresql/$PGVER/extension/postgis.control" ]; then
  echo "-- installerar PostGIS för PostgreSQL $PGVER"
  # `|| true`: ett par PPA:er i basbilden når inte igenom agentproxyn och svarar
  # 403. apt rapporterar det som W: och avslutar med 0 i dag, men eskalerar till
  # E: i vissa lägen — och då skulle set -e döda hooken redan här, före
  # klusterstarten. Det är apt-get install nedan som avgör om vi fick PostGIS.
  apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "postgresql-$PGVER-postgis-3" >/dev/null
else
  echo "-- PostGIS finns redan"
fi

# 2. Python-beroenden för Python-sviterna och för installern.
if ! python3 -c "import psycopg2, requests" 2>/dev/null; then
  echo "-- installerar psycopg2-binary och requests"
  pip3 install --quiet --break-system-packages psycopg2-binary requests
else
  echo "-- Python-beroenden finns redan"
fi

# 3. Starta klustret. Det är nedstängt i en nystartad container.
if ! pg_isready -q 2>/dev/null; then
  echo "-- startar PostgreSQL-klustret"
  pg_ctlcluster "$PGVER" "$PGCLUSTER" start
  # pg_ctlcluster returnerar innan servern tar emot anslutningar.
  for _ in $(seq 1 30); do
    pg_isready -q && break
    sleep 1
  done
else
  echo "-- klustret är redan igång"
fi

# 4. Lösenord för postgres-rollen. Sviterna ansluter över TCP som root, och då
#    räcker inte peer-autentiseringen i pg_hba.conf.
su postgres -c "psql -qtAX -c \"ALTER ROLE postgres PASSWORD '$PGPASS'\"" >/dev/null

export PGHOST=localhost PGUSER=postgres PGPASSWORD="$PGPASS"

# 5. Testdatabasen.
if ! psql -qtAX -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$TESTDB'" | grep -q 1; then
  echo "-- skapar databasen $TESTDB"
  createdb "$TESTDB"
else
  echo "-- databasen $TESTDB finns redan"
fi

# 6. Hex. install() anropas direkt med en egen db-dict, så att DATABASES i
#    install_hex.py lämnas orörd — annars skulle hooken checka in ett lösenord
#    i en spårad fil vid varje sessionsstart.
#    Antalet event-triggers räknas fram ur src/sql/04_triggers/ i stället för att
#    hårdkodas. Med en hårdkodad siffra skulle en tillagd trigger göra villkoret
#    permanent uppfyllt, och Hex skulle installeras om vid varje sessionsstart.
FORVANTADE_TRIGGERS=$(grep -rhoiE 'CREATE[[:space:]]+EVENT[[:space:]]+TRIGGER' src/sql/04_triggers/ | wc -l)
INSTALLERADE_TRIGGERS=$(psql -qtAX -d "$TESTDB" -c "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex\_%'")
if [ "$INSTALLERADE_TRIGGERS" != "$FORVANTADE_TRIGGERS" ]; then
  echo "-- installerar Hex i $TESTDB"
  PGPASS="$PGPASS" TESTDB="$TESTDB" python3 - <<'PY' >/dev/null
import os
import install_hex

install_hex.install({
    "host": "localhost",
    "port": 5432,
    "dbname": os.environ["TESTDB"],
    "user": "postgres",
    "password": os.environ["PGPASS"],
    "owner_role": "gis_admin",
})
PY
else
  echo "-- Hex är redan installerat i $TESTDB"
fi

# 7. Anslutningsvariabler för resten av sessionen, så att både psql och
#    tests/run_all_tests.py hittar databasen utan extra flaggor.
#
#    Hooken körs vid varje sessionsstart — startup, resume, clear, compact och
#    fork — och filen skrivs med >>. Utan kontrollen nedan läggs samma fyra
#    rader till en gång per start. Den körs medvetet vid alla fem: klustret kan
#    ha hunnit dö mellan två starter, och då är det steg 3 som återstartar det.
if ! grep -q "^export PGDATABASE=$TESTDB\$" "$CLAUDE_ENV_FILE" 2>/dev/null; then
  {
    echo "export PGHOST=localhost"
    echo "export PGUSER=postgres"
    echo "export PGDATABASE=$TESTDB"
    echo "export PGPASSWORD=$PGPASS"
  } >> "$CLAUDE_ENV_FILE"
fi

echo "== Klart: $TESTDB är redo för tests/run_all_tests.py =="
