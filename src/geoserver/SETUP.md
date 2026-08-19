# GeoServer Schema Listener - Installationsguide

Steg-för-steg guide för att installera och konfigurera den automatiska
GeoServer workspace/store-skaparen på Windows Server 2022.

---

## Stödda GeoServer-versioner

Lyssnaren är verifierad mot **GeoServer 2.27, 2.28 och 3.0** och använder samma
kodväg för alla tre. Vid uppstart loggas den anslutna versionen, och en varning
skrivs om den ligger utanför det intervallet — lyssnaren fortsätter ändå.

**Om du uppgraderar till GeoServer 3.x**, notera att det är GeoServer-servern
som ställer krav, inte lyssnaren:

| Krav | GeoServer 2.28 | GeoServer 3.0 |
| --- | --- | --- |
| Java | 17 eller 21 | 17 eller 21 |
| Servletmotor (WAR-distribution) | Tomcat 10.1 | **Tomcat 11.0** (Jakarta EE Servlet 6.1) |
| Fristående distribution | Jetty 10 | Jetty 12.1 |

Övrigt att känna till vid uppgradering till 3.x:

- **H2-datastoren är borttagen.** Berör inte Hex — lyssnaren skapar enbart
  PostGIS-datastores — men kontrollera om något lager publicerats manuellt mot H2.
- **WCS 1.0/1.1, WorldImage och ArcGRID är numera tillägg** och måste installeras
  separat om de används.
- **Keycloak- och OAuth2-tilläggen är avvecklade** och ersätts av ett gemensamt
  OIDC-tillägg. Om GeoServer-inloggningen går via något av dem: se till att
  kontot i `HEX_GS_USER` är ett lokalt konto i GeoServers egen användartjänst,
  så att lyssnaren kan logga in oavsett hur den federerade inloggningen migreras.
- **Loggplatsen** konfigureras inte längre i webbgränssnittet eller via REST,
  utan med `GEOSERVER_LOG_LOCATION`. Berör inte lyssnarens egen loggfil
  (`HEX_LOG_DIR`), bara GeoServers.

Datakatalogen (`data_dir`) behöver inte konverteras vid uppgraderingen, men
uppgraderingen är inte reversibel — ta en säkerhetskopia först.

---

## Översikt

Lyssnaren hanterar två riktningar automatiskt via var sin pg_notify-kanal.

**Skapande** — när du kör `CREATE SCHEMA sk0_kba_test`:

```
CREATE SCHEMA sk0_kba_test
        |
        v
[PostgreSQL Event Trigger 1]
hex_hantera_std_roller()
        |
        +--> CREATE ROLE r_sk0_kba_test NOLOGIN
        |    (läsbehörighetsgrupp – tilldelas AD-användare)
        +--> CREATE ROLE w_sk0_kba_test NOLOGIN
        |    (skrivbehörighetsgrupp – tilldelas AD-användare)
        +--> CREATE ROLE gs_r_sk0_kba_test WITH LOGIN PASSWORD '<autogenererat>'
        |    (GeoServer läs-tjänstekonto, ärver r_sk0_kba_test – SELECT)
        +--> CREATE ROLE gs_w_sk0_kba_test WITH LOGIN PASSWORD '<autogenererat>'
        |    (GeoServer skriv-tjänstekonto, ärver w_sk0_kba_test – ALL, möjliggör WFS-T)
        +--> INSERT INTO hex_rolluppgifter (rollnamn, losenord)
             (lösenorden sparas i databasen för lyssnaren att hämta)
        |
        v
[PostgreSQL Event Trigger 2]
hex_notifiera_gs()
        |
        v
pg_notify('geoserver_schema', 'sk0_kba_test')
        |
        v
[Python Listener - Windows Service]
geoserver_listener.py
        |
        +--> SELECT losenord FROM hex_rolluppgifter WHERE rollnamn = 'gs_r_sk0_kba_test'
        +--> SELECT losenord FROM hex_rolluppgifter WHERE rollnamn = 'gs_w_sk0_kba_test'
        |
        v
GeoServer REST API:
  Steg 1. POST /rest/workspaces
              --> läs-workspace "sk0_kba_test"
          PUT  /rest/namespaces/sk0_kba_test
              --> namespace URI satt
  Steg 2. POST /rest/workspaces/sk0_kba_test/datastores
              --> PostGIS-datastore "sk0_kba_test"
                  (direktanslutning med gs_r_sk0_kba_test – SELECT)
  Steg 3. POST /rest/workspaces
              --> skriv-workspace "sk0_kba_test_w"
          PUT  /rest/namespaces/sk0_kba_test_w
              --> namespace URI satt
  Steg 4. POST /rest/workspaces/sk0_kba_test_w/datastores
              --> PostGIS-datastore "sk0_kba_test_w"
                  (direktanslutning med gs_w_sk0_kba_test – ALL, möjliggör WFS-T)
  Steg 5. POST /rest/security/roles/role/r_sk0_kba_test
          POST /rest/security/roles/role/w_sk0_kba_test
              --> GeoServer-roller skapas (speglar PostgreSQL-behörighetsgrupperna)
  Steg 6. POST /rest/security/acl/layers
              --> sk0_kba_test.*.r = r_sk0_kba_test
                  (läsrollen, och ROLE_ANONYMOUS för sk0/anonym_las=true)
  Steg 7. POST /rest/security/acl/layers
              --> sk0_kba_test_w.*.r = w_sk0_kba_test
                  sk0_kba_test_w.*.w = w_sk0_kba_test
                  (skrivrollen styr åtkomst till WFS-T-workspacet)
```

