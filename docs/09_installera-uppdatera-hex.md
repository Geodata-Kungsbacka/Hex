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
i rätt ordning. En utskrift bekräftar varje steg. Skriptet avslutas med felkod 1 om
någon databas misslyckades, annars 0.

`--upgrade` och `--uninstall` kan inte kombineras — anges båda avbryter
installern med ett argumentfel.

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

Följande tabeller bevaras automatiskt vid `--upgrade`.

**Konfiguration** — dina ändringar av standardraderna, och rader du lagt till själv:
- `hex_standardiserade_kolumner` — anpassade standardkolumner
- `hex_standardiserade_roller` — anpassade rollmallar
- `hex_standardiserade_datakategorier` — anpassade datakategorier
- `hex_standardiserade_skyddsnivaer` — anpassade skyddsnivåer
- `hex_systemanvandare` — registrerade systemanvändare
- `hex_grupprattigheter` — AD-grupp-till-Hex-roll-mappningar

**Drifttillstånd** — vad Hex redan gjort med dina tabeller. Innehållet går inte
att härleda ur databasen i efterhand, till skillnad från triggers och funktioner:
- `hex_metadata` — mappning tabell-OID → historiktabell och QA-trigger
- `hex_dummy_geometrier` — tabeller som fortfarande bär en dummy-rad
- `hex_afvaktande_geometri` — tabeller mitt i FME:s tvåstegsmönster
- `hex_avvikande_srid` — granskningslista över fel koordinatsystem

> **Undantag:** `kan_logga_in` och `arvs_fran` på de fyra standardrollerna
> (`r_`, `w_`, `gs_r_`, `gs_w_`) återställs *inte* — dem äger Hex. `r_`/`w_`
> måste vara NOLOGIN, annars hamnar de i `hex_geoserver_roller` och öppnar
> `pg_hba.conf` för behörighetsgrupperna. På rollmallar du lagt till själv
> bevaras båda kolumnerna som vanligt.

> **OBS:** `--upgrade` bevarar konfigurationsdata men tar bort och återskapar
> alla Hex-funktioner, triggers och typer. Kör gärna en manuell säkerhetskopia
> av databasen innan uppgradering i produktionsmiljö.

### Ominstallation utan `--upgrade`

`python install_hex.py` mot en databas som redan kör Hex droppar ingenting — den
kör om SQL-filerna, som är skrivna för att vara idempotenta. Dina ändringar i
konfigurationstabellerna ligger kvar: `default_varde`, `historik_qa`,
`schema_uttryck`, `beskrivning`, `publiceras_geoserver`, `anonym_las` med flera.

Det enda undantaget är samma som ovan: `kan_logga_in` och `arvs_fran` på de fyra
standardrollerna rättas vid varje körning.

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
efter `HEX_RECONCILE_INTERVAL` (standard 43200 s = 12 h). Fram till dess misslyckas
GeoServers anslutningar för de berörda schemana.

**Åtgärd:** starta om lyssnartjänsten direkt efter en uppgradering i stället för
att vänta ut avstämningsintervallet:

```cmd
py geoserver_service.py restart
```

---

## Uppdatera lyssnartjänsten på GeoServer-servern

**Gäller:** Ny version av `geoserver_listener.py` eller `geoserver_service.py`
på servern där Windows-tjänsten `HexGeoServerListener` kör.

