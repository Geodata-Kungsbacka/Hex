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
`D:\ProgramData\Hex`):

```cmd
type %HEX_LOG_DIR%\geoserver_listener.log
```

Följ loggen i realtid:
```cmd
powershell Get-Content "$env:HEX_LOG_DIR\geoserver_listener.log" -Wait -Tail 20
```

Om `HEX_LOG_DIR` inte är satt som systemmiljövariabel, ersätt med den faktiska
sökvägen (t.ex. `D:\ProgramData\Hex\geoserver_listener.log`).

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
- `{schema}.*.r` = `r_{schema}` (och eventuellt `ROLE_ANONYMOUS` för sk0)
- `{schema}_w.*.r` = `w_{schema}`
- `{schema}_w.*.w` = `w_{schema}`

---

## Periodisk avstämning (reconciliation)

Lyssnaren kör automatiskt en periodisk avstämning mot GeoServer för att reparera
avvikelser — t.ex. om ett workspace eller en datastore försvunnit, eller om ACL-regler
är felaktiga. Samma logik körs alltid vid tjänstens uppstart.

Intervallet styrs av miljövariabeln `HEX_RECONCILE_INTERVAL` (sekunder, standard `3600`).
Sätt till `0` för att inaktivera periodisk avstämning (uppstartsavstämningen körs ändå):

```env
HEX_RECONCILE_INTERVAL=3600   # Kontrollera varje timme (standard)
HEX_RECONCILE_INTERVAL=0      # Ingen periodisk avstämning
```

Vid varje avstämning jämförs GeoServers befintliga workspaces mot scheman i PostgreSQL.
Både läs- och skriv-workspaces skapas om de saknas, och avvikande ACL-regler korrigeras.
Eventuella fel loggas men stoppar inte lyssnaren.

---

## Uppdatera konfigurationen (lösenord m.m.)

Inställningarna finns i antingen en `.env`-fil i `src/geoserver/` eller
som systemövergripande miljövariabler:

1. Redigera `.env` (eller uppdatera systemvariablerna).
2. Starta om tjänsten:
   ```cmd
   py geoserver_service.py restart
   ```

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

- Vid **CREATE SCHEMA** skapar `hex_hantera_std_roller()` fyra roller automatiskt:
  - `r_{schema}` och `w_{schema}` — NOLOGIN behörighetsgrupper, tilldelas AD-användare/grupper
  - `gs_r_{schema}` och `gs_w_{schema}` — LOGIN GeoServer-tjänstekonton med autogenererade
    lösenord sparade i `hex_rolluppgifter`. Tjänstekontona ärver behörigheter från
    `r_{schema}` respektive `w_{schema}` via gruppmedlemskap.
- Lyssnaren hämtar `gs_r_{schema}`-uppgifterna och konfigurerar läs-datastoren,
  samt `gs_w_{schema}`-uppgifterna för skriv-datastoren.
- Vid **DROP SCHEMA** tas båda workspaces, alla fyra roller och deras poster
  i `hex_rolluppgifter` bort automatiskt.

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

## Fullständig installationsguide

Se `src/geoserver/SETUP.md` för komplett installations- och
konfigurationsdokumentation inklusive Python-beroenden, tjänstekonton
och CSRF-inställningar i GeoServer.