> Rolltrigger och notifieringstrigger körs i ordning som en del av samma CREATE
> SCHEMA-transaktion. Lösenordet är alltid inskrivet i `hex_rolluppgifter`
> innan pg_notify når lyssnaren.

**Borttagning** — när du kör `DROP SCHEMA sk0_kba_test CASCADE`:

```
DROP SCHEMA sk0_kba_test CASCADE
        |
        v
[PostgreSQL Event Trigger]
hex_notifiera_gs_borttagning()
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
  Steg 1. DELETE /rest/security/acl/layers/sk0_kba_test.*.r
              --> ACL-regler för läs-workspace tas bort
  Steg 2. DELETE /rest/security/acl/layers/sk0_kba_test_w.*.r
          DELETE /rest/security/acl/layers/sk0_kba_test_w.*.w
              --> ACL-regler för skriv-workspace tas bort
  Steg 3. DELETE /rest/workspaces/sk0_kba_test?recurse=true
              --> läs-workspace + datastores + publicerade lager tas bort
  Steg 4. DELETE /rest/workspaces/sk0_kba_test_w?recurse=true
              --> skriv-workspace + datastores + publicerade lager tas bort
  Steg 5. DELETE /rest/security/roles/role/r_sk0_kba_test
          DELETE /rest/security/roles/role/w_sk0_kba_test
              --> GeoServer-roller tas bort
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

   > **Luftgapat nätverk?** Om servern inte har internetåtkomst: ladda ned
   > Python på en annan maskin och flytta över det till servern.
   >
   > **Viktigt:** Ladda ned exakt samma Python-version på båda maskinerna.
   > Version måste stämma överens för att du ska kunna ladda ned
   > Python-paket på den andra maskinen och flytta dem till servern (se Steg 1).
   > Kontrollera att de matchar:
   > ```cmd
   > py --version
   > ```
   > Utskriften ska vara identisk på båda maskinerna, t.ex. `Python 3.14.5`.

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
py -m pip install psycopg2-binary requests python-dotenv pywin32
```

> **Luftgapat nätverk?** Om servern inte kan nå internet, ladda ned paketen
> på en annan maskin och flytta dem till servern.
>
> **Förutsättning:** Båda maskinerna måste köra exakt samma Python-version
> (se avsnittet om Python-installation ovan). Kontrollera att de matchar
> innan du fortsätter:
> ```cmd
> py --version
> ```
>
> **På maskinen med internetåtkomst** — ladda ned paketen som färdiga wheel-filer:
> ```cmd
> py -m pip download psycopg2-binary requests python-dotenv pywin32 --only-binary=:all: -d C:\hex-wheels
> ```
>
> Kopiera mappen `C:\hex-wheels` till servern (t.ex. via USB eller fildelning).
>
> **På servern** — installera från de nedladdade filerna:
> ```cmd
> py -m pip install --no-index --find-links D:\hex-wheels psycopg2-binary requests python-dotenv pywin32
> ```

> **OBS:** `psycopg2-binary` används istället för `psycopg2` eftersom det är
> förpaketerat och inte kräver en C-kompilator — fungerar utan problem på Windows.

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

---

## Steg 2: Installera SQL-komponenten via Hex

Om du kör Hex-installern (`install_hex.py`) installeras alla triggers
automatiskt som en del av installationsordningen. De relevanta filerna är:

| Fil | Syfte |
|---|---|
| `src/sql/02_tables/hex_rolluppgifter.sql` | Tabell där lösenord för LOGIN-roller sparas |
| `src/sql/03_functions/05_trigger_functions/hex_hantera_std_roller.sql` | Skapar r_/w_-behörighetsgrupper och gs_r_/gs_w_-tjänstekonton med autogenererade lösenord vid CREATE SCHEMA |
| `src/sql/04_triggers/hex_hantera_std_roller_trigger.sql` | Registrerar ovanstående trigger |
| `src/sql/03_functions/05_trigger_functions/hex_notifiera_gs.sql` | Skickar pg_notify vid CREATE SCHEMA |
| `src/sql/04_triggers/hex_notifiera_gs_trigger.sql` | Registrerar ovanstående trigger |
| `src/sql/03_functions/05_trigger_functions/hex_notifiera_gs_borttagning.sql` | Skickar pg_notify vid DROP SCHEMA |
| `src/sql/04_triggers/hex_notifiera_gs_borttagning_trigger.sql` | Registrerar ovanstående trigger |

