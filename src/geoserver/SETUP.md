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

Om du redan har Hex installerat och bara vill lagga till triggern manuellt:

```sql
-- Kor som postgres-anvandaren i din databas
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

## Steg 3: Konfigurera miljovariabler

### Alternativ A: .env-fil (enklast for testning)

```cmd
cd C:\sokvag\till\Hex\src\geoserver
copy .env.example .env
notepad .env
```

Fyll i dina varden i `.env`:

```env
# PostgreSQL
HEX_PG_HOST=localhost
HEX_PG_PORT=5432
HEX_PG_DBNAME=geodata
HEX_PG_USER=postgres
HEX_PG_PASSWORD=ditt_postgres_losenord

# GeoServer
HEX_GS_URL=http://localhost:8080/geoserver
HEX_GS_USER=admin
HEX_GS_PASSWORD=ditt_geoserver_losenord

# JNDI-kopplingar
HEX_JNDI_sk0=java:comp/env/jdbc/db-devkarta.geodata_sk0_oppen
HEX_JNDI_sk1=java:comp/env/jdbc/db-devkarta.geodata_sk1_kommun

# Framtida prefix laggs till har:
# HEX_JNDI_sk3=java:comp/env/jdbc/db-prod.geodata_sk3_ngt
```

### Alternativ B: Systemvida miljovariabler (sakrare for produktion)

Satt variablerna via **System Properties > Advanced > Environment Variables > System variables**.

Fordelen: ingen `.env`-fil pa disk med losenord.

Alternativt via kommandotolken (som admin):

```cmd
setx /M HEX_PG_DBNAME "geodata"
setx /M HEX_PG_PASSWORD "ditt_postgres_losenord"
setx /M HEX_GS_USER "admin"
setx /M HEX_GS_PASSWORD "ditt_geoserver_losenord"
setx /M HEX_JNDI_sk0 "java:comp/env/jdbc/db-devkarta.geodata_sk0_oppen"
setx /M HEX_JNDI_sk1 "java:comp/env/jdbc/db-devkarta.geodata_sk1_kommun"
```

> **OBS:** `setx /M` satter systemvida variabler. Du maste starta om
> tjansten/terminalen for att andringarna ska ga igenom.

---

## Steg 4: Testa anslutningen

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
2026-02-13 10:00:00 [INFO] PostgreSQL: postgres@localhost:5432/geodata
2026-02-13 10:00:00 [INFO] GeoServer:  http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] JNDI-kopplingar:
2026-02-13 10:00:00 [INFO]   sk0 -> java:comp/env/jdbc/db-devkarta.geodata_sk0_oppen
2026-02-13 10:00:00 [INFO]   sk1 -> java:comp/env/jdbc/db-devkarta.geodata_sk1_kommun
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] Ansluten till GeoServer 2.26.x pa http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] Anslutningstest lyckat
```

**Felsok om det misslyckas:**

| Felmeddelande | Orsak | Losning |
|---|---|---|
| `Saknade miljovariabler: HEX_PG_DBNAME` | .env saknas eller oifylld | Fyll i .env enligt steg 3 |
| `Kan inte ansluta till GeoServer` | GeoServer ar inte igang | Starta GeoServer forst |
| `Autentisering misslyckades` | Fel anvandardnamn/losenord | Kontrollera HEX_GS_USER/PASSWORD |
| `connection refused` (PostgreSQL) | PostgreSQL ar inte igang | Kontrollera pg-tjansten |

---

## Steg 5: Testa manuellt (dry-run)

Kor lyssnaren i dry-run-lage for att se vad som hander utan att gora andringar:

**Terminal 1 - Starta lyssnaren:**
```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_listener.py --dry-run
```

**Terminal 2 - Skapa ett testschema i psql:**
```sql
CREATE SCHEMA sk0_kba_test;
```

**Forvantad utskrift i Terminal 1:**
```
[INFO] Mottog notifiering for schema: sk0_kba_test
[INFO]   Prefix: sk0 -> JNDI: java:comp/env/jdbc/db-devkarta.geodata_sk0_oppen
[INFO]   Steg 1: Skapar workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa workspace: sk0_kba_test
[INFO]   Steg 2: Skapar JNDI-datastore 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa JNDI-datastore: sk0_kba_test
[INFO]   Schema 'sk0_kba_test' publicerat till GeoServer
```

**Rensa testschemat:**
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

Avbryt lyssnaren med `Ctrl+C`.

---

## Steg 6: Testa pa riktigt

Upprepa steg 5, men UTAN `--dry-run`:

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

## Steg 7: Installera som Windows-tjanst

Nu nar vi vet att allt fungerar, installera det som en riktig tjanst.

### 7a. Installera tjansten

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

### 7b. Konfigurera ateranslutning vid krasch

Oppna `services.msc`, hitta **Hex GeoServer Schema Listener**, hogerklicka
och valj **Properties > Recovery**:

| Installning | Varde |
|---|---|
| First failure | Restart the Service |
| Second failure | Restart the Service |
| Subsequent failures | Restart the Service |
| Reset fail count after | 1 dag |
| Restart service after | 30 sekunder |

### 7c. Starta tjansten

```cmd
"C:\Users\admin.tobhol\AppData\Local\Programs\Python\Python314\python.exe" geoserver_service.py start
```

Eller via `services.msc`, eller:
```cmd
net start HexGeoServerListener
```

### 7d. Kontrollera status

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

## Steg 8: Verifiera hela flodet

Allt ska nu vara online. Testa hela kedjan:

```sql
-- I psql eller pgAdmin:
CREATE SCHEMA sk1_kba_parkering;
```

Kontrollera loggen:
```cmd
type C:\ProgramData\Hex\geoserver_listener.log
```

Kontrollera GeoServer:
- Workspace `sk1_kba_parkering` bor finnas
- Datastore `sk1_kba_parkering` med JNDI `java:comp/env/jdbc/db-devkarta.geodata_sk1_kommun`

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

### Lagga till nytt prefix (t.ex. sk3)

1. Skapa JNDI-resursen i GeoServers `context.xml`
2. Lagg till miljoariabel: `HEX_JNDI_sk3=java:comp/env/jdbc/server.database`
3. Starta om tjansten: `python geoserver_service.py restart`
4. Uppdatera SQL-funktionen `notifiera_geoserver()` sa att `sk3` inkluderas
   (andrad regex fran `^(sk[01])_` till `^(sk[013])_`)

### Andra JNDI-koppling

1. Andrade miljoariabel eller .env
2. Starta om tjansten

Befintliga workspaces/stores i GeoServer paverkas inte - andringar galler
bara nya scheman som skapas efter omstarten.
