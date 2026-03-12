# GeoServer Schema Listener - Installationsguide

Steg-för-steg guide för att installera och konfigurera den automatiska
GeoServer workspace/store-skaparen på Windows Server 2022.

---

## Översikt

Lyssnaren hanterar två riktningar automatiskt via var sin pg_notify-kanal.

**Skapande** — när du kör `CREATE SCHEMA sk0_kba_test`:

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

**Borttagning** — när du kör `DROP SCHEMA sk0_kba_test CASCADE`:

```
DROP SCHEMA sk0_kba_test CASCADE
        |
        v
[PostgreSQL Event Trigger]
notifiera_geoserver_borttagning()
        |
        v
pg_notify('geoserver_schema_drop', 'sk0_kba_test')
        |
        v
[Python Listener - Windows Service]
geoserver_listener.py
        |
        v
GeoServer REST API:
  DELETE /rest/workspaces/sk0_kba_test?recurse=true
    --> tar bort workspace + datastores + publicerade lager
```

Det säkerställer att GeoServer inte gör upprepade anrop mot ett schema
som inte längre existerar i databasen.

---

## Förutsättning: Installera Python (första gången på servern)

> **OBS:** Om detta är en server där Python inte tidigare installerats,
> måste du göra detta steg först. Hoppa över om Python redan är installerat
> och verifiera installationen nedan.

### Installera Python