> **VIKTIGT:** Samtliga triggers måste installeras i **varje** databas som
> ska övervakas. Kör `install_hex.py` en gång per databas, med rätt
> `dbname` i `DB_CONFIG`.

Om du redan har Hex installerat och bara vill lägga till dessa triggers manuellt:

```sql
-- Kör som postgres-användaren i VARJE databas som ska övervakas
-- 1. hex_notifiera_gs.sql         (CREATE SCHEMA-funktion)
-- 2. hex_notifiera_gs_trigger.sql (CREATE SCHEMA-trigger)
-- 3. hex_notifiera_gs_borttagning.sql         (DROP SCHEMA-funktion)
-- 4. hex_notifiera_gs_borttagning_trigger.sql (DROP SCHEMA-trigger)
```

**Verifiera att triggerna finns:**
```sql
SELECT evtname, evtevent, evttags
FROM pg_event_trigger
WHERE evtname IN (
    'hex_hantera_std_roller_trigger',
    'hex_notifiera_gs_trigger',
    'hex_notifiera_gs_borttagning_trigger'
);
```

Du bör se tre rader. `hex_hantera_std_roller_trigger` körs alltid
**före** `hex_notifiera_gs_trigger` så att lösenordet redan finns i
`hex_rolluppgifter` när lyssnaren svarar på notifieringen.

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

`LISTEN` på en kanal är tillgängligt för alla roller som kan ansluta till
databasen. Lyssnaren behöver dessutom kunna läsa `hex_rolluppgifter` för
att hämta lösenordet till GeoServer-datastorens direktanslutning. Ge
rättigheten i **varje databas** som ska övervakas:

```sql
-- Kör i varje databas (t.ex. \c geodata_sk0 i psql)
GRANT SELECT ON public.hex_rolluppgifter TO hex_listener;
```

> **OBS:** Om du kör Hex-installern (`install_hex.py`) sätts denna rättighet
> automatiskt av `hex_rolluppgifter.sql` och behöver inte läggas till manuellt.

### pg_hba.conf — tillåt anslutningar

PostgreSQL tillåter inte nätverksanslutningar förrän det finns en matchande post i
`pg_hba.conf`. Två typer av roller behöver sådana poster:

**1. `hex_listener`** — Python-lyssnaren som prenumererar på `pg_notify`.

**2. `gs_r_<schema>`- och `gs_w_<schema>`-roller** — skapas automatiskt av `hex_hantera_std_roller()`
vid varje `CREATE SCHEMA`. GeoServer använder dessa LOGIN-tjänstekonton för direktanslutning till
varje PostGIS-datastore. (`r_*` och `w_*` är NOLOGIN-behörighetsgrupper för AD-användare och
används inte av GeoServer direkt.)

Alla dynamiskt skapade `gs_r_*`- och `gs_w_*`-roller läggs automatiskt till i
grupprollen **`hex_geoserver_roller`**. Rollen har inga egna rättigheter — den
fungerar enbart som autentiseringsmål i `pg_hba.conf`. Det innebär att en
`pg_hba.conf`-post kan referera till `+hex_geoserver_roller` för att täcka
alla Hex-skapade tjänstekonton utan att lista dem individuellt:

```
# Exempel — hur exakt du konfigurerar detta är upp till DBA:n
host  geodata_sk0  hex_listener        127.0.0.1/32  scram-sha-256
host  geodata_sk0  +hex_geoserver_roller  127.0.0.1/32  scram-sha-256
```

Det är upp till DBA:n att bestämma lämpligt scope (vilka databaser, vilken
adress/CIDR, vilken autentiseringsmetod) utifrån organisationens säkerhetspolicy.
Ladda om konfigurationen utan omstart:

```sql
SELECT pg_reload_conf();
```

