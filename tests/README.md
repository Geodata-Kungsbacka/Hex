# Hex-tester

Testsviten består av SQL-sviter som körs mot en riktig PostgreSQL-databas med
Hex installerat, samt Python-sviter för GeoServer-lyssnaren.

---

## Förutsättningar

- PostgreSQL 16 eller senare med PostGIS installerat på servern (paketet
  `postgresql-<version>-postgis-3` eller motsvarande), och Hex installerat i
  testdatabasen
  (se [docs/09_installera-uppdatera-hex.md](../docs/09_installera-uppdatera-hex.md)).
- `psql` på PATH. `test_run_all.py` kör SQL-sviterna genom klienten och läser
  de NOTICE/WARNING-rader den skriver ut. Installerar du servern med
  Debian/Ubuntus `postgresql-16` följer klienten med automatiskt
  (`postgresql-client-16` är ett beroende), men kör du sviterna från en annan
  maskin än databasservern — eller mot en hanterad PostgreSQL — måste
  `postgresql-client-<version>` installeras separat. `install_hex.py` berörs
  inte: den ansluter via psycopg2.
- Anslutning som superuser. Sviterna skapar och tar bort scheman, roller och
  event-triggerberoende objekt.
- För Python-sviterna: `pip install psycopg2-binary requests`.

> **Använd en engångsdatabas.** Sviterna skapar och droppar scheman som
> `sk1_kba_stress` och `sk0_ext_fmetest`, och de tar bort roller som hör till
> dem. Kör dem aldrig mot produktion.

> **Claude Code på webben: hoppa över uppsättningen nedan.** I den miljön gör
> `.claude/hooks/session-start.sh` allt det här automatiskt vid sessionsstart —
> installerar PostGIS och Python-beroendena, startar klustret, skapar `hex_test`
> och installerar Hex i den, och sätter `PG*`-variablerna för sessionen.
> `tests/test_run_all.py` går alltså att köra direkt.
>
> Hooken anropar `install_hex.install()` med en egen anslutningsdict i stället
> för att fylla i `DATABASES` i `install_hex.py`. Redigera därför inte
> `DATABASES` i en webbsession: filen är spårad, och lösenordet skulle checkas
> in. Hooken kör bara när `CLAUDE_CODE_REMOTE=true` och rör aldrig en lokal
> PostgreSQL-installation.

Sätt upp en testdatabas:

```bash
createdb hex_test
```

> **Anslutning som `postgres`.** På Debian/Ubuntu står `local all postgres peer`
> i `pg_hba.conf`, vilket betyder att `createdb` och psql-kommandona nedan bara
> fungerar direkt om du är inloggad som OS-användaren `postgres`. Är du det
> inte, kör antingen via `su postgres -c '...'` eller anslut över TCP med
> lösenord (`PGHOST=localhost PGUSER=postgres PGPASSWORD=...`). Samma sak
> gäller `host`/`password` i `DATABASES` nedan.

Peka sedan `DATABASES` i `install_hex.py` på testdatabasen:

```python
DATABASES = [
    {
        "host": "localhost",
        "port": 5432,
        "dbname": "hex_test",
        "user": "postgres",
        "password": "...",
        "owner_role": "gis_admin",
    },
]
```

```bash
python3 install_hex.py
```

Installern skapar `postgis` och `pgcrypto`, och skapar ägarrollen
(`gis_admin` ovan) som `NOLOGIN` om den inte redan finns i klustret.

---

## Kör alla tester

```bash
PGDATABASE=hex_test PGUSER=postgres PGHOST=localhost PGPASSWORD=... \
  python3 tests/test_run_all.py
```

`PGHOST`/`PGPASSWORD` behövs inte om du kör som OS-användaren `postgres` och
peer-autentisering räcker — se noten om `pg_hba.conf` ovan.

Skriptet kör varje svit, tolkar resultaten och skriver ut en sammanfattning.
Avslutskoden är 0 bara om samtliga sviter passerade, vilket gör det användbart
i CI.

```
SVIT                                 PASS  XFAIL   SKIP   FAIL   STATUS
...
test_reserved_words.sql                24      0      0      0   OK
...
test_stress.sql                        28     14      0      0   OK
...
TOTALT                                614     15      0      0
```

Flaggor:

| Flagga            | Effekt                                  |
|-------------------|-----------------------------------------|
| `--only sql`      | Kör bara SQL-sviterna                   |
| `--only python`   | Kör bara Python-sviterna                |
| `-v`, `--verbose` | Skriv ut fullständig utdata per svit    |
| `--strikt`        | Underkänn sviter med överhoppade tester |

