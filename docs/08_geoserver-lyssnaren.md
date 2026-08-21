# Hantera GeoServer-lyssnaren

**Gäller:** Windows-tjänsten `HexGeoServerListener` som automatiskt publicerar
nya scheman till GeoServer.

---

## Bakgrund

När ett schema skapas skickar Hex en `pg_notify`. En Python-process lyssnar
på dessa notifieringar och skapar automatiskt två workspaces i GeoServer:

- **Läs-workspace** `{schema}` — ansluter med `gs_r_{schema}` (SELECT-behörighet).
  Används av WMS/WFS-läsanrop.
- **Skriv-workspace** `{schema}_w` — ansluter med `gs_w_{schema}` (ALL-behörighet).
  Används av WFS-T-transaktioner (Insert/Update/Delete) via GeoServer.

Varje workspace får en direkt PostGIS-datastore med rätt PostgreSQL-tjänstekonto.
Autentiseringsuppgifterna hämtas från tabellen `hex_rolluppgifter` där
`hex_hantera_std_roller()` lagrar de autogenererade lösenorden vid `CREATE SCHEMA`.

Vilka skyddsnivåer som publiceras styrs av kolumnen `publiceras_geoserver` i
tabellen `hex_standardiserade_skyddsnivaer` — standard är `sk0` och `sk1`.
Ändra tabellen för att justera vilka prefix som publiceras:

```sql
-- Aktivera publicering för sk2
UPDATE hex_standardiserade_skyddsnivaer
SET publiceras_geoserver = true
WHERE prefix = 'sk2';
```

Huruvida publicerade lager är läsbara utan inloggning styrs av kolumnen `anonym_las`.
När den är `true` läggs `ROLE_ANONYMOUS` till i GeoServers ACL-läsregel för läs-workspacet,
vilket tillåter anonyma WMS/WFS-anrop (t.ex. från Hajk). Skriv-workspacet `{schema}_w`
kräver alltid inloggning.
Standard är `true` för `sk0` (öppen publik data) och `false` för övriga prefix.
Förutsätter att åtkomst redan begränsas på nätverksnivå (t.ex. IP-vitlista i `web.xml`).

```sql
-- Tillåt anonym WMS/WFS-läsning för skx (utvecklingsdata)
UPDATE hex_standardiserade_skyddsnivaer
SET anonym_las = true
WHERE prefix = 'skx';

-- Kontrollera aktuell konfiguration
SELECT prefix, beskrivning, publiceras_geoserver, anonym_las
FROM hex_standardiserade_skyddsnivaer
ORDER BY prefix;
```

Lyssnaren laddar `anonym_las` per schema vid varje notifiering — ingen omstart krävs
för att nya scheman ska få rätt regel. Befintliga workspaces uppdateras automatiskt
vid nästa omstart av tjänsten (startavstämningen korrigerar avvikande ACL-regler).

Processen körs som en Windows-tjänst och startar automatiskt med servern.

---

## Vanliga uppgifter

### Starta, stoppa och starta om tjänsten

Öppna en **administrativ kommandotolk** i `<installationskatalog>\src\geoserver`:

```cmd
py geoserver_service.py start
py geoserver_service.py stop
py geoserver_service.py restart
```

Alternativt via Windows Services (`services.msc`) – tjänsten heter
**Hex GeoServer Schema Listener**.

### Kontrollera status

```cmd
py geoserver_service.py status
```

### Visa loggen

Loggens plats styrs av `.env`-variabeln `HEX_LOG_DIR` (standard:
`D:\Hex\Logs`):

```cmd
type %HEX_LOG_DIR%\hex_geoserver_listener.log
```

Följ loggen i realtid:
```cmd
powershell Get-Content "$env:HEX_LOG_DIR\hex_geoserver_listener.log" -Wait -Tail 20
```

Om `HEX_LOG_DIR` inte är satt som systemmiljövariabel, ersätt med den faktiska
sökvägen (t.ex. `D:\Hex\Logs\hex_geoserver_listener.log`).

### Långsamma GeoServer-anrop

Tar ett REST-anrop mot GeoServer längre än fem sekunder loggas en varning:

```
[WARNING]   Långsamt GeoServer-anrop: GET http://localhost:8080/geoserver/rest/workspaces.json
            tog 18.7 s (föregående anrop avslutades för 3601 s sedan)
```

Normala anrop svarar på bråkdelar av en sekund. Läs raden så här:

- **Bara det första anropet efter en lång paus är långsamt**, medan resten av
  samma avstämning går fort. Då ligger kostnaden i att bygga upp anslutningen,
  inte i anropet. Vanligaste orsaken är att `HEX_GS_URL` pekar på ett
  värdnamn vars första adress inte svarar — `localhost` slår upp `::1` före
  `127.0.0.1`, och lyssnar GeoServer bara på IPv4 får varje ny anslutning
  vänta ut TCP-timeouten (~21 s på Windows) innan den faller tillbaka.
  Kontrollera med `ping localhost` och `netstat -ano | findstr :8080`, och sätt
  i så fall `HEX_GS_URL` till `http://127.0.0.1:8080/geoserver`. Byter du
  adress måste CSRF-vitlistan i GeoServers `web.xml` uppdateras så att den
  matchar (se `src/geoserver/SETUP.md`, Steg 4) – annars slutar GeoServers
  webbgränssnitt att acceptera inloggningar.
- **Alla anrop är långsamma**, oavsett paus. Då ligger tiden hos GeoServer.
  Titta i GeoServers egen logg; en rolltjänst mot en långsam eller onåbar
  katalog (LDAP) gör att varje anrop får vänta på autentiseringen.

---

## Manuell publicering (om automatiken misslyckats)

Om ett schema inte publicerades (t.ex. om GeoServer var nere) kan du
trigga publicering manuellt. Anslut till aktuell databas i psql eller pgAdmin:

```sql
NOTIFY geoserver_schema, 'sk0_ext_sgu';
```

Lyssnaren tar emot notifieringen och försöker publicera schemat igen (skapar
läs-workspace `sk0_ext_sgu` och skriv-workspace `sk0_ext_sgu_w`).
Kontrollera loggen efteråt.

---

## WFS-T (redigering via GeoServer)

WFS-T (Web Feature Service Transactional) möjliggör Insert, Update och Delete
av lager via GeoServer. För att redigering ska fungera hela vägen till databasen
krävs att klienten pekar mot skriv-workspacet:

| Workspace       | Datastore-användare | PostgreSQL-rättigheter | Ändamål            |
|-----------------|---------------------|------------------------|--------------------|
| `{schema}`      | `gs_r_{schema}`     | SELECT                 | WMS/WFS-läsning    |
| `{schema}_w`    | `gs_w_{schema}`     | ALL                    | WFS-T (redigering) |

Konfigurationsexempel för en WFS-T-klient (t.ex. QGIS):

```
WFS-URL: https://geoserver.example.com/geoserver/{schema}_w/wfs
```

