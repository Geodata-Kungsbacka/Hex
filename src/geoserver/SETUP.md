# GeoServer Schema Listener - Installationsguide

Steg-for-steg guide for att installera och konfigurera den automatiska
GeoServer workspace/store-skaparen pa Windows Server 2022.

---

## Oversikt

Nar du kor `CREATE SCHEMA sk0_kba_test` i PostgreSQL hander foljande:

```
CREATE SCHEMA sk0_kba_test
        |
        v
[PostgreSQL Event Trigger]
notifiera_geoserver()
        |
        v
pg_notify('geoserver_schema', 'sk0_kba_test')
        |
        v
[Python Listener - Windows Service]
geoserver_listener.py
        |
        v
GeoServer REST API:
  1. POST /rest/workspaces          --> workspace "sk0_kba_test"
  2. POST /rest/.../datastores      --> JNDI store "sk0_kba_test"
```

> **Tips:** Om Hex ligger pa en annan enhet an `C:` (t.ex. `D:`) maste du
> byta enhet forst innan `cd` fungerar. Anvand `cd /D D:\sokvag\till\Hex`
> eller skriv `D:` foljt av `cd \sokvag\till\Hex` i tva steg.

---

## Steg 1: Installera Python-beroenden

Oppna en **Administrativ kommandotolk** (Command Prompt som admin).

```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" -m pip install psycopg2 requests python-dotenv pywin32
```

Kontrollera att allt installerades:
```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" -m pip list | findstr /i "psycopg2 requests dotenv pywin32"
```

Du bor se nagot i stil med:
```
psycopg2          2.9.x
python-dotenv     1.x.x
pywin32           30x
requests          2.3x.x
```

> **OBS:** Om `psycopg2` inte gar att installera (krav pa C-kompilator),
> anvand `psycopg2-binary` istallet:
> ```cmd
> pip install psycopg2-binary
> ```

---

## Steg 2: Installera SQL-komponenten via Hex

Om du kor Hex-installern (`install_hex.py`) installeras triggern
automatiskt som en del av installationsordningen. De nya filerna ar:

- `src/sql/03_functions/05_trigger_functions/notifiera_geoserver.sql`
- `src/sql/04_triggers/notifiera_geoserver_trigger.sql`

> **VIKTIGT:** Event-triggern maste installeras i **varje** databas som
> ska overvakas. Kor `install_hex.py` en gang per databas, med ratt
> `dbname` i `DB_CONFIG`.

Om du redan har Hex installerat och bara vill lagga till triggern manuellt:

```sql
-- Kor som postgres-anvandaren i VARJE databas som ska overvakas
-- 1. Skapa funktionen (kopiera innehallet fran notifiera_geoserver.sql)
-- 2. Skapa triggern (kopiera innehallet fran notifiera_geoserver_trigger.sql)
```

**Verifiera att triggern finns:**
```sql
SELECT evtname, evtevent, evttags
FROM pg_event_trigger
WHERE evtname = 'notifiera_geoserver_trigger';
```

---

## Steg 3: Skapa dedikerade tjanstekonton

Lyssnaren behover **inte** superuser-rattigheter i PostgreSQL och bor **inte**
anvanda `postgres`-kontot. Skapa istallet dedikerade konton med minimala
rattigheter.

### PostgreSQL - Lyssnarroll

Lyssnaren gor bara tva saker mot PostgreSQL:

1. `LISTEN geoserver_schema` - prenumerera pa notify-kanalen
2. `SELECT 1` - keepalive var 5:e sekund

Detta kraver enbart `CONNECT`-rattighet pa varje databas som ska overvakas:

```sql
-- Kor som postgres/superuser
CREATE ROLE hex_listener WITH LOGIN PASSWORD 'starkt_losenord_har';

-- Ge CONNECT pa varje databas som lyssnaren ska overvaka
GRANT CONNECT ON DATABASE geodata_sk0 TO hex_listener;
GRANT CONNECT ON DATABASE geodata_sk1 TO hex_listener;
```

