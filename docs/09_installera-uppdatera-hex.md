# Installera eller uppdatera Hex

**Gäller:** Första installation av Hex i en databas, eller uppdatering till en ny version.

---

## Förutsättningar

- Målplattformen är Windows Server 2022, och kommandona nedan är skrivna för
  Windows. Installern är plattformsoberoende och fungerar lika bra på Linux —
  byt då `python` mot `python3`. Se [Systemkrav i README](../README.md#systemkrav)
  för vad som skiljer plattformarna åt.
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
- PostgreSQL 16 eller senare. Installern läser serverversionen och avbryter mot
  äldre servrar.
- Ägarrollen (`owner_role`) behöver inte finnas i förväg. Saknas den skapar
  installern den som `NOLOGIN` utan lösenord och rapporterar det som en varning
  på slutet. Rollen behöver aldrig kunna logga in: den äger Hex:s objekt och får
  `ADMIN OPTION` på schemats `r_`- och `w_`-roller, vilket fungerar för en
  `NOLOGIN`-roll. Ska den kunna logga in lägger du själv till det med
  `ALTER ROLE <roll> LOGIN PASSWORD '...';`.
  Observera att ett felstavat `owner_role` därmed skapar en ny roll i stället
  för att återanvända den avsedda — läs varningen på slutet av installationen.
  Roller är gemensamma för hela klustret, inte per databas.
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

> **OBS:** `--upgrade` bevarar konfigurationsdata men tar bort och återskapar
> alla Hex-funktioner, triggers och typer. Kör gärna en manuell säkerhetskopia
> av databasen innan uppgradering i produktionsmiljö.

### Uppgradering från en version före `hex_`-prefixet

Databaser installerade innan alla objekt fick `hex_`-prefix bär kvar funktioner,
typer, tabeller och event-triggers under sina gamla namn (`hantera_ny_tabell()`,
`geom_info`, `standardiserade_skyddsnivaer` med flera).

De gamla event-triggarna är aktiva och avfyras på nästa `CREATE TABLE`. En
kvarlämnad `hantera_ny_tabell()` slår mot `public.hex_systemanvandare` innan
installationen hunnit skapa tabellen, och hela transaktionen rullas tillbaka:

```
MISSLYCKADES: FEL:  relationen "public.hex_systemanvandare" existerar inte
CONTEXT:  PL/pgSQL-funktion hantera_ny_tabell() rad 54 vid SQL-sats
```

Installern hanterar det själv:

- **Installation** rensar bort ärvda event-triggers innan något annat körs, så
  de inte kan avbryta installationen. Ärvda tabeller lämnas orörda — de kan
  bära data, och en ren installation kastar inget.
- **Avinstallation och `--upgrade`** tar dessutom bort ärvda funktioner, typer
  och tabeller, så databasen inte lämnas med två uppsättningar objekt.

Se du felet ovan kör du en avinstallation följt av en installation, eller
`--upgrade` direkt.

### `hex_rolluppgifter` roteras — den bevaras inte

Lösenorden för `gs_r_`/`gs_w_`-rollerna **byts ut** vid varje `--upgrade`.
Avinstallationen droppar `hex_rolluppgifter`, och när installationen därefter
kör `hex_underhall()` ser den inloggningsroller utan sparade uppgifter och
backfyller dem: nytt lösenord via `gen_random_bytes()`, `ALTER ROLE ... PASSWORD`
och en ny rad i tabellen. Det sker innan de sparade raderna återställs, så de
gamla lösenorden skrivs aldrig tillbaka.

Databasen är konsekvent efteråt — rollen, tabellen och gruppmedlemskapen
(`hex_geoserver_roller` samt `arvs_fran`) stämmer överens, och de nya
uppgifterna fungerar direkt för inloggning.

Det som däremot inte hänger med automatiskt är **GeoServers datastores**, som
har sitt eget sparade lösenord. Lyssnaren skriver om dem från
`hex_rolluppgifter` vid varje avstämning, men det sker först vid uppstart eller
efter `HEX_RECONCILE_INTERVAL` (standard 3600 s). Fram till dess misslyckas
GeoServers anslutningar för de berörda schemana.

**Åtgärd:** starta om lyssnartjänsten direkt efter en uppgradering i stället för
att vänta ut avstämningsintervallet:

```cmd
py geoserver_service.py restart
```

---

## Manuell installation (alternativ)

Om du föredrar att köra SQL direkt, se installationsordningen i `README.md`
under avsnittet *Detaljerad installationsordning*. Starta alltid med
`src/sql/00_config/hex_systemagare.sql` och ange ägarrollen där.

Det är den enda filen som ska redigeras. Alla övriga filer läser ägarrollen
från `hex_systemagare()` i stället för att hårdkoda ett rollnamn, så manuell
installation ger samma ägarskap som `install_hex.py`.

Undantagen som statiskt ägs av `postgres` är samtliga event-triggers,
`hex_systemagare()` och de tre `SECURITY DEFINER`-triggerfunktionerna
`hex_hantera_ny_tabell()`, `hex_hantera_std_roller()` och
`hex_ta_bort_schemaroller()`. Övriga triggerfunktioner ägs av ägarrollen —
de är inte `SECURITY DEFINER` och körs ändå med den anropande användarens
rättigheter.

Installern skapar tilläggen (`postgis`, `pgcrypto`) och ägarrollen automatiskt.
Vid manuell installation måste du göra det själv. Se *Vanliga fel vid manuell
installation* i `README.md` för felmeddelandena det ger.

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