Åtkomstkontroll via GeoServer ACL:
- `{schema}.*.r` = `r_{schema}` (och `ROLE_ANONYMOUS` för prefix med
  `anonym_las = true` — standard bara `sk0`, se [Bakgrund](#bakgrund))
- `{schema}_w.*.r` = `w_{schema}`
- `{schema}_w.*.w` = `w_{schema}`

---

## Periodisk avstämning (reconciliation)

Lyssnaren kör automatiskt en periodisk avstämning mot GeoServer för att reparera
avvikelser — t.ex. om ett workspace eller en datastore försvunnit, eller om ACL-regler
är felaktiga. Samma logik körs alltid vid tjänstens uppstart.

Intervallet styrs av miljövariabeln `HEX_RECONCILE_INTERVAL` (sekunder, standard `43200`).
Sätt till `0` för att inaktivera periodisk avstämning (uppstartsavstämningen körs ändå):

```env
HEX_RECONCILE_INTERVAL=43200  # Kontrollera var tolfte timme (standard)
HEX_RECONCILE_INTERVAL=3600   # Kontrollera varje timme
HEX_RECONCILE_INTERVAL=0      # Ingen periodisk avstämning
```

Standarden är satt lågt med flit. Avstämningen är ett skyddsnät, inte huvudvägen:
publiceringen sker via `pg_notify` i samma transaktion som `CREATE SCHEMA`, och
det troliga sättet att missa en notifiering är att lyssnaren varit nere — vilket
uppstartsavstämningen redan täcker. Kvar blir notifieringar som missats medan
lyssnaren varit både uppe och ansluten, vilket är sällsynt.

Varje avstämning kostar dessutom något: den kör om hela publiceringen för
*samtliga* scheman, och varje datastore skrivs om med en PUT som bygger om
GeoServers anslutningspool för den datastoren. Intervallet räknas från
tjänstestart och inte från klockslag, så med 12 timmar hamnar minst en av
dygnets två körningar utanför kontorstid oavsett när tjänsten startades om.

Vid varje avstämning jämförs GeoServers befintliga workspaces mot scheman i PostgreSQL.
Både läs- och skriv-workspaces skapas om de saknas, och avvikande ACL-regler korrigeras.
Eventuella fel loggas men stoppar inte lyssnaren.

### Kvarlämnade workspaces i GeoServer

Avstämningen tittar också åt andra hållet: workspaces som finns i GeoServer men
vars PostgreSQL-schema saknas i **samtliga** övervakade databaser. Det inträffar
t.ex. när en databas installeras om, när ett schema tas bort medan tjänsten är
stoppad, eller när en `DROP SCHEMA` inte hann notifieras.

Ägarskapet avgörs av databasens konfiguration — de prefix som har
`publiceras_geoserver = true` i `hex_standardiserade_skyddsnivaer` — inte av
vilka scheman som råkar finnas just nu. En tömd eller nyinstallerad databas
larmar därför fortfarande om kvarlämnade workspaces.

Standardbeteendet är att bara logga en varning. Vad som ska hända styrs av
`HEX_ORPHAN_CLEANUP`:

```env
HEX_ORPHAN_CLEANUP=off       # Endast varning i loggen (standard)
HEX_ORPHAN_CLEANUP=dry-run   # Loggar vad en uppstädning skulle ta bort
HEX_ORPHAN_CLEANUP=on        # Tar bort workspacen
```

Med `on` tas workspacen bort via samma flöde som en `DROP SCHEMA`-notifiering:
läs-workspace, skriv-workspace, ACL-regler och GeoServer-rollerna `r_`/`w_`.

**Borttagning kräver att workspacen bevisligen är skapad av Hex.** Samtliga
villkor måste vara uppfyllda:

| Villkor | Skyddar mot |
| --- | --- |
| Namnet matchar schemamönstret | Workspaces utanför Hex namnkonvention |
| Inga coverage-, WMS- eller WMTS-lagringar | Manuell rasterpublicering vars namn matchar mönstret |
| Minst en datastore finns | Tom workspace som någon just har börjat bygga |
| Varje datastore är `dbtype = postgis` | Shapefile-kataloger och andra format |
| Varje datastore pekar på en övervakad databas (host, port, databas) | Datastores mot andra databaser |
| Varje datastore exponerar exakt det saknade schemat | Handpåläggning i en Hex-workspace |
| Alla övervakade databaser kunde läsas vid avstämningen | Att ett driftavbrott i en databas tolkas som "schemat är borta" |

Faller något villkor loggas en varning som säger vilket, och workspacen lämnas
orörd för manuell granskning. En publicering som gjorts direkt mot en mapp med
raster tas alltså aldrig bort, även om namnet matchar mönstret.

> **Rekommendation:** kör `dry-run` först, läs igenom loggen och verifiera att
> bara det du förväntar dig listas, innan du sätter `on`.

---

## Uppdatera konfigurationen (lösenord m.m.)

Inställningarna finns i antingen en `.env`-fil eller som systemövergripande
miljövariabler. `.env` söks i `src/geoserver/`, om inte miljövariabeln
`HEX_ENV_FILE` pekar ut en annan sökväg — lägg filen utanför kodkatalogen på en
server där katalogen byts ut vid uppgradering.

1. Redigera `.env` (eller uppdatera systemvariablerna).
2. Starta om tjänsten:
   ```cmd
   py geoserver_service.py restart
   ```

Sökvägen till konfigurationsfilen loggas vid uppstart, så loggen visar vilken
fil tjänsten faktiskt läste.

---

## Lägga till en ny databas att övervaka

1. Installera Hex-triggern i den nya databasen (se [09_installera-uppdatera-hex.md](09_installera-uppdatera-hex.md)).
2. Ge `hex_listener` CONNECT-rättighet och läsåtkomst till `hex_rolluppgifter`:
   ```sql
   GRANT CONNECT ON DATABASE geodata_ny TO hex_listener;
   GRANT SELECT ON public.hex_rolluppgifter TO hex_listener;
   ```
3. Lägg till i `.env`:
   ```env
   HEX_DB_3_DBNAME=geodata_ny
   ```
4. Starta om tjänsten.

---

## Datastore-autentisering

GeoServer ansluter till PostgreSQL via direkta PostGIS-datastores (inte JNDI).
Autentiseringsuppgifterna hanteras automatiskt av Hex:

- Vid **CREATE SCHEMA** skapar `hex_hantera_std_roller()` roller enligt mallarna i
  `hex_standardiserade_roller`. Standardkonfigurationen ger fyra roller:
  - `r_{schema}` och `w_{schema}` — NOLOGIN behörighetsgrupper, tilldelas AD-användare/grupper
  - `gs_r_{schema}` och `gs_w_{schema}` — LOGIN GeoServer-tjänstekonton med autogenererade
    lösenord sparade i `hex_rolluppgifter`. Tjänstekontona ärver behörigheter från
    `r_{schema}` respektive `w_{schema}` via gruppmedlemskap.
- Lyssnaren hämtar `gs_r_{schema}`-uppgifterna och konfigurerar läs-datastoren,
  samt `gs_w_{schema}`-uppgifterna för skriv-datastoren.
- Vid **DROP SCHEMA** tas båda workspaces bort automatiskt, tillsammans med de
  roller vars mall har `ta_bort_med_schema = true` (standard: alla fyra) och
  deras poster i `hex_rolluppgifter`.

Det krävs normalt ingen manuell åtgärd. Om du behöver en `pg_hba.conf`-post
för GeoServers direktanslutningar, tillåt `hex_geoserver_roller`-gruppen (som innehåller
`gs_r_*` och `gs_w_*`) från GeoServers IP-adress med din föredragna autentiseringsmetod,
och ladda om med:
```sql
SELECT pg_reload_conf();
```

---

## Avinstallera tjänsten

```cmd
py geoserver_service.py stop
py geoserver_service.py remove
```

---

## Stödda GeoServer-versioner

Lyssnaren är verifierad mot **GeoServer 2.27, 2.28 och 3.0**. Samma kodväg
används för alla tre — ingen konfiguration behöver ändras vid uppgradering.

Vid uppstart loggas den anslutna versionen:

```
[INFO] Ansluten till GeoServer 2.28.0 på http://localhost:8080/geoserver
```

Ligger versionen utanför det verifierade intervallet loggas dessutom:

```
[WARNING] GeoServer 3.1.0 ligger utanför det testade intervallet 2.27-3.0.
          Lyssnaren fortsätter, men verifiera särskilt roll- och ACL-hanteringen.
```

Varningen stoppar ingenting — den är en påminnelse om att köra igenom
steg 10 (verifiera hela flödet) i `SETUP.md` efter en GeoServer-uppgradering.

> **Bakgrund till versionsspannet:** GeoServer 3 ändrade felhanteringen i
> rollendpointen. En roll som redan finns gav tidigare `404` med orsaken i
> klartext, men ger i 3.x `400` med ett generiskt meddelande som bara hänvisar
> till serverloggen. Lyssnaren hanterar båda: när svaret är tvetydigt frågar
> den `/rest/security/roles` vad som faktiskt gäller i stället för att tolka
> felmeddelandet. Utan det hade varje avstämning mot en 3.x-server misslyckats
> för redan publicerade scheman.

Kraven på servermiljön skiljer sig däremot åt — GeoServer 3.0 kräver
**Tomcat 11.0** för WAR-distributionen. Se `src/geoserver/SETUP.md`,
avsnittet *Stödda GeoServer-versioner*, för hela listan.

---

## Fullständig installationsguide

Se `src/geoserver/SETUP.md` för komplett installations- och
konfigurationsdokumentation inklusive Python-beroenden och tjänstekonton.