Ingen ytterligare rattighet behovs - `LISTEN` pa en kanal ar tillganligt for
alla roller som kan ansluta till databasen.

### GeoServer - REST API-anvandare

Lyssnaren anropar GeoServer REST API for att:

- Kontrollera om workspace/datastore redan finns (`GET`)
- Skapa workspace och JNDI-datastore (`POST`)

Att skapa workspaces och datastores kraver **administratorsrattigheter** i
GeoServer. Det gar inte att begransar med finare granularitet i GeoServer REST API.

Skapa ett dedikerat administratorskonto i GeoServer istallet for att anvanda
standardkontot `admin`:

1. Ga till **Security > Users/Groups** i GeoServer webbgranssnittet
2. Skapa en ny anvandare, t.ex. `hex_publisher`
3. Tilldela rollen **ADMIN**

> **OBS:** Andrade aldrig losenordet pa standardkontot `admin` utan att forst
> verifiera att det nya kontot fungerar.

---

## Steg 4: Tillat localhost i GeoServer CSRF-filter

GeoServer blockerar POST/PUT/DELETE-anrop fran origon den inte kanner igen.
Eftersom lyssnaren anropar GeoServer REST API fran `localhost` maste vi
vitlista det i GeoServers `web.xml`.

**Hitta filen:**
```
<GeoServer-katalog>\webapps\geoserver\WEB-INF\web.xml
```

**Lagg till `localhost` i CSRF-vitlistan:**

```xml
<context-param>
    <param-name>GEOSERVER_CSRF_WHITELIST</param-name>
    <param-value>[din-geoserver-doman], localhost</param-value>
</context-param>
```

> **OBS:** Om parametern redan finns, lagg bara till `, localhost` i
> befintligt `<param-value>`. Starta om GeoServer efterat.

---

## Steg 5: Konfigurera miljovariabler

### Alternativ A: .env-fil (enklast for testning)

```cmd
cd C:\sokvag\till\Hex\src\geoserver
copy .env.example .env
notepad .env
```

Fyll i dina varden i `.env`:

```env
# PostgreSQL - delade standardvarden (anvand INTE postgres-kontot)
HEX_PG_HOST=localhost
HEX_PG_PORT=5432
HEX_PG_USER=hex_listener
HEX_PG_PASSWORD=ditt_listener_losenord

# GeoServer (dedikerad admin-anvandare - anvand INTE standardkontot admin)
HEX_GS_URL=http://localhost:8080/geoserver
HEX_GS_USER=hex_publisher
HEX_GS_PASSWORD=ditt_geoserver_losenord

# Databaser - en grupp per PostgreSQL-databas
HEX_DB_1_DBNAME=geodata_sk0
HEX_DB_1_JNDI_sk0=java:comp/env/jdbc/server.geodata_sk0

HEX_DB_2_DBNAME=geodata_sk1
HEX_DB_2_JNDI_sk1=java:comp/env/jdbc/server.geodata_sk1

# Framtida databaser laggs till har:
# HEX_DB_3_DBNAME=geodata_sk3
# HEX_DB_3_JNDI_sk3=java:comp/env/jdbc/server.geodata_sk3
```

Varje `HEX_DB_N_`-grupp maste ha ett `DBNAME` och minst en `JNDI_`-koppling.
HOST/PORT/USER/PASSWORD kan anges per databas om de skiljer sig fran
standardvardena ovan (t.ex. `HEX_DB_2_HOST=annan-server`).

### Alternativ B: Systemvida miljovariabler (sakrare for produktion)

Satt variablerna via **System Properties > Advanced > Environment Variables > System variables**.

Fordelen: ingen `.env`-fil pa disk med losenord.

Alternativt via kommandotolken (som admin):