> **Loopback-adresser och `localhost` på Windows Server**
>
> Använd alltid den **literala IP-adressen** i stället för hostnamnet `localhost`
> vid loopback-konfiguration. På moderna Windows-servrar kan `localhost` lösas
> upp till `::1` (IPv6) i stället för `127.0.0.1`, beroende på `hosts`-filens
> ordning och JVM/runtime-inställning. Det skapar ett svårupptäckt felläge:
>
> - Lyssnaren ansluter till `127.0.0.1` men PostgreSQL lyssnar på `::1`
>   → anslutning nekas, trots att PostgreSQL är igång.
> - Lyssnaren ansluter till `::1` men PostgreSQL lyssnar på `127.0.0.1`
>   → samma fel, omvänd riktning.
>
> **Rekommendation — välj ett protokoll och använd samma literala adress överallt:**
>
> - **IPv4 loopback:** Sätt `HEX_PG_HOST=127.0.0.1` i `.env`. Lägg till en
>   `pg_hba.conf`-post för `127.0.0.1/32`:
>   ```
>   host  all  hex_listener  127.0.0.1/32  scram-sha-256
>   ```
> - **IPv6 loopback:** Sätt `HEX_PG_HOST=::1` i `.env`. Lägg till en post
>   för `::1/128` i `pg_hba.conf`:
>   ```
>   host  all  hex_listener  ::1/128       scram-sha-256
>   ```
> - **Blanda aldrig:** Bind PostgreSQL till `127.0.0.1` men anslut via
>   `localhost` som löses till `::1` — det är exakt det felläge som ger
>   `connection refused` utan uppenbar anledning.
>
> Om felet kvarstår: kör `netstat -an | findstr 5432` för att se vilken
> adress PostgreSQL faktiskt lyssnar på, och verifiera att `.env` och
> `pg_hba.conf` använder samma adress.

### GeoServer - REST API-användare

Lyssnaren anropar GeoServer REST API för att:

- Kontrollera om workspace/datastore redan finns (`GET`)
- Skapa workspace och direkt PostGIS-datastore (`POST`)
- Skapa GeoServer-roller `gs_r_{schema}` och `gs_w_{schema}` (`POST /rest/security/roles/`)
- Sätta ACL-regler som ger rollerna tillgång till workspace (`POST /rest/security/acl/layers`)
- Ta bort ACL-regler, workspace och roller vid DROP SCHEMA (`DELETE`)

Att skapa workspaces, datastores, roller och ACL-regler kräver **administratörsrättigheter** i
GeoServer. Det går inte att begränsa med finare granularitet i GeoServer REST API.

Skapa ett dedikerat administratörskonto i GeoServer istället för att använda
standardkontot `admin`:

1. Gå till **Security > Users/Groups** i GeoServer webbgränssnittet
2. Skapa en ny användare, t.ex. `hex_publisher`
3. Tilldela rollen **ADMIN**

> **OBS:** Ändra aldrig lösenordet på standardkontot `admin` utan att först
> verifiera att det nya kontot fungerar.

---

## Steg 4: CSRF-filtret — behövs normalt inte för lyssnaren

> **Kort svar:** hoppa över det här steget. GeoServers CSRF-filter skyddar
> webbgränssnittet (Wicket), inte REST-API:et. Lyssnaren anropar bara REST.

Steget fanns tidigare med som obligatoriskt. Verifierat mot GeoServer 2.28.0
och 3.0.0 med standardkonfiguration — helt utan `GEOSERVER_CSRF_WHITELIST` —
lyckas samtliga skrivande REST-anrop (`POST`/`PUT`/`DELETE`), även när
`Host`-headern pekar på en helt främmande domän:

| Anrop | GeoServer 2.28.0 | GeoServer 3.0.0 |
| --- | --- | --- |
| `POST /rest/workspaces` | 201 | 201 |
| `DELETE /rest/workspaces/...?recurse=true` | 200 | 200 |

**Om du redan har `localhost` i vitlistan gör den ingen skada** — låt den ligga
kvar. Ta bara bort den om du städar konfigurationen, och testa lyssnaren
efteråt (steg 6).

**Vitlistan behövs däremot fortfarande** om *du själv* når GeoServers
webbgränssnitt via en proxy och får `403 Origin does not correspond to request`.
Det är ett separat problem från lyssnaren. Parametern finns kvar i GeoServer 3:

```xml
<context-param>
    <param-name>GEOSERVER_CSRF_WHITELIST</param-name>
    <param-value>[din-geoserver-doman]</param-value>
</context-param>
```

Den kan också sättas som systemegenskap (`-DGEOSERVER_CSRF_WHITELIST=...`)
eller miljövariabel.

---

## Steg 5: Konfigurera miljövariabler

### Alternativ A: .env-fil (enklast för testning)

```cmd
cd D:\Hex\src\geoserver
copy .env.example .env
notepad .env
```