`--strikt` är avsett för CI. Lokalt är ett överhopp ofta avsiktligt —
`test_installer_livscykel.py` hoppar över sig själv när ingen
superuser-anslutning finns — men i CI betyder det nästan alltid en
felkonfigurerad anslutning, och då ska bygget gå rött i stället för att
redovisa tester som aldrig kördes.

Anslutningen styrs med libpq:s standardvariabler (`PGDATABASE`, `PGUSER`,
`PGHOST`, `PGPORT`, `PGPASSWORD`). Utan dem används `hex_test` på `localhost`
som `postgres`.

---

## Kör en enskild svit

```bash
# SQL-svit
psql -d hex_test -f tests/test_regression.sql

# Python-svit
python3 tests/test_pg_notify_listener.py
PGHOST=localhost PGUSER=postgres PGPASSWORD=hemligt python3 tests/test_pg_notify_listener.py
```

---

## Resultatkonventioner

SQL-sviterna rapporterar på två sätt. Båda tolkas av `test_run_all.py`:

1. **Meddelandenivå** — `NOTICE ... PASSED` (eller `GODKÄNT`) är godkänt,
   `WARNING ... FAILED` (eller `MISSLYCKAT` / `BUG`) är underkänt. Att köra
   sviten med `psql` utan att sänka `client_min_messages` är alltså en
   förutsättning för att se resultaten.
2. **Resultattabell** — sviten samlar rader i en tabell med kolumnen `status`
   och skriver ut den på slutet.

| Status  | Betydelse                                                          |
|---------|--------------------------------------------------------------------|
| `PASS`  | Testet gjorde det som förväntades                                   |
| `XFAIL` | Förväntat fel – Hex blockerade korrekt något otillåtet. Räknas som godkänt |
| `FAIL`  | Underkänt                                                           |

Python-sviterna bidrar dessutom med `SKIP`-kolumnen i sammanfattningen, och
räknas in i `XFAIL` när unittest rapporterar `expected failures=N` — det är
samma sak som SQL-sviternas `XFAIL`, ett test som kördes och gav det förväntade
felet. Blanda inte ihop kolumnerna: ett `XFAIL` kördes och gav det förväntade
felet, medan ett `SKIP` aldrig kördes alls. Överhoppade tester räknas därför
bort från `PASS` — unittest avslutar med 0 även när samtliga tester hoppades
över, så utan avräkningen skulle en svit som inte körde något redovisas som
idel godkända tester. En svit som inte rapporterar ett enda resultat underkänns
alltid, oavsett avslutskod.

SRID-varningar (`har SRID 3006 – förväntar 3007`) är avsiktliga i flera sviter
och betyder inte att ett test misslyckats.

---

## Sviterna

| Fil                            | Täcker                                                        |
|--------------------------------|---------------------------------------------------------------|
| `test_reserved_words.sql`      | Kolumnnamn som är reserverade ord i QA-triggers                |
| `test_stress.sql`              | Namnvalidering, rollhantering, historik, konfigurationsgränser |
| `test_dummy_srid.sql`          | Dummy-geometrier och registrering av avvikande SRID            |
| `test_edge_cases.sql`          | CREATE/ALTER TABLE-varianter, schemanamngivning, specialfall   |
| `test_extended_ab.sql`         | sk2-scheman och vy-validering                                  |
| `test_extended_cd.sql`         | Klientsimulering (GeoServer, QGIS, FME) och strukturella fall  |
| `test_extended_efg.sql`        | Historiksynk, dataöverlevnad, QA-triggersäkerhet               |
| `test_fme.sql`                 | FME:s tvåstegsmönster för tabellskapande                       |
| `test_geometry_validation.sql` | `hex_validera_geometri` och geometrikvalitet                    |
| `test_regression.sql`          | Regressionsskydd för tidigare rättade buggar                   |
| `test_role_permissions.sql`    | Roller och rättigheter per schema                              |
| `test_underhall.sql`           | `hex_underhall()` – reparation av triggers, roller, ägarskap    |
| `test_underhall_hex.sql`       | Ägarskapsreparation och idempotens i underhållet               |
| `test_schema_namnbyte.sql`     | Blockering av `ALTER SCHEMA ... RENAME TO`                     |
| `test_grupprattigheter.sql`    | `hex_tillampa_grupprattigheter()` – AD-grupproll → Hex-roll     |
| `test_client_encoding.py`      | Att lyssnaren alltid sätter UTF-8 som klientkodning             |
| `test_installer.py`            | `install_hex.py` – ägarskap, installationsordning och dokumentationens SQL-block |
| `test_installer_livscykel.py`  | Uppgradering (även från äldre schema), avinstallation, felvägar, `owner_role=None` |
| `test_pg_notify_listener.py`   | `pg_notify`-flödet mot GeoServer (GeoServer mockas), `.env`-läsning, e-postlarm |
| `test_geoserver_service.py`    | Windows-tjänsten: import, `HEX_LOG_DIR`, loggfilsuppsättning     |