```cmd
setx /M HEX_PG_PASSWORD "ditt_listener_losenord"
setx /M HEX_GS_USER "hex_publisher"
setx /M HEX_GS_PASSWORD "ditt_geoserver_losenord"
setx /M HEX_DB_1_DBNAME "geodata_sk0"
setx /M HEX_DB_1_JNDI_sk0 "java:comp/env/jdbc/server.geodata_sk0"
setx /M HEX_DB_2_DBNAME "geodata_sk1"
setx /M HEX_DB_2_JNDI_sk1 "java:comp/env/jdbc/server.geodata_sk1"
```

> **OBS:** `setx /M` satter systemvida variabler. Du maste starta om
> tjansten/terminalen for att andringarna ska ga igenom.

---

## Steg 6: Testa anslutningen

Testa att lyssnaren kan na bade PostgreSQL och GeoServer:

```cmd
cd C:\sokvag\till\Hex\src\geoserver

"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_listener.py --test
```

Forvantad utskrift:
```
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] GeoServer Schema Listener
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] GeoServer:  http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] Databaser:  2 st
2026-02-13 10:00:00 [INFO]   [geodata_sk0] hex_listener@localhost:5432/geodata_sk0
2026-02-13 10:00:00 [INFO]     sk0 -> java:comp/env/jdbc/server.geodata_sk0
2026-02-13 10:00:00 [INFO]   [geodata_sk1] hex_listener@localhost:5432/geodata_sk1
2026-02-13 10:00:00 [INFO]     sk1 -> java:comp/env/jdbc/server.geodata_sk1
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] Ansluten till GeoServer 2.26.x pa http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] Anslutningstest lyckat
```

**Felsok om det misslyckas:**

| Felmeddelande | Orsak | Losning |
|---|---|---|
| `Saknade miljovariabler: HEX_DB_1_DBNAME` | .env saknas eller oifylld | Fyll i .env enligt steg 5 |
| `Kan inte ansluta till GeoServer` | GeoServer ar inte igang | Starta GeoServer forst |
| `Autentisering misslyckades` | Fel anvandardnamn/losenord | Kontrollera HEX_GS_USER/PASSWORD |
| `connection refused` (PostgreSQL) | PostgreSQL ar inte igang | Kontrollera pg-tjansten |

---

## Steg 7: Testa manuellt (dry-run)

Kor lyssnaren i dry-run-lage for att se vad som hander utan att gora andringar:

**Terminal 1 - Starta lyssnaren:**
```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_listener.py --dry-run
```

**Terminal 2 - Skapa ett testschema i psql (anslut till en av databaserna):**
```sql
-- Anslut till databasen som har triggern installerad
-- t.ex. psql -d geodata_sk0
CREATE SCHEMA sk0_kba_test;
```

**Forvantad utskrift i Terminal 1:**
```
[INFO] [geodata_sk0] Mottog notifiering for schema: sk0_kba_test
[INFO] [geodata_sk0]   Prefix: sk0 -> JNDI: java:comp/env/jdbc/server.geodata_sk0
[INFO] [geodata_sk0]   Steg 1: Skapar workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa workspace: sk0_kba_test
[INFO] [geodata_sk0]   Steg 2: Skapar JNDI-datastore 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa JNDI-datastore: sk0_kba_test
[INFO] [geodata_sk0]   Schema 'sk0_kba_test' publicerat till GeoServer
```

**Rensa testschemat:**
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

Avbryt lyssnaren med `Ctrl+C`.

---

## Steg 8: Testa pa riktigt

Upprepa steg 7, men UTAN `--dry-run`:

```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_listener.py
```

Skapa schemat igen och verifiera i GeoServer:
1. Ga till http://localhost:8080/geoserver/web/
2. Klicka pa **Workspaces** i vanstermenyn
3. Du bor se `sk0_kba_test` i listan
4. Klicka pa den, sedan **Stores** - du bor se en JNDI-store med samma namn