> **Produktion:** lägg `.env` utanför kodkatalogen och peka ut den med den
> systemvida miljövariabeln `HEX_ENV_FILE`. Då kan installationsmappen bytas ut
> vid uppgradering utan att konfigurationen följer med — och utan att en öppen
> `.env` låser mappen. Se
> [09_installera-uppdatera-hex.md](../../docs/09_installera-uppdatera-hex.md#uppdatera-lyssnartjänsten-på-geoserver-servern).
>
> ```cmd
> setx /M HEX_ENV_FILE "D:\Hex\config\.env"
> ```

Fyll i dina värden i `.env`:

```env
# PostgreSQL - delade standardvärden (använd INTE postgres-kontot)
HEX_PG_HOST=localhost        # Rekommenderas: byt till 127.0.0.1 (IPv4) eller ::1 (IPv6)
HEX_PG_PORT=5432
HEX_PG_USER=hex_listener
HEX_PG_PASSWORD=ditt_listener_losenord

# GeoServer (dedikerad admin-användare - använd INTE standardkontot admin)
HEX_GS_URL=http://localhost:8080/geoserver  # Rekommenderas: byt till 127.0.0.1 (se not nedan)
HEX_GS_USER=hex_publisher
HEX_GS_PASSWORD=ditt_geoserver_losenord

# Databaser - en grupp per PostgreSQL-databas
HEX_DB_1_DBNAME=geodata_sk0

HEX_DB_2_DBNAME=geodata_sk1

# Framtida databaser läggs till här:
# HEX_DB_3_DBNAME=geodata_sk3
```

> **OBS – `localhost` kontra literal IP-adress:** På Windows Server rekommenderas
> att ersätta `localhost` med `127.0.0.1` (IPv4) för både `HEX_PG_HOST` och
> `HEX_GS_URL`. Se Steg 3 för förklaring av varför `localhost` kan orsaka
> anslutningsfel. (CSRF-vitlistan behöver inte hållas i synk med `HEX_GS_URL` —
> filtret gäller inte REST-API:et, se Steg 4.)

Varje `HEX_DB_N_`-grupp måste ha ett `DBNAME`. HOST/PORT/USER/PASSWORD kan anges
per databas om de skiljer sig från standardvärdena ovan (t.ex. `HEX_DB_2_HOST=annan-server`).

> **VIKTIGT — `HEX_PG_HOST` används av både lyssnaren och GeoServer:**
> Värdet på `HEX_PG_HOST` (och eventuella `HEX_DB_N_HOST`) gör dubbel tjänst.
> Det används dels av Python-lyssnaren för att ansluta och lyssna på pg_notify,
> dels bäddas det in ordagrant i varje PostGIS-datastore som skapas i GeoServer
> via REST API. Det innebär att GeoServer försöker nå PostgreSQL på exakt den
> adressen — från GeoServers eget nätverkskontext.
>
> - Om GeoServer och PostgreSQL **körs på samma server**: `127.0.0.1` fungerar
>   för båda.
> - Om de **körs på olika servrar**: sätt `HEX_PG_HOST` till det faktiska
>   nätverksnamnet eller IP-adressen som GeoServer-servern kan nå PostgreSQL på.
>   `127.0.0.1` från lyssnaren gör att GeoServer försöker ansluta till sig själv.

> **Datastore-autentisering:** Lyssnaren hämtar autentiseringsuppgifter för
> GeoServer-datastores direkt från tabellen `hex_rolluppgifter` i varje
> databas. Lösenorden genereras automatiskt av `hex_hantera_std_roller()`
> vid CREATE SCHEMA och kräver ingen manuell konfiguration.

#### Periodisk avstämning (valfritt)

Lyssnaren kör automatiskt en periodisk kontroll av GeoServer mot PostgreSQL. Om
en workspace eller datastore saknas (t.ex. för att någon manuellt tagit bort dem)
skapas de om automatiskt, och autentiseringsuppgifterna uppdateras alltid med
aktuella värden från `hex_rolluppgifter`.

Standardintervallet är **3600 sekunder (60 minuter)**. Ändra eller avaktivera med:

```env
HEX_RECONCILE_INTERVAL=3600   # sekunder mellan kontroller; 0 = avaktiverat
```

| Variabel | Standard | Beskrivning |
|---|---|---|
| `HEX_RECONCILE_INTERVAL` | `3600` | Intervall i sekunder (0 avaktiverar) |

> **OBS:** Periodisk avstämning skapar aldrig om publicerade lager (feature types)
> – enbart workspaces, datastores, GeoServer-roller och ACL-regler. Lager måste
> republiseras manuellt via GeoServer UI eller REST API.

#### Kvarlämnade workspaces (valfritt)

Avstämningen upptäcker även workspaces i GeoServer vars PostgreSQL-schema saknas
i samtliga övervakade databaser — t.ex. efter en ominstallation av databasen.
Standard är att bara logga en varning.

```env
HEX_ORPHAN_CLEANUP=off       # Endast varning i loggen (standard)
HEX_ORPHAN_CLEANUP=dry-run   # Loggar vad en uppstädning skulle ta bort
HEX_ORPHAN_CLEANUP=on        # Tar bort workspacen
```

| Variabel | Standard | Beskrivning |
|---|---|---|
| `HEX_ORPHAN_CLEANUP` | `off` | `off`, `dry-run` eller `on` |

Med `on` tas en workspace bort endast om den bevisligen är skapad av Hex: inga
raster-, WMS- eller WMTS-lagringar, och samtliga datastores är PostGIS mot en
övervakad databas och exponerar exakt det saknade schemat. En manuell
rasterpublicering vars namn råkar matcha schemamönstret rörs aldrig. Kör
`dry-run` först och läs loggen. Fullständig beskrivning finns i
[08_geoserver-lyssnaren.md](../../docs/08_geoserver-lyssnaren.md#kvarlämnade-workspaces-i-geoserver).

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
setx /M HEX_DB_2_DBNAME "geodata_sk1"
```

> **OBS:** `setx /M` sätter systemövergripande variabler. Du måste starta om
> tjänsten/terminalen för att ändringarna ska gå igenom.

---

## Steg 6: Testa anslutningen

Testa att lyssnaren kan nå både PostgreSQL och GeoServer:

```cmd
cd D:\Hex\src\geoserver
py geoserver_listener.py --test
```

> **OBS:** På servrar där Python installerats på en icke-standardiserad plats
> kan `py` leda till att Windows Store-stubben (`WindowsApps\python3.exe`)
> hittas istället för den riktiga tolken, vilket ger felet
> *"Unable to create process using …\WindowsApps\python3.exe"*.
>
> Verifiera rätt sökväg med:
> ```cmd
> py -c "import sys; print(sys.executable)"
> ```
> Anropa sedan Python-tolken direkt med den sökvägen:
> ```cmd
> D:\Program Files\Python\python.exe geoserver_listener.py --test
> ```

Förväntad utskrift:
```
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] GeoServer Schema Listener
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] GeoServer:  http://localhost:8080/geoserver
2026-02-13 10:00:00 [INFO] Anslutning: direkt PostGIS (autentiseringsuppgifter från hex_rolluppgifter)
2026-02-13 10:00:00 [INFO] Databaser:  2 st
2026-02-13 10:00:00 [INFO]   [geodata_sk0] hex_listener@localhost:5432/geodata_sk0
2026-02-13 10:00:00 [INFO]   [geodata_sk1] hex_listener@localhost:5432/geodata_sk1
2026-02-13 10:00:00 [INFO] ============================================================
2026-02-13 10:00:00 [INFO] Ansluten till GeoServer 2.28.0 på http://localhost:8080/geoserver
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
py geoserver_listener.py --dry-run
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
[INFO] [geodata_sk0]   Steg 1: Skapar läs-workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa workspace: sk0_kba_test
[INFO] [geodata_sk0]   Steg 2: Skapar läs-datastore 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa PG-datastore: sk0_kba_test (användare: gs_r_sk0_kba_test)
[INFO] [geodata_sk0]   Steg 3: Skapar skriv-workspace 'sk0_kba_test_w'...
[INFO]   [DRY-RUN] Skulle skapa workspace: sk0_kba_test_w
[INFO] [geodata_sk0]   Steg 4: Skapar skriv-datastore 'sk0_kba_test_w'...
[INFO]   [DRY-RUN] Skulle skapa PG-datastore: sk0_kba_test_w (användare: gs_w_sk0_kba_test)
[INFO] [geodata_sk0]   Steg 5: Skapar GeoServer-roller för 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa GeoServer-roll: r_sk0_kba_test
[INFO]   [DRY-RUN] Skulle skapa GeoServer-roll: w_sk0_kba_test
[INFO] [geodata_sk0]   Steg 6: Skapar ACL-regler för läs-workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle skapa ACL-regler för läs-workspace 'sk0_kba_test':
[INFO]   [DRY-RUN]   sk0_kba_test.*.r = r_sk0_kba_test
[INFO] [geodata_sk0]   Steg 7: Skapar ACL-regler för skriv-workspace 'sk0_kba_test_w'...
[INFO]   [DRY-RUN] Skulle skapa ACL-regler för skriv-workspace 'sk0_kba_test_w':
[INFO]   [DRY-RUN]   sk0_kba_test_w.*.r = w_sk0_kba_test
[INFO]   [DRY-RUN]   sk0_kba_test_w.*.w = w_sk0_kba_test
[INFO] [geodata_sk0]   Schema 'sk0_kba_test' publicerat till GeoServer
```

**Testa även borttagning — Terminal 2:**
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

**Förväntad utskrift i Terminal 1 (borttagning):**
```
[INFO] [geodata_sk0] Mottog borttagningsnotifiering för schema: sk0_kba_test
[INFO] [geodata_sk0]   Steg 1: Tar bort ACL-regler för läs-workspace 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle ta bort ACL-regler för workspace 'sk0_kba_test':
[INFO]   [DRY-RUN]   sk0_kba_test.*.r
[INFO]   [DRY-RUN]   sk0_kba_test.*.w
[INFO] [geodata_sk0]   Steg 2: Tar bort ACL-regler för skriv-workspace 'sk0_kba_test_w'...
[INFO]   [DRY-RUN] Skulle ta bort ACL-regler för workspace 'sk0_kba_test_w':
[INFO]   [DRY-RUN]   sk0_kba_test_w.*.r
[INFO]   [DRY-RUN]   sk0_kba_test_w.*.w
[INFO] [geodata_sk0]   Steg 3: Tar bort läs-workspace 'sk0_kba_test' från GeoServer...
[INFO]   [DRY-RUN] Skulle ta bort workspace (inkl. datastores/lager): sk0_kba_test
[INFO] [geodata_sk0]   Steg 4: Tar bort skriv-workspace 'sk0_kba_test_w' från GeoServer...
[INFO]   [DRY-RUN] Skulle ta bort workspace (inkl. datastores/lager): sk0_kba_test_w
[INFO] [geodata_sk0]   Steg 5: Tar bort GeoServer-roller för 'sk0_kba_test'...
[INFO]   [DRY-RUN] Skulle ta bort GeoServer-roll: r_sk0_kba_test
[INFO]   [DRY-RUN] Skulle ta bort GeoServer-roll: w_sk0_kba_test
[INFO] [geodata_sk0]   Schema 'sk0_kba_test' avpublicerat från GeoServer
```

Avbryt lyssnaren med `Ctrl+C`.

---

## Steg 8: Testa på riktigt

Upprepa steg 7, men UTAN `--dry-run`:

```cmd
py geoserver_listener.py
```

Skapa schemat och verifiera i GeoServer:
1. Gå till http://localhost:8080/geoserver/web/
2. Klicka på **Workspaces** — du bör se **både** `sk0_kba_test` (läs) och `sk0_kba_test_w` (skriv) i listan
3. Klicka på `sk0_kba_test`, sedan **Stores** — du bör se en PostGIS-datastore med rollen `gs_r_sk0_kba_test`
4. Klicka på `sk0_kba_test_w`, sedan **Stores** — du bör se en PostGIS-datastore med rollen `gs_w_sk0_kba_test`
5. Gå till **Security > Users/Groups/Roles** — du bör se rollerna `r_sk0_kba_test` och `w_sk0_kba_test`
6. Gå till **Security > Data** — du bör se:
   - `sk0_kba_test.*.r = r_sk0_kba_test` (och ev. `ROLE_ANONYMOUS` för sk0)
   - `sk0_kba_test_w.*.r = w_sk0_kba_test`
   - `sk0_kba_test_w.*.w = w_sk0_kba_test`

Testa sedan borttagning:
```sql
DROP SCHEMA sk0_kba_test CASCADE;
```

Kontrollera i GeoServer att **båda** workspaces (`sk0_kba_test` och `sk0_kba_test_w`), roller och
ACL-regler är borta. Loggen ska visa att alla fem steg lyckades.

---

## Steg 9: Installera som Windows-tjänst

Nu när vi vet att allt fungerar, installera det som en riktig tjänst.

### 9a. Installera tjänsten

Öppna en **Administrativ kommandotolk** och kör:

```cmd
cd D:\Hex\src\geoserver
py geoserver_service.py install
```

Förväntad utskrift:
```
Installing service HexGeoServerListener
Service installed
```

### 9b. Konfigurera återställning vid krasch

Öppna `services.msc`, hitta **Hex GeoServer Schema Listener**, högerklicka
och välj **Properties**:

Starttypen ska vara **Automatic** (sätts under fliken
**General > Startup type**) så att tjänsten startar vid serveromstart.

Hör med din IT avdelning hur dom vill att tjänster sätts upp.

### 9c. Starta tjänsten

```cmd
py geoserver_service.py start
```

Eller via `services.msc`, eller:
```cmd
net start HexGeoServerListener
```

### 9d. Kontrollera status

```cmd
py geoserver_service.py status
```

Kontrollera loggfilen:
```cmd
type D:\Hex\Logs\hex_geoserver_listener.log
```

Eller följ loggen i realtid:
```cmd
powershell Get-Content D:\Hex\Logs\hex_geoserver_listener.log -Wait -Tail 20
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
type D:\Hex\Logs\hex_geoserver_listener.log
```

Kontrollera GeoServer:
- Båda workspaces bör finnas under **Workspaces**:
  - `sk1_kba_parkering` (läs) med datastore ansluten via `gs_r_sk1_kba_parkering`
  - `sk1_kba_parkering_w` (skriv/WFS-T) med datastore ansluten via `gs_w_sk1_kba_parkering`
- Rollerna `r_sk1_kba_parkering` och `w_sk1_kba_parkering` under **Security > Users/Groups/Roles**
- Under **Security > Data**:
  - `sk1_kba_parkering.*.r = r_sk1_kba_parkering`
  - `sk1_kba_parkering_w.*.r = w_sk1_kba_parkering`
  - `sk1_kba_parkering_w.*.w = w_sk1_kba_parkering`

---

## Hantera tjänsten

| Kommando | Beskrivning |
|---|---|
| `python geoserver_service.py start` | Starta |
| `python geoserver_service.py stop` | Stoppa |
| `python geoserver_service.py restart` | Starta om (t.ex. efter konfigändring) |
| `python geoserver_service.py status` | Visa status |
| `python geoserver_service.py update` | Skriv om registreringen (ny sökväg eller Python-tolk) |
| `python geoserver_service.py remove` | Avinstallera tjänsten |
| `net start HexGeoServerListener` | Starta (alternativ) |
| `net stop HexGeoServerListener` | Stoppa (alternativ) |

> **OBS:** Kommandona är verb utan bindestreck (pywin32:s `HandleCommandLine`,
> samma stil som `net start` och `sc`), medan `install_hex.py` använder
> argparse-flaggor (`--upgrade`, `--uninstall`).

Tjänsten startar automatiskt med Windows om du ställt in det i services.msc
(Startup type: Automatic).

**Uppdatera koden:** `stop` → byt filer → `start`. `remove` + `install` behövs
bara när registreringen ändras (sökväg, Python-tolk, tjänstnamn eller
uppgraderad pywin32). Fullständig rutin i
[09_installera-uppdatera-hex.md](../../docs/09_installera-uppdatera-hex.md#uppdatera-lyssnartjänsten-på-geoserver-servern).

---

## Loggfiler

| Fil | Beskrivning |
|---|---|
| `D:\Hex\Logs\hex_geoserver_listener.log` | Huvudlogg (standardsökväg) |
| Windows Event Viewer > Application | Start/stopp-händelser |

Loggen roterar vid midnatt och 14 dagars historik sparas.

### Anpassa loggkatalogen med HEX_LOG_DIR

Loggkatalogen styrs av miljövariabeln `HEX_LOG_DIR`. Om den inte är satt
används standardvärdet `D:\Hex\Logs`.

```env
HEX_LOG_DIR=D:\Hex\Logs
```

> **Lägg inte loggen i kodkatalogen.** Tjänsten håller loggfilen öppen medan den
> kör, vilket hindrar att katalogen byts ut vid en uppgradering. Standardvärdet
> ligger redan utanför `src\geoserver`.

Katalogen skapas automatiskt om den inte finns. Den exakta sökvägen loggas
vid uppstart:

```
[INFO] Loggfil: D:\Hex\Logs\hex_geoserver_listener.log
```

> **OBS:** Kommandona för att läsa loggen i steg 9d och 10 nedan använder
> standardsökvägen. Ersätt med din sökväg om du har satt `HEX_LOG_DIR`.

---

## Framtida anpassningar

### Lägga till en ny databas (t.ex. sk3)

1. Installera alla event-triggers i den nya databasen (enklast via `install_hex.py`):
   - `hex_hantera_std_roller` (skapar roller och lösenord)
   - `hex_notifiera_gs` (skickar CREATE-notifiering)
   - `hex_notifiera_gs_borttagning` (skickar DROP-notifiering)
2. Ge `hex_listener` nödvändiga rättigheter på den nya databasen:
   ```sql
   GRANT CONNECT ON DATABASE geodata_sk3 TO hex_listener;
   -- Kör i den nya databasen:
   GRANT SELECT ON public.hex_rolluppgifter TO hex_listener;
   ```
3. Lägg till en ny databasgrupp i `.env`:
   ```env
   HEX_DB_3_DBNAME=geodata_sk3
   ```
4. Starta om tjänsten: `python geoserver_service.py restart`

> Lyssnaren läser vilka scheman som ska publiceras till GeoServer direkt från
> `hex_standardiserade_skyddsnivaer` (`publiceras_geoserver = true`) vid uppstart.
> Ingen kodredigering krävs för att lägga till en ny skyddsnivå — lägg till
> raden i konfigurationstabellen så hanteras den automatiskt.

### Ändra datastore-autentisering

Autentiseringsuppgifter för GeoServer-datastores hanteras automatiskt av Hex:

- `hex_hantera_std_roller()` skapar `gs_r_{schema}` (läs) och `gs_w_{schema}` (skriv)
  med LOGIN och autogenererade lösenord vid varje CREATE SCHEMA
- Lösenorden sparas i `hex_rolluppgifter` och läses av lyssnaren vid
  datastore-skapandet — `gs_r_{schema}` för läs-workspacet och `gs_w_{schema}` för
  skriv-workspacet

Det finns normalt inget att konfigurera manuellt. Om du behöver återskapa
datastores för ett befintligt schema, skicka en manuell notifiering:

```sql
NOTIFY geoserver_schema, 'sk0_kba_mittschema';
```

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
- Ogiltiga schemanamn, saknade uppgifter i `hex_rolluppgifter`, autentiseringsfel mot GeoServer, etc.

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
