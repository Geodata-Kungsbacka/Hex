# Hantera GeoServer-lyssnaren

**Gäller:** Windows-tjänsten `HexGeoServerListener` som automatiskt publicerar
nya `sk0`- och `sk1`-scheman till GeoServer.

---

## Bakgrund

När ett `sk0`- eller `sk1`-schema skapas skickar Hex en `pg_notify`. En
Python-process lyssnar på dessa notifieringar och skapar automatiskt en
**workspace** och en direkt **PostGIS-datastore** i GeoServer med samma namn som schemat.
Datastore-autentiseringen hämtas från tabellen `hex_role_credentials` (läsrollen `r_{schema}`).

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

Lyssnaren tar emot notifieringen och försöker publicera schemat igen.
Kontrollera loggen efteråt.

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
2. Ge `hex_listener` CONNECT-rättighet och läsåtkomst till `hex_role_credentials`:
   ```sql
   GRANT CONNECT ON DATABASE geodata_ny TO hex_listener;
   GRANT SELECT ON public.hex_role_credentials TO hex_listener;
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

- Vid **CREATE SCHEMA** skapar `hantera_standardiserade_roller()` en LOGIN-roll
  (`r_{schema}`) med ett autogenererat lösenord som sparas i `hex_role_credentials`.
- Lyssnaren hämtar dessa uppgifter och konfigurerar GeoServer-datastoren med dem.
- Vid **DROP SCHEMA** tas rollen och dess post i `hex_role_credentials` bort automatiskt.

Det krävs normalt ingen manuell åtgärd. Om du ändå behöver en `pg_hba.conf`-post
för GeoServers direktanslutningar, tillåt rollen `r_{schema}` från GeoServers
IP-adress med din föredragna autentiseringsmetod, och ladda om med:
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
