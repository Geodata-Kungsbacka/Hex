# Installera eller uppdatera Hex

**Gäller:** Första installation av Hex i en databas, eller uppdatering till en ny version.

---

## Förutsättningar

- Python 3 installerat på maskinen som kör installationsskriptet.
- Python-paketet `psycopg2` installerat: `pip install psycopg2-binary`.
  Installern importerar det direkt vid start och avbryter med
  `ModuleNotFoundError` om det saknas.
- Tillgång till databasen som en PostgreSQL-roll med `SUPERUSER` eller en roll med
  tillräckliga rättigheter för att skapa event-triggers och objekt i `public`-schemat.
  Normalt ägarrollen, t.ex. `gis_admin`.
- PostGIS tillgängligt på servern (paketet `postgresql-<version>-postgis-3` eller
  motsvarande). Själva tilläggen `postgis` och `pgcrypto` skapas automatiskt av
  installern med `CREATE EXTENSION IF NOT EXISTS`.
- Ägarrollen (`owner_role`) måste finnas i databasen innan installationen körs.
  Installern skapar den inte, den avbryter med
  `owner_role '<roll>' finns inte i databasen`.
- Källkoden från repositoryt (`install_hex.py` och `src/`).

---

## Steg 1 – Konfigurera installationsskriptet

Öppna `install_hex.py` i en texteditor och fyll i listan `DATABASES`:

```python
DATABASES = [
    {
        "host":       "localhost",
        "port":       5432,
        "dbname":     "geodata",      # Databas att installera Hex i
        "user":       "postgres",     # Databasanvändare
        "password":   "losenord_har",
        "owner_role": "gis_admin",    # Rollen som ska äga Hex-objekt
    },
]
```

Alla nycklar utom `owner_role` skickas rakt in i `psycopg2.connect()` — du kan
alltså lägga till andra psycopg2-parametrar vid behov. `owner_role` anger
rollen som ska äga typer, tabeller, funktioner och triggers; sätt den till
`None` för att låta den anslutande användaren äga objekten.

> **OBS – anslutningen måste ha superuser-rättigheter.** Event-triggers kan
> bara skapas av en superuser, och de behåller `postgres`-ägande även när
> `owner_role` är satt. Samma gäller `SECURITY DEFINER`-funktioner.

> **OBS – `localhost` på Windows Server:** Om du installerar mot en lokal
> PostgreSQL-instans på Windows, byt `"localhost"` mot `"127.0.0.1"` i
> `host`-fältet. På moderna Windows-servrar kan `localhost` lösas till `::1`
> (IPv6) i stället för `127.0.0.1`, beroende på `hosts`-filens ordning. Om
> PostgreSQL lyssnar på `127.0.0.1` men Python ansluter via `::1` (eller
> vice versa) misslyckas installationen med `connection refused`. Använd
> samma literala adress i `DATABASES` och i `pg_hba.conf`.

> Har du flera databaser som ska ha Hex lägger du till **en post per databas**
> i `DATABASES`. Installern loopar över alla i samma körning och skriver ut en
> sammanfattning med OK/MISSLYCKADES per databas. En databas som misslyckas
> stoppar inte de övriga, men skriptet avslutas med felkod 1.

---

## Steg 2 – Kör installationen

```bash
python install_hex.py
```

Skriptet installerar alla typer, tabeller, funktioner, triggers och event-triggers
i rätt ordning. En utskrift bekräftar varje steg.

---

## Verifiera installationen

```sql
-- Alla event triggers ska synas
SELECT evtname, evtevent, evtenabled
FROM pg_event_trigger
ORDER BY evtname;

-- Konfigurationstabellerna ska finnas
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND (tablename LIKE '%hex%'
   OR tablename LIKE 'standardiserade%')
ORDER BY tablename;
```

---

## Uppdatera Hex till en ny version

Använd flaggan `--upgrade` som sparar dina anpassade inställningar, avinstallerar,
installerar om med den nya versionen och återställer inställningarna automatiskt:

```bash
git pull                          # Hämta senaste versionen
python install_hex.py --upgrade   # Uppgradera med bevarade inställningar
```

Följande tabeller bevaras automatiskt vid `--upgrade`:
- `hex_standardiserade_kolumner` — anpassade standardkolumner
- `hex_standardiserade_roller` — anpassade rollmallar
- `hex_standardiserade_datakategorier` — anpassade datakategorier
- `hex_standardiserade_skyddsnivaer` — anpassade skyddsnivåer
- `hex_systemanvandare` — registrerade systemanvändare
- `hex_grupprattigheter` — AD-grupp-till-Hex-roll-mappningar
- `hex_rolluppgifter` — autogenererade lösenord för `gs_r_`/`gs_w_`-roller

> **OBS:** `--upgrade` bevarar konfigurationsdata men tar bort och återskapar
> alla Hex-funktioner, triggers och typer. Kör gärna en manuell säkerhetskopia
> av databasen innan uppgradering i produktionsmiljö.

---

## Manuell installation (alternativ)

Om du föredrar att köra SQL direkt, se installationsordningen i `README.md`
under avsnittet *Detaljerad installationsordning*. Starta alltid med
`src/sql/00_config/hex_systemagare.sql` och ange ägarrollen där.

---

## Kontrollera systemstatus

```sql
-- Verifiera att triggers är aktiva
SELECT evtname, evtenabled
FROM pg_event_trigger
WHERE evtenabled != 'D'
ORDER BY evtname;

-- Kontrollera standardkolumner
SELECT kolumnnamn, ordinal_position
FROM hex_standardiserade_kolumner
ORDER BY ordinal_position;
```
