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

## Lägga till eller byta JNDI-anslutningsanvändare

JNDI-poolens databasanvändare är den roll som GeoServer faktiskt ansluter med mot PostgreSQL.

**Vad systemet hanterar automatiskt:**
Schema- och tabellrättigheter tilldelas via `hantera_standardiserade_roller()` när scheman skapas, inklusive `DEFAULT PRIVILEGES` för framtida tabeller. Login-rollen ärver alla rättigheter från gruppollen via PostgreSQL roll-arv.

**Vad som konfigureras per miljö:**

1. **Skapa login-rollen** i PostgreSQL och tilldela den lämplig grupproll:
   ```sql
   CREATE ROLE r_sk0_global_pub WITH LOGIN PASSWORD '...';
   GRANT r_sk0_global TO r_sk0_global_pub;
   ```

2. **PostgreSQL-autentisering** — `pg_hba.conf`-poster är per login-roll och ärvs inte via gruppmedlemskap. Varje ny login-roll behöver en egen post konfigurerad enligt er miljö (IP-adress, autentiseringsmetod). Ladda om utan omstart: `SELECT pg_reload_conf()`.

3. **JNDI-resursen i Tomcat** — miljöspecifik konfiguration i er Tomcat-installation. Resursens `name` (på formen `jdbc/...`) måste matcha `HEX_DB_N_JNDI_*`-variabeln i `.env`. Tomcat måste startas om för att läsa nya pooler.

4. **Uppdatera lyssnaren** — lägg till `HEX_DB_N_JNDI_*` i `.env` och starta om tjänsten så att lyssnaren känner till den nya poolen.

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