Rensa efterat:
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```
> Workspace i GeoServer tas inte bort automatiskt - det ar avsiktligt.

---

## Steg 9: Installera som Windows-tjanst

Nu nar vi vet att allt fungerar, installera det som en riktig tjanst.

### 9a. Installera tjansten

Oppna en **Administrativ kommandotolk** och kor:

```cmd
cd C:\sokvag\till\Hex\src\geoserver

"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_service.py install
```

Forvantad utskrift:
```
Installing service HexGeoServerListener
Service installed
```

### 9b. Konfigurera ateranslutning vid krasch

Oppna `services.msc`, hitta **Hex GeoServer Schema Listener**, hogerklicka
och valj **Properties > Recovery**:

| Installning | Varde |
|---|---|
| First failure | Restart the Service |
| Second failure | Restart the Service |
| Subsequent failures | Restart the Service |
| Reset fail count after | 1 dag |
| Restart service after | 30 sekunder |

### 9c. Starta tjansten

```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_service.py start
```

Eller via `services.msc`, eller:
```cmd
net start HexGeoServerListener
```

### 9d. Kontrollera status

```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_service.py status
```

Kontrollera loggfilen:
```cmd
type C:\ProgramData\Hex\geoserver_listener.log
```

Eller folj loggen i realtid:
```cmd
powershell Get-Content C:\ProgramData\Hex\geoserver_listener.log -Wait -Tail 20
```

---

## Steg 10: Verifiera hela flodet

Allt ska nu vara online. Testa hela kedjan:

```sql
-- I psql eller pgAdmin, anslut till databasen med sk1-triggern
-- t.ex. psql -d geodata_sk1
CREATE SCHEMA sk1_kba_parkering;
```

Kontrollera loggen:
```cmd
type C:\ProgramData\Hex\geoserver_listener.log
```

Kontrollera GeoServer:
- Workspace `sk1_kba_parkering` bor finnas
- Datastore `sk1_kba_parkering` med ratt JNDI-koppling for sk1

---

## Hantera tjansten

| Kommando | Beskrivning |
|---|---|
| `python geoserver_service.py start` | Starta |
| `python geoserver_service.py stop` | Stoppa |
| `python geoserver_service.py restart` | Starta om (t.ex. efter konfigandring) |
| `python geoserver_service.py status` | Visa status |
| `python geoserver_service.py remove` | Avinstallera tjansten |
| `net start HexGeoServerListener` | Starta (alternativ) |
| `net stop HexGeoServerListener` | Stoppa (alternativ) |

Tjansten startar automatiskt med Windows om du stallt in det i services.msc
(Startup type: Automatic).

---

## Loggfiler

| Fil | Beskrivning |
|---|---|
| `C:\ProgramData\Hex\geoserver_listener.log` | Huvudlogg |
| Windows Event Viewer > Application | Start/stopp-handelser |

Loggen roterar automatiskt vid 5 MB (5 gamla filer sparas).

Andra loggkatalogen med miljoariabeln `HEX_LOG_DIR`.

---

## Framtida anpassningar

### Lagga till en ny databas (t.ex. sk3)

1. Installera event-triggern `notifiera_geoserver` i den nya databasen
2. Skapa JNDI-resursen i GeoServers `context.xml`
3. Lagg till en ny databasgrupp i `.env`:
   ```env
   HEX_DB_3_DBNAME=geodata_sk3
   HEX_DB_3_JNDI_sk3=java:comp/env/jdbc/server.geodata_sk3
   ```
4. Uppdatera SQL-funktionen `notifiera_geoserver()` sa att `sk3` inkluderas
   (andrad regex fran `^(sk[01])_` till `^(sk[013])_`)
5. Starta om tjansten: `python geoserver_service.py restart`

### Andra JNDI-koppling

1. Andrade miljoariabel eller .env
2. Starta om tjansten

Befintliga workspaces/stores i GeoServer paverkas inte - andringar galler
bara nya scheman som skapas efter omstarten.
