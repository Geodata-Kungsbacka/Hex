# Hantera GeoServer-lyssnaren

**Gäller:** Windows-tjänsten `HexGeoServerListener` som automatiskt publicerar
nya `sk0`- och `sk1`-scheman till GeoServer.

---

## Bakgrund

När ett `sk0`- eller `sk1`-schema skapas skickar Hex en `pg_notify`. En
Python-process lyssnar på dessa notifieringar och skapar automatiskt en
**workspace** och en **JNDI-datastore** i GeoServer med samma namn som schemat.

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

```cmd
type C:\ProgramData\Hex\geoserver_listener.log
```

Följ loggen i realtid:
```cmd
powershell Get-Content C:\ProgramData\Hex\geoserver_listener.log -Wait -Tail 20
```

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

## Uppdatera konfigurationen (lösenord, JNDI m.m.)

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
2. Skapa JNDI-resursen i GeoServers `context.xml`.
3. Lägg till i `.env`:
   ```env
   HEX_DB_3_DBNAME=geodata_ny
   HEX_DB_3_JNDI_sk0=java:comp/env/jdbc/server.geodata_ny_sk0
   ```
4. Starta om tjänsten.

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