1. Hämta Python från [python.org/downloads](https://www.python.org/downloads/)
2. Kör installationsprogrammet som **Administrator**
3. **VIKTIGT:** Kryssa i **"Install for all users"** innan du klickar Install

   Utan detta hamnar Python under `C:\Users\<ditt-namn>\AppData\...` vilket
   skapar problem när Windows-tjänsten körs under ett systemkonto.

### Verifiera installationen

Öppna en **Administrativ kommandotolk** och kör:

```cmd
py -c "import sys; print(sys.executable)"
```

Utskriften ska peka på `C:\Program Files\` eller liknande -
**utan ett användarnamn i sökvägen**:

```
C:\Program Files\Python314\python.exe   <- RÄTT (systemomfattande installation)
C:\Users\admin.tobhol\AppData\...       <- FEL (per-användare, installera om)
```

Om utskriften innehåller ett användarnamn: avinstallera Python och installera
om med **"Install for all users"** ikryssad, annars registreras Windows-tjänsten
under en användarspecifik sökväg som kan sluta fungera om
kontot byter namn eller tas bort.

---

## Steg 1: Installera Python-beroenden

Öppna en **Administrativ kommandotolk** (Command Prompt som admin).

Installationens filer ligger under `D:\Hex\src\geoserver`.

Kommandona här nedan använder `py` - Python Launcher for Windows, som
följer med varje Python-installation och alltid finns på `C:\Windows\py.exe`
oavsett var Python itself är installerat. Verifiera att den finns:

```cmd
py --version
```

Om `py` inte hittas, använd `where python` för att hitta din Python-installation
och ersätt `py` med den fullständiga sökvägen i kommandona nedan.

Installera beroenden:
```cmd
py -m pip install -r requirements.txt
```

Eller manuellt:
```cmd
py -m pip install psycopg2 requests python-dotenv pywin32
```

Kontrollera att allt installerades:
```cmd
py -m pip list | findstr /i "psycopg2 requests dotenv pywin32"
```

Du bör se något i stil med:
```
psycopg2          2.9.x
python-dotenv     1.x.x
pywin32           30x
requests          2.3x.x
```

> **OBS:** Om `psycopg2` inte går att installera (krav på C-kompilator),
> använd `psycopg2-binary` istället:
> ```cmd
> py -m pip install psycopg2-binary
> ```

---

## Steg 2: Installera SQL-komponenten via Hex

Om du kör Hex-installern (`install_hex.py`) installeras alla triggers
automatiskt som en del av installationsordningen. De relevanta filerna är:

| Fil | Syfte |
|---|---|
| `src/sql/03_functions/05_trigger_functions/notifiera_geoserver.sql` | Skickar pg_notify vid CREATE SCHEMA |
| `src/sql/04_triggers/notifiera_geoserver_trigger.sql` | Registrerar ovanstående trigger |
| `src/sql/03_functions/05_trigger_functions/notifiera_geoserver_borttagning.sql` | Skickar pg_notify vid DROP SCHEMA |
| `src/sql/04_triggers/notifiera_geoserver_borttagning_trigger.sql` | Registrerar ovanstående trigger |

> **VIKTIGT:** Samtliga triggers måste installeras i **varje** databas som
> ska övervakas. Kör `install_hex.py` en gång per databas, med rätt
> `dbname` i `DB_CONFIG`.

Om du redan har Hex installerat och bara vill lägga till dessa triggers manuellt:

```sql
-- Kör som postgres-användaren i VARJE databas som ska övervakas
-- 1. notifiera_geoserver.sql         (CREATE SCHEMA-funktion)
-- 2. notifiera_geoserver_trigger.sql (CREATE SCHEMA-trigger)
-- 3. notifiera_geoserver_borttagning.sql         (DROP SCHEMA-funktion)
-- 4. notifiera_geoserver_borttagning_trigger.sql (DROP SCHEMA-trigger)
```

**Verifiera att triggerna finns:**
```sql
SELECT evtname, evtevent, evttags
FROM pg_event_trigger
WHERE evtname IN (
    'notifiera_geoserver_trigger',
    'notifiera_geoserver_borttagning_trigger'
);
```

---

## Steg 3: Skapa dedikerade tjänstekonton

Lyssnaren behöver **inte** superuser-rättigheter i PostgreSQL och bör **inte**
använda `postgres`-kontot. Skapa istället dedikerade konton med minimala
rättigheter.

### PostgreSQL - Lyssnarroll

Lyssnaren gör bara tre saker mot PostgreSQL:

1. `LISTEN geoserver_schema` - prenumerera på kanalen för CREATE SCHEMA
2. `LISTEN geoserver_schema_drop` - prenumerera på kanalen för DROP SCHEMA
3. `SELECT 1` - keepalive var 5:e sekund

Detta kräver enbart `CONNECT`-rättighet på varje databas som ska övervakas:

```sql
-- Kör som postgres/superuser
CREATE ROLE hex_listener WITH LOGIN PASSWORD 'starkt_losenord_har';

-- Ge CONNECT på varje databas som lyssnaren ska övervaka
GRANT CONNECT ON DATABASE geodata_sk0 TO hex_listener;
GRANT CONNECT ON DATABASE geodata_sk1 TO hex_listener;
```

Ingen ytterligare rättighet behövs - `LISTEN` på en kanal är tillgängligt för
alla roller som kan ansluta till databasen.

> **IPv6:** Windows Server 2022 kan föredra IPv6 för `localhost`-uppslag (`::1`).
> Kontrollera att `pg_hba.conf` har poster för **båda** protokollen:
> ```
> host  all  hex_listener  127.0.0.1/32  scram-sha-256
> host  all  hex_listener  ::1/128       scram-sha-256
> ```
> Om du ser `connection refused` trots att PostgreSQL är igång, kontrollera detta.
> Du kan också sätta `HEX_PG_HOST=127.0.0.1` (IPv4) eller `HEX_PG_HOST=::1` (IPv6)
> i `.env` för att tvinga ett specifikt protokoll.

### GeoServer - REST API-användare

Lyssnaren anropar GeoServer REST API för att:

- Kontrollera om workspace/datastore redan finns (`GET`)
- Skapa workspace och JNDI-datastore (`POST`)
- Ta bort workspace med allt innehåll vid DROP SCHEMA (`DELETE ?recurse=true`)

Att skapa workspaces och datastores kräver **administratörsrättigheter** i
GeoServer. Det går inte att begränsa med finare granularitet i GeoServer REST API.

Skapa ett dedikerat administratörskonto i GeoServer istället för att använda
standardkontot `admin`:

1. Gå till **Security > Users/Groups** i GeoServer webbgränssnittet
2. Skapa en ny användare, t.ex. `hex_publisher`
3. Tilldela rollen **ADMIN**

> **OBS:** Ändra aldrig lösenordet på standardkontot `admin` utan att först
> verifiera att det nya kontot fungerar.

---

## Steg 4: Tillåt localhost i GeoServer CSRF-filter

GeoServer blockerar POST/PUT/DELETE-anrop från ursprung den inte känner igen.
Eftersom lyssnaren anropar GeoServer REST API från `localhost` måste vi
vitlista det i GeoServers `web.xml`.

**Hitta filen:**
```
<GeoServer-katalog>\webapps\geoserver\WEB-INF\web.xml
```

**Lägg till `localhost` i CSRF-vitlistan:**

```xml
<context-param>
    <param-name>GEOSERVER_CSRF_WHITELIST</param-name>
    <param-value>[din-geoserver-doman], localhost</param-value>
</context-param>
```

> **OBS:** Om parametern redan finns, lägg bara till `, localhost` i
> befintligt `<param-value>`. Starta om GeoServer efteråt.

---

## Steg 5: Konfigurera miljövariabler

### Alternativ A: .env-fil (enklast för testning)

```cmd
cd D:\Hex\src\geoserver
copy .env.example .env
notepad .env
```

Fyll i dina värden i `.env`:

```env
# PostgreSQL - delade standardvärden (använd INTE postgres-kontot)
HEX_PG_HOST=localhost
HEX_PG_PORT=5432
HEX_PG_USER=hex_listener
HEX_PG_PASSWORD=ditt_listener_losenord

# GeoServer (dedikerad admin-användare - använd INTE standardkontot admin)
HEX_GS_URL=http://localhost:8080/geoserver
HEX_GS_USER=hex_publisher
HEX_GS_PASSWORD=ditt_geoserver_losenord

# Databaser - en grupp per PostgreSQL-databas
HEX_DB_1_DBNAME=geodata_sk0
HEX_DB_1_JNDI_sk0=java:comp/env/jdbc/server.geodata_sk0

HEX_DB_2_DBNAME=geodata_sk1
HEX_DB_2_JNDI_sk1=java:comp/env/jdbc/server.geodata_sk1

# Framtida databaser läggs till här:
# HEX_DB_3_DBNAME=geodata_sk3
# HEX_DB_3_JNDI_sk3=java:comp/env/jdbc/server.geodata_sk3
```

Varje `HEX_DB_N_`-grupp måste ha ett `DBNAME` och minst en `JNDI_`-koppling.
HOST/PORT/USER/PASSWORD kan anges per databas om de skiljer sig från
standardvärdena ovan (t.ex. `HEX_DB_2_HOST=annan-server`).

#### E-postnotifieringar (valfritt)

Lyssnaren kan skicka e-post vid fel och återhämtning. Lägg till följande
i `.env` för att aktivera:

```env
HEX_SMTP_HOST=smtp.office365.com
HEX_SMTP_PORT=587
HEX_SMTP_USER=tjanstekonto@kungsbacka.se
HEX_SMTP_PASSWORD=losenord_har
HEX_SMTP_FROM=tjanstekonto@kungsbacka.se
HEX_SMTP_TO=mottagare@kungsbacka.se
```

| Variabel | Standard | Beskrivning |
|---|---|---|
| `HEX_SMTP_HOST` | `smtp.office365.com` | SMTP-server |
| `HEX_SMTP_PORT` | `587` | Port (STARTTLS) |
| `HEX_SMTP_USER` | *(krävs)* | Inloggning mot SMTP-servern |
| `HEX_SMTP_PASSWORD` | *(krävs)* | Lösenord för SMTP-kontot |
| `HEX_SMTP_FROM` | `HEX_SMTP_USER` | Avsändaradress |
| `HEX_SMTP_TO` | *(sätter på/av)* | Mottagaradress - sätt denna för att aktivera |

**Notifieringar skickas vid:**
- Misslyckad schema-publicering till GeoServer (efter alla retry-försök)
- Misslyckad workspace-borttagning i GeoServer (efter alla retry-försök)
- Förlorad PostgreSQL-anslutning
- Oväntade fel i lyssnaren
- Lyckad återanslutning efter avbrott (så du vet att saker fungerar igen)

Samma ämne skickas max var 5:e minut för att undvika spam vid långvariga avbrott.

Om `HEX_SMTP_TO` inte är satt (eller tom) är e-post helt avaktiverat och
lyssnaren fungerar exakt som tidigare.

### Alternativ B: Systemövergripande miljövariabler (säkrare för produktion)

Sätt variablerna via **System Properties > Advanced > Environment Variables > System variables**.

Fördelen: ingen `.env`-fil på disk med lösenord.

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

> **OBS:** `setx /M` sätter systemövergripande variabler. Du måste starta om
> tjänsten/terminalen för att ändringarna ska gå igenom.

---

## Steg 6: Testa anslutningen

Testa att lyssnaren kan nå både PostgreSQL och GeoServer:

```cmd
cd D:\Hex\src\geoserver
[Python-sökväg]\python.exe geoserver_listener.py --test
```

> **OBS – systemspecifikt Python-sökväg**
> Kommandot `py` (Windows Python Launcher) läser skriptets shebang-rad
> (`#!/usr/bin/env python3`) och letar upp `python3` i PATH. På servrar där
> Python installerats på en icke-standardiserad plats (t.ex. `D:\Python\`)
> kan detta leda till att Windows Store-stubben (`WindowsApps\python3.exe`)
> hittas istället – en platshållare som inte kan köra filer och ger felet
> *"Unable to create process using …\WindowsApps\python3.exe"*.
>
> **Lösning:** Anropa Python-tolken direkt med dess fulla sökväg:
>
> ```cmd
> D:\Python\python.exe geoserver_listener.py --test
> ```
>
> Rätt sökväg på den aktuella servern kan alltid verifieras med:
>
> ```cmd
> py -c "import sys; print(sys.executable)"
> ```

Förväntad utskrift:
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
2026-02-13 10:00:00 [INFO] Ansluten till GeoServer 2.26.x på http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] Anslutningstest lyckat
```

**Felsök om det misslyckas:**

| Felmeddelande | Orsak | Lösning |
|---|---|---|
| `Saknade miljövariabler: HEX_DB_1_DBNAME` | .env saknas eller ofylld | Fyll i .env enligt steg 5 |
| `Kan inte ansluta till GeoServer` | GeoServer är inte igång | Starta GeoServer först |
| `Autentisering misslyckades` | Fel användarnamn/lösenord | Kontrollera HEX_GS_USER/PASSWORD |
| `connection refused` (PostgreSQL) | PostgreSQL är inte igång | Kontrollera pg-tjänsten |

---

## Steg 7: Testa manuellt (dry-run)

Kör lyssnaren i dry-run-läge för att se vad som händer utan att göra ändringar:

**Terminal 1 - Starta lyssnaren** (från `D:\Hex\src\geoserver`):
```cmd
[Python-sökväg]\python.exe geoserver_listener.py --dry-run
```

**Terminal 2 - Skapa ett testschema i psql (anslut till en av databaserna):**
```sql
-- Anslut till databasen som har triggern installerad
-- t.ex. psql -d geodata_sk0
CREATE SCHEMA sk0_kba_test;
```

**Förväntad utskrift i Terminal 1 (skapande):**
```
[INFO] [geodata_sk0] Mottog notifiering för schema: sk0_kba_test
[INFO] [geodata_sk0]   Prefix: sk0 -> JNDI: java:comp/env/jdbc/server.geodata_sk0
[INFO] [geodata_sk0]   Steg 1: Skapar workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa workspace: sk0_kba_test
[INFO] [geodata_sk0]   Steg 2: Skapar JNDI-datastore 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa JNDI-datastore: sk0_kba_test
[INFO] [geodata_sk0]   Schema 'sk0_kba_test' publicerat till GeoServer
```

**Testa även borttagning — Terminal 2:**
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

**Förväntad utskrift i Terminal 1 (borttagning):**
```
[INFO] [geodata_sk0] Mottog borttagningsnotifiering för schema: sk0_kba_test
[INFO] [geodata_sk0]   Tar bort workspace 'sk0_kba_test' från GeoServer...
[INFO]   [DRY-RUN] Skulle ta bort workspace (inkl. datastores/lager): sk0_kba_test
[INFO]   [DRY-RUN] DELETE .../workspaces/sk0_kba_test?recurse=true
[INFO] [geodata_sk0]   Schema 'sk0_kba_test' avpublicerat från GeoServer
```

Avbryt lyssnaren med `Ctrl+C`.

---

## Steg 8: Testa på riktigt

Upprepa steg 7, men UTAN `--dry-run`:

```cmd
[Python-sökväg]\python.exe geoserver_listener.py
```

Skapa schemat och verifiera i GeoServer:
1. Gå till http://localhost:8080/geoserver/web/
2. Klicka på **Workspaces** i vänstermenyn
3. Du bör se `sk0_kba_test` i listan
4. Klicka på den, sedan **Stores** — du bör se en JNDI-store med samma namn

Testa sedan borttagning:
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

Kontrollera i GeoServer att workspace `sk0_kba_test` är borta.
Loggen ska visa att DELETE-anropet lyckades.

---

## Steg 9: Installera som Windows-tjänst

Nu när vi vet att allt fungerar, installera det som en riktig tjänst.

### 9a. Installera tjänsten

Öppna en **Administrativ kommandotolk** och kör:

```cmd
cd D:\Hex\src\geoserver
[Python-sökväg]\python.exe geoserver_service.py install
```

Förväntad utskrift:
```
Installing service HexGeoServerListener
Service installed
```

### 9b. Konfigurera återställning vid krasch

Öppna `services.msc`, hitta **Hex GeoServer Schema Listener**, högerklicka
och välj **Properties > Recovery**:

| Inställning | Värde |
|---|---|
| First failure | Take No Action |
| Second failure | Take No Action |
| Subsequent failures | Take No Action |

Tjänsten startas **inte** om automatiskt vid krasch — återstart sker manuellt
efter felsökning. Starttypen ska vara **Automatic** (sätts under fliken
**General > Startup type**) så att tjänsten startar vid serveromstart.

### 9c. Starta tjänsten

```cmd
[Python-sökväg]\python.exe geoserver_service.py start
```

Eller via `services.msc`, eller:
```cmd
net start HexGeoServerListener
```

### 9d. Kontrollera status

```cmd
[Python-sökväg]\python.exe geoserver_service.py status
```

Kontrollera loggfilen:
```cmd
type D:\ProgramData\Hex\geoserver_listener.log
```

Eller följ loggen i realtid:
```cmd
powershell Get-Content D:\ProgramData\Hex\geoserver_listener.log -Wait -Tail 20
```

---

## Steg 10: Verifiera hela flödet

Allt ska nu vara online. Testa hela kedjan:

```sql
-- I psql eller pgAdmin, anslut till databasen med sk1-triggern
-- t.ex. psql -d geodata_sk1
CREATE SCHEMA sk1_kba_parkering;
```

Kontrollera loggen:
```cmd
type D:\ProgramData\Hex\geoserver_listener.log
```

Kontrollera GeoServer:
- Workspace `sk1_kba_parkering` bör finnas
- Datastore `sk1_kba_parkering` med rätt JNDI-koppling för sk1

---

## Hantera tjänsten

| Kommando | Beskrivning |
|---|---|
| `python geoserver_service.py start` | Starta |
| `python geoserver_service.py stop` | Stoppa |
| `python geoserver_service.py restart` | Starta om (t.ex. efter konfigändring) |
| `python geoserver_service.py status` | Visa status |
| `python geoserver_service.py remove` | Avinstallera tjänsten |
| `net start HexGeoServerListener` | Starta (alternativ) |
| `net stop HexGeoServerListener` | Stoppa (alternativ) |

Tjänsten startar automatiskt med Windows om du ställt in det i services.msc
(Startup type: Automatic).

---

## Loggfiler

| Fil | Beskrivning |
|---|---|
| `D:\ProgramData\Hex\geoserver_listener.log` | Huvudlogg (standardsökväg) |
| Windows Event Viewer > Application | Start/stopp-händelser |

Loggen roterar automatiskt vid 5 MB (5 gamla filer sparas).

### Anpassa loggkatalogen med HEX_LOG_DIR

Loggfilens plats styrs av miljövariabeln `HEX_LOG_DIR`. Om den inte är satt
används standardvärdet `D:\ProgramData\Hex`.

Sätt den i `.env` för att lägga loggen nära övriga installationsfiler:

```env
HEX_LOG_DIR=D:\Hex\src\geoserver\logs
```

Katalogen skapas automatiskt om den inte finns. Den exakta sökvägen loggas
vid uppstart:

```
[INFO] Loggfil: D:\Hex\src\geoserver\logs\geoserver_listener.log
```

> **OBS:** Kommandona för att läsa loggen i steg 9d och 10 nedan använder
> standardsökvägen `D:\ProgramData\Hex`. Ersätt med din sökväg om du har
> satt `HEX_LOG_DIR`.

---

## Framtida anpassningar

### Lägga till en ny databas (t.ex. sk3)

1. Installera event-triggern `notifiera_geoserver` i den nya databasen
2. Skapa JNDI-resursen i GeoServers `context.xml`
3. Lägg till en ny databasgrupp i `.env`:
   ```env
   HEX_DB_3_DBNAME=geodata_sk3
   HEX_DB_3_JNDI_sk3=java:comp/env/jdbc/server.geodata_sk3
   ```
4. Uppdatera SQL-funktionen `notifiera_geoserver()` så att `sk3` inkluderas
   (ändrad regex från `^(sk[01])_` till `^(sk[013])_`)
5. Starta om tjänsten: `python geoserver_service.py restart`

### Lägga till eller byta JNDI-anslutningsanvändare

JNDI-poolens databasanvändare (t.ex. `r_sk0_global_pub`) är den roll som
GeoServer faktiskt ansluter med mot PostgreSQL. Följande steg krävs när du
skapar en ny sådan roll eller byter ut en befintlig.

#### 1. Skapa rollen i PostgreSQL och ge den grupprättigheter

```sql
-- Kör som postgres i rätt databas (t.ex. [databas])
CREATE ROLE r_sk0_global_pub WITH LOGIN PASSWORD 'starkt_losenord_har';
GRANT r_sk0_global TO r_sk0_global_pub;
```

Rollen ärver alla schema- och tabellrättigheter via gruppollen (`r_sk0_global`).
Om scheman skapades innan gruppollen fick dessa rättigheter, kör migrationen
`src/sql/migrationer/01_reparera_pub_roller.sql` i rätt databas för att backfilla.

#### 2. Registrera lösenordskontot i localusers.txt

> **Gäller endast lösenordsbaserade konton** — AD-användare (Windows-autentisering)
> hanteras av domänkontrollanten och ska inte läggas här.

Lägg till rollen i `localusers.txt` så att lösenordskontot är spårbart och
inte faller bort vid nästa genomgång av databasanvändare:

```
r_sk0_global_pub   # JNDI-pool för GeoServer sk0-databas
r_sk1_global_pub   # JNDI-pool för GeoServer sk1-databas
```

#### 3. Lägg till rollen i pg_hba.conf

> **Gäller endast lösenordsbaserade konton** — AD-användare behöver inte detta.

Rader i `pg_hba.conf` är per login-roll och ärvs inte via gruppmedlemskap.
Varje ny `_pub`-roll måste ha en egen rad:

```
# GeoServer JNDI-pooler (GeoServer-serverns IP)
host    [databas_sk0]    r_sk0_global_pub    <geoserver_ip>/32    scram-sha-256
host    [databas_sk1]    r_sk1_global_pub    <geoserver_ip>/32    scram-sha-256
```

Ladda om PostgreSQL efter ändringen — ingen omstart krävs:

```sql
SELECT pg_reload_conf();
```

#### 4. Lägg till JNDI-resursen i geoserver.xml

Tomcat läser `D:\Tomcat\conf\Catalina\localhost\geoserver.xml` vid start.
Lägg till en ny `<Resource>`-post för varje ny anslutningspool:

```xml
<Resource name="jdbc/[server].[databas]"
          auth="Container"
          type="javax.sql.DataSource"
          driverClassName="org.postgresql.Driver"
          url="jdbc:postgresql://[pg-server]:5432/[databas]"
          username="r_sk0_global_pub" password="starkt_losenord_har"
          maxTotal="20"
          initialSize="0"
          minIdle="0"
          maxIdle="8"
          maxWaitMillis="10000"
          timeBetweenEvictionRunsMillis="30000"
          minEvictableIdleTimeMillis="60000"
          testWhileIdle="true"
          validationQuery="SELECT 1"
          rollbackOnReturn="true" />
```

JNDI-resursens `name` (utan `java:comp/env/`-prefix) måste matcha vad
GeoServers datastores refererar till. Kontrollera `.env`:

```
HEX_DB_1_JNDI_sk0=java:comp/env/jdbc/[server].[databas]
```

#### 5. Starta om Tomcat

`geoserver.xml` läses bara vid uppstart. Starta om Tomcat-tjänsten:

```cmd
net stop Tomcat9
net start Tomcat9
```

> **OBS:** Nya scheman som publiceras via lyssnaren kräver **inte** Tomcat-omstart
> — det är bara ändringar i `geoserver.xml` (nya pooler) som gör det.

---

### Ändra JNDI-koppling

1. Ändra miljövariabel eller .env
2. Starta om tjänsten

Befintliga workspaces/stores i GeoServer påverkas inte - ändringar gäller
bara nya scheman som skapas efter omstarten.

---

## Retry-beteende och felhantering

Lyssnaren har inbyggd retry-logik för transienta fel mot GeoServer:

| Parameter | Värde |
|---|---|
| Timeout per anrop | 30 sekunder |
| Max antal försök | 4 (1 + 3 retries) |
| Backoff-tider | 2s, 5s, 10s |
| Total max väntetid | ~2 minuter per anrop |

**Vad som ger retry:**
- Timeout (GeoServer svarar inte inom 30s)
- Anslutningsfel (GeoServer är nere eller onåtbart)

**Vad som INTE ger retry:**
- HTTP-felkoder (400, 401, 404, 500 etc.) - dessa returneras direkt
- Ogiltiga schemanamn, felaktig JNDI-konfiguration, etc.

Om alla retry-försök misslyckas loggas felet tydligt. Lyssnaren hoppar
sedan över notifieringen. För att försöka igen manuellt:

```sql
-- Kör som en användare med NOTIFY-rättighet i den aktuella databasen

-- Om ett schema skapades men workspace saknas i GeoServer:
NOTIFY geoserver_schema, 'sk0_ext_scb';

-- Om ett schema togs bort men workspace fortfarande finns i GeoServer:
NOTIFY geoserver_schema_drop, 'sk0_ext_scb';
```

Om e-postnotifieringar är konfigurerade skickas även ett mejl med
instruktioner för manuell åtgärd och den exakta NOTIFY-satsen att köra.
