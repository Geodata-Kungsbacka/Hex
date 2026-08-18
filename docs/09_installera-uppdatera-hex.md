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

## Uppdatera lyssnartjänsten på GeoServer-servern

**Kort svar: nej, tjänsten behöver normalt varken stoppas och tas bort eller
installeras om.** Windows-tjänsten registrerar en sökväg till
`geoserver_service.py` och en Python-tolk; själva koden läses in först när
tjänsten startar. Byter du bara filernas innehåll räcker det med

```cmd
py geoserver_service.py stop
git -C D:\Hex pull
py geoserver_service.py start
```

`install`/`remove` behövs bara när **registreringen** ändras, inte när koden gör
det. Se tabellen längre ned.

### Varför mappen var låst

Tjänsten håller `.env` och loggfilen öppna medan den kör, och den `remove` som
behövdes berodde egentligen inte på tjänstregistreringen — det var två filer i
mappen som skulle ersättas. Två saker gör att det inte behöver hända igen:

1. **Byt inte ut hela mappen.** `git pull` i den befintliga katalogen skriver
   bara om spårade filer. `.env` är gitignorerad och rörs inte, och loggfilen
   ligger inte i git. Det är utbytet av mappen — inte uppdateringen av koden —
   som kräver att varenda fil i den går att stänga.
2. **Låt konfiguration och loggar bo utanför kodkatalogen.** Då finns inget i
   mappen som någon process håller öppet mellan omstarter.

   ```cmd
   :: Körs en gång, som administratör. Kräver omstart av tjänsten för att slå igenom.
   setx /M HEX_ENV_FILE "D:\Hex\config\.env"
   setx /M HEX_LOG_DIR  "D:\Hex\Logs"
   ```

   `HEX_ENV_FILE` läses av både `geoserver_listener.py` och
   `geoserver_service.py` innan någon annan konfiguration laddas. Utan variabeln
   används `src/geoserver/.env` som tidigare. `HEX_LOG_DIR` pekar redan som
   standard på `D:\Hex\Logs`; sätt den bara om du vill ha loggen någon
   annanstans — men inte i kodkatalogen.

Flytta den befintliga `.env` till den nya platsen innan du sätter variabeln, så
att tjänsten hittar sin konfiguration vid nästa start.

### Rekommenderad uppdatering, steg för steg

```cmd
:: 1. Stoppa tjänsten – släpper .env, loggfilen och databasanslutningarna
py geoserver_service.py stop
py geoserver_service.py status        :: ska visa "Stoppad"

:: 2. Hämta ny kod i befintlig katalog
git -C D:\Hex pull

:: 3. Uppdatera Python-beroenden om requirements ändrats
py -m pip install --upgrade psycopg2-binary requests python-dotenv pywin32

:: 4. Starta igen
py geoserver_service.py start
py geoserver_service.py status        :: ska visa "Kör"
```

Kontrollera därefter loggen (`D:\Hex\Logs\hex_geoserver_listener.log`). En
lyckad start loggar GeoServer-URL, konfigurationsfilens sökväg, antalet
databaser och att avstämningen körts.

Ska både databasen och tjänsten uppgraderas: kör `python install_hex.py --upgrade`
medan tjänsten är stoppad, och starta tjänsten efteråt. Då är
`hex_rolluppgifter` redan omroterad när lyssnaren startar och skriver om
GeoServers datastores vid uppstartsavstämningen.

### När `remove` + `install` faktiskt behövs

| Ändring | Åtgärd |
| --- | --- |
| Kodfiler byts ut (`git pull`) | `stop` → `start` |
| `.env` eller andra miljövariabler ändras | `restart` |
| Katalogen flyttas (t.ex. `D:\Hex` → `E:\Hex`) | `update` med ny sökväg, annars `remove` + `install` |
| Ny Python-tolk eller nytt virtuellt env | `update`, annars `remove` + `install` |
| `_svc_name_`, visningsnamn eller beskrivning ändras i koden | `update` (namnbyte kräver `remove` + `install`) |
| `pywin32` uppgraderas | `remove` + `install` (tjänste-EXE:n `pythonservice.exe` byts) |

`update` är pywin32:s eget kommando för att skriva om en befintlig registrering
utan att ta bort den:

```cmd
py geoserver_service.py update
```

### Varför `--upgrade` men `install`?

Skillnaden är konvention och parser, inte funktion — båda väljer en gren i
koden.

`install_hex.py` använder Pythons `argparse`. Där avgör det inledande
bindestrecket att argumentet är en **flagga**: `argparse` behandlar allt som
börjar med `-` som valfritt och namnger det efter flaggan (`--upgrade` blir
`args.upgrade`). Flaggor är oberoende av ordning, valfria, och kan kombineras.

```bash
python install_hex.py --upgrade
```

`geoserver_service.py` lämnar över kommandoraden till pywin32:s
`win32serviceutil.HandleCommandLine()`, som har sin **egen** grammatik: ett
positionsargument som är ett verb (`install`, `start`, `stop`, `restart`,
`update`, `remove`, `debug`). Det följer Windows-traditionen från `net start`
och `sc`, och du kan inte byta till `--install` utan att sluta använda
`HandleCommandLine` och skriva en egen parser.

```cmd
py geoserver_service.py install
```

Skillnaden i praktiken:

| | `--flagga` (argparse) | `verb` (pywin32) |
| --- | --- | --- |
| Ordning spelar roll | Nej | Ja – verbet står först |
| Kan kombineras | Ja (`--upgrade --dry-run`) | Nej – ett verb i taget |
| Får utelämnas | Ja (default = installera) | Ja, men då startas tjänsten av Windows tjänstehanterare |

Det sista är själva skälet till att `geoserver_service.py` inte kan använda
flaggor rakt av: när Windows startar tjänsten anropas skriptet **utan
argument**, och då ska det inte installera något utan lämna över kontrollen
till `StartServiceCtrlDispatcher()`. Den grenen finns i skriptets `__main__`
(`len(sys.argv) == 1`).

### Om en fil ändå är låst

1. Bekräfta att tjänsten verkligen är stoppad: `sc query HexGeoServerListener`.
   En tjänst i `STOP_PENDING` håller kvar sina filhandtag.
2. Stäng editorer och Utforskarfönster som står i katalogen — en öppen
   `.env` i Anteckningar eller en förhandsgranskad loggfil räcker.
3. Hitta processen som håller filen med Resursövervakaren
   (`resmon` → CPU → Associerade handtag → sök på filnamnet).
4. Rör aldrig `taskkill /F` på tjänsten om den kan stoppas normalt — en
   avbruten lyssnare lämnar sina PostgreSQL-anslutningar öppna tills servern
   städar upp dem.

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