Python-sviterna kräver inte att Hex är installerat. `test_installer.py`
behöver ingen databas alls – den testar installerns rena funktioner och
konsistensen i `INSTALL_ORDER` mot filerna på disk.

Den kontrollerar också **dokumentationen mot installern**: att `DROP`-blocket i
`docs/10_avinstallera-hex.md` innehåller exakt samma satser i samma ordning som
`UNINSTALL_SQL`, att README inte upprepar blocket, och att README:s
*Detaljerad installationsordning* speglar `INSTALL_ORDER`. De listorna är
handkopior av installerns egna, och en kopia som driver isär märks inte förrän
en DBA följer den: ett bortglömt `DROP EVENT TRIGGER` lämnar en aktiv
event-trigger kvar i en databas där Hex ska vara avinstallerat.

`test_installer_livscykel.py` skapar och droppar en egen engångsdatabas
(`hex_test_livscykel`) och rör aldrig `hex_test`. Den hoppas över automatiskt
om ingen superuser-anslutning finns. Anslutningen styrs med `PGHOST`,
`PGUSER`, `PGPASSWORD` och `PGPORT` — `PGDATABASE` används inte.

Tre klasser där testar **uppgradering från ett äldre schema**, alltså att
`snapshot_settings`/`restore_settings` tål att den gamla databasens tabeller
inte ser ut som SQL-filerna. De installerar dagens Hex och bakar sedan
tillbaka schemat innan `upgrade()` körs:

| Klass | Glapp som ställs upp |
|---|---|
| `TestUppgraderingFranAldreSchema` | Kolumn saknas, bara nyckeln kvar, hel tabell saknas, död OID i `hex_metadata` |
| `TestUppgraderingUtanNaturligNyckel` | Nyckelkolumnen heter något annat |
| `TestUppgraderingNarNyaSchematTappatKolumn` | Snapshoten har en kolumn som nya schemat inte skapar |

Det är maskineriet varje framtida `HEX-MIGRERING` lutar sig mot — se
[CLAUDE.md](../CLAUDE.md) om att märka, testa och städa bort migreringar.

`TestFelvagar` täcker felvägarna: avbruten installation, trasig
avinstallation, misslyckat underhåll och misslyckad återställning. README
lovar att skriptet rullar tillbaka om något går fel, och de grenarna var
otäckta tills de testades.

> Kvar otäckt i `install_hex.py` (8 rader, 97 %) är avsiktligt: redundanta
> vakter vars utfall inte går att skilja från en annan gren — t.ex.
> `if not _table_exists(...)` i `_las`, där `_table_columns()` ändå ger en tom
> mängd och funktionen returnerar `None` — samt `DATABASES`-defaulten och
> `raise SystemExit(main())`, som bara nås när skriptet körs mot en verkligt
> konfigurerad databas.

`test_pg_notify_listener.py` använder en riktig databasanslutning för
LISTEN/NOTIFY men mockar GeoServer. Klassen `TestRolluppgifterMotRiktigTabell`
kör dessutom uppslagen mot en verklig `public.hex_rolluppgifter` — övriga
tester mockar dem, och då körs aldrig deras SQL. Den klassen hoppas över när
Hex inte är installerat i måldatabasen.

`TestEnvFilReservlasare` testar `.env`-läsaren som används när `python-dotenv`
saknas. Den vägen är inte hypotetisk: hooken installerar bara `psycopg2` och
`requests`, så i CI och i webbsessioner är reservläsaren den som körs.

`test_geoserver_service.py` stoppar in attrapper för pywin32 i `sys.modules` och
kan därför köras på Linux, trots att `geoserver_service.py` är en
Windows-tjänst. Den täcker inte tjänstelivscykeln — bara att modulen går att
importera (den hämtar fem namn ur `geoserver_listener`, och ett namnbyte där
syns annars först när tjänsten inte startar), att `HEX_LOG_DIR` styr
loggkatalogen, och att loggfilen kopplas på.