Tjänsten registrerar en sökväg till `geoserver_service.py` och en Python-tolk.
Koden läses in först när tjänsten startar, så ny kod kräver `stop` och `start`
— inte `remove` och `install`. Registreringen behöver bara skrivas om när
sökvägen, tolken eller tjänstnamnet ändras (se
[Tjänstkommandon](#tjänstkommandon)).

### Förutsättning: konfiguration och loggar utanför kodkatalogen

Tjänsten håller `.env` och loggfilen öppna medan den kör. Ligger de i
kodkatalogen kan katalogen inte ersättas medan tjänsten är installerad, och en
uppdatering kräver att tjänsten först tas bort.

Två inställningar flyttar ut dem. Kör en gång, som administratör:

```cmd
setx /M HEX_ENV_FILE "D:\Hex\config\.env"
setx /M HEX_LOG_DIR  "D:\Hex\Logs"
```

| Variabel | Standard | Läses av |
| --- | --- | --- |
| `HEX_ENV_FILE` | `src/geoserver/.env` | `geoserver_listener.py` och `geoserver_service.py`, före all annan konfiguration |
| `HEX_LOG_DIR` | `D:\Hex\Logs` | `geoserver_service.py` vid uppstart |

Flytta den befintliga `.env` till den nya sökvägen innan variabeln sätts, annars
startar tjänsten utan konfiguration. Sökvägen tjänsten faktiskt läste loggas vid
uppstart.

> **OBS:** `HEX_LOG_DIR` pekar redan som standard utanför `src\geoserver`. Sätt
> den bara om loggen ska ligga någon annanstans — aldrig i kodkatalogen.

### Steg 1 – Stoppa tjänsten

```cmd
py geoserver_service.py stop
py geoserver_service.py status        :: ska visa "Stoppad"
```

Stoppet släpper `.env`, loggfilen och databasanslutningarna.

### Steg 2 – Hämta ny kod i befintlig katalog

```cmd
git -C D:\Hex pull
```

Uppdatera koden på plats i stället för att ersätta hela katalogen. `git pull`
skriver bara om spårade filer; `.env` är gitignorerad och loggfilen ligger
utanför git. Ett utbyte av hela katalogen kräver däremot att varje fil i den går
att stänga.

### Steg 3 – Uppdatera Python-beroenden vid behov

```cmd
py -m pip install --upgrade psycopg2-binary requests python-dotenv pywin32
```

### Steg 4 – Starta tjänsten

```cmd
py geoserver_service.py start
py geoserver_service.py status        :: ska visa "Kör"
```

<!-- HEX-MIGRERING 2026-08: visningsnamnet ändrades från
"Hex GeoServer Schema Listener" till "HexGeoServerListener". Tjänster
registrerade före det bär kvar det gamla namnet i tjänsteregistret. Tas bort när
samtliga servrar kört `update` en gång. -->
> **Engångsåtgärd vid uppgradering från en äldre version:** tjänstens
> visningsnamn hette tidigare *Hex GeoServer Schema Listener* och heter nu
> `HexGeoServerListener`, samma som tjänstnamnet. Visningsnamnet ligger i
> Windows tjänsteregister och skrivs inte om av `stop`/`start`. Kör därför en
> gång, som administratör, medan tjänsten är stoppad:
>
> ```cmd
> py geoserver_service.py update
> ```
>
> Utan det står det gamla namnet kvar i `services.msc`. Tjänstnamnet är
> oförändrat, så `net start HexGeoServerListener` och `sc query
> HexGeoServerListener` fungerar oavsett.

### Verifiera

Läs loggen (`D:\Hex\Logs\hex_geoserver_listener.log`). En lyckad start loggar
GeoServer-URL, konfigurationsfilens sökväg, antal databaser, uppstädningsläge och
att avstämningen körts.

> **Uppgraderas både databasen och tjänsten:** kör `python install_hex.py --upgrade`
> medan tjänsten är stoppad och starta tjänsten efteråt. `hex_rolluppgifter` är då
> redan omroterad när lyssnaren startar och skriver om GeoServers datastores vid
> uppstartsavstämningen. Se
> [`hex_rolluppgifter` roteras](#hex_rolluppgifter-roteras--den-bevaras-inte).

### Tjänstkommandon

| Ändring | Åtgärd |
| --- | --- |
| Kodfiler byts ut (`git pull`) | `stop` → `start` |
| `.env` eller andra miljövariabler ändras | `restart` |
| Katalogen flyttas (t.ex. `D:\Hex` → `E:\Hex`) | `update`, annars `remove` + `install` |
| Ny Python-tolk eller nytt virtuellt env | `update`, annars `remove` + `install` |
| Visningsnamn eller beskrivning ändras i koden | `update` |
| `_svc_name_` ändras i koden | `remove` + `install` |
| `pywin32` uppgraderas | `remove` + `install` (tjänste-EXE:n `pythonservice.exe` byts) |

`update` är pywin32:s kommando för att skriva om en befintlig registrering utan
att ta bort den:

```cmd
py geoserver_service.py update
```

> **OBS – två olika kommandoradskonventioner.** `geoserver_service.py` tar verb
> utan bindestreck (`install`, `start`, `update`) därför att pywin32:s
> `win32serviceutil.HandleCommandLine()` äger grammatiken, i samma stil som
> `net start` och `sc`. `install_hex.py` använder `argparse` och därmed flaggor
> (`--upgrade`, `--uninstall`). Verben kan inte bytas mot flaggor: Windows
> tjänstehanterare startar skriptet helt utan argument, och den grenen
> (`len(sys.argv) == 1` i `__main__`) lämnar över till
> `StartServiceCtrlDispatcher()` i stället för att tolka ett kommando.

### Felsökning: en fil går inte att ersätta

1. Kontrollera att tjänsten verkligen är stoppad: `sc query HexGeoServerListener`.
   En tjänst i `STOP_PENDING` håller kvar sina filhandtag.
2. Stäng editorer och Utforskarfönster som står i katalogen. En öppen `.env` i
   Anteckningar eller en förhandsgranskad loggfil räcker för att blockera.
3. Identifiera processen som håller filen med Resursövervakaren
   (`resmon` → CPU → Associerade handtag → sök på filnamnet).
4. Använd inte `taskkill /F` på en tjänst som går att stoppa normalt. En avbruten
   lyssnare lämnar sina PostgreSQL-anslutningar öppna tills servern städar upp dem.

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
