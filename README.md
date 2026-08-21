# PostgreSQL Automatisk Tabellstrukturering med PostGIS

## Översikt

Detta system automatiserar databasstrukturering i PostgreSQL med PostGIS-stöd. När du skapar en ny tabell läggs automatiskt standardkolumner till (som primärnyckel, tidsstämplar och användarspårning), geometrikolumner placeras alltid sist, och tabellnamn valideras enligt en strikt namngivningsstandard. Systemet skapar även automatiskt säkerhetsroller för varje schema och kan generera historiktabeller för ändringsloggning. Huvudsyftet är att säkerställa konsekvent databasstruktur utan manuellt arbete, vilket minskar fel och ökar produktiviteten i geodatabashantering.

> **Mer dokumentation:**
> - **[LOGIC_MAP.md](LOGIC_MAP.md)** — detaljerade funktionsflöden och Mermaid-diagram för alla DDL-händelser
> - **[src/geoserver/SETUP.md](src/geoserver/SETUP.md)** — installationsguide för GeoServer-lyssnaren (Windows-tjänst)

## Huvudfunktionalitet

### 1. **Automatisk tabellstrukturering**
När du skapar en tabell med `CREATE TABLE` omstruktureras den automatiskt med:
- Standardkolumner enligt konfigurationstabellen `hex_standardiserade_kolumner` — i standardkonfigurationen `gid` (primärnyckel), `skapad_tidpunkt`, `skapad_av`, `andrad_tidpunkt` och `andrad_av`
- Korrekt kolumnordning (standardkolumner först/sist, geometri alltid sist)
- Bevarande av alla ursprungliga hex_tabellregler och begränsningar

### 2. **Namngivningsvalidering**

#### Schemanamn
Schemanamn måste följa mönstret `<skyddsnivå>_<datakategori>_<namn>` där giltiga värden hämtas dynamiskt från konfigurationstabellerna `hex_standardiserade_skyddsnivaer` och `hex_standardiserade_datakategorier`.

Standardkonfiguration:
- `sk0`, `sk1`, `sk2`, `skx` = Säkerhetsnivå (0=öppen, 1=kommun, 2=begränsad, x=oklassificerad)
- `ext` = Externa datakällor
- `kba` = Interna kommunala datakällor
- `sys` = Systemdata

Lägg till rader i `hex_standardiserade_skyddsnivaer` eller `hex_standardiserade_datakategorier` för att utöka tillåtna kombinationer utan att ändra kod.

Exempel på giltiga schemanamn (standardkonfiguration):
- `sk0_ext_sgu`
- `sk1_kba_bygg`
- `sk2_sys_admin`
- `skx_kba_testprojekt`

**`ALTER SCHEMA ... RENAME TO` är blockerat.** Schemanamnet är identitetsnyckeln för GeoServer-workspace, databasroller (`r_`/`w_`), `hex_rolluppgifter` och `hex_metadata`. Ett namnbyte river sönder alla dessa kopplingar. Rätt tillvägagångssätt är `DROP SCHEMA CASCADE` (Hex städar upp) följt av `CREATE SCHEMA` med det nya namnet.

#### Tabellnamn
Systemet kräver specifika suffix baserat på geometrityp:
- `_p` för punktgeometrier (POINT, MULTIPOINT)
- `_l` för linjegeometrier (LINESTRING, MULTILINESTRING)
- `_y` för ytgeometrier (POLYGON, MULTIPOLYGON)
- `_g` för generiska eller blandade geometrier
- Tabeller utan geometri får inte använda dessa suffix

### 3. **Automatisk rollhantering**
Vilka roller som skapas för ett nytt schema styrs av rollmallarna i `hex_standardiserade_roller`. I standardkonfigurationen finns fyra mallar, som alla matchar samtliga scheman (`schema_uttryck = 'IS NOT NULL'`):
- `r_schemanamn` — NOLOGIN behörighetsgrupp med läsrättigheter (tilldelas AD-användare och AD-grupper)
- `w_schemanamn` — NOLOGIN behörighetsgrupp med skrivrättigheter (tilldelas AD-användare och AD-grupper)
- `gs_r_schemanamn` — LOGIN GeoServer-läs-tjänstekonto, ärver rättigheter från `r_`
- `gs_w_schemanamn` — LOGIN GeoServer-skriv-tjänstekonto, ärver rättigheter från `w_`

Lägg till, ändra eller ta bort rader i `hex_standardiserade_roller` för att styra uppsättningen — se [docs/04_hantera-rollmallar.md](docs/04_hantera-rollmallar.md).

`gs_r_` och `gs_w_` får autogenererade lösenord sparade i `hex_rolluppgifter` och ingår i `hex_geoserver_roller` för pg_hba.conf-matchning. `r_` och `w_` är NOLOGIN och ingår aldrig i `hex_geoserver_roller`.

### 4. **Automatisk GeoServer-publicering och rensning**
Lyssnaren hanterar två livscykelhändelser automatiskt via `pg_notify`:

**Vid CREATE SCHEMA** (kanal `geoserver_schema`) — skapar **två** workspaces per schema:

| Workspace | Datastore-konto | Rättigheter | Ändamål |
|---|---|---|---|
| `{schema}` | `gs_r_{schema}` | SELECT | WMS/WFS-läsning |
| `{schema}_w` | `gs_w_{schema}` | ALL | WFS-T (redigering via GeoServer) |

För varje workspace hämtas tjänstekontots uppgifter ur `hex_rolluppgifter` och en
direkt PostGIS-datastore skapas med dem. Därefter skapas GeoServer-roller
(`r_{schema}`, `w_{schema}`) och ACL-regler för båda workspaces.

`gs_r_{schema}` och `gs_w_{schema}` skapas automatiskt av `hex_hantera_std_roller()`
vid CREATE SCHEMA med autogenererade lösenord sparade i `hex_rolluppgifter`. Ingen
JNDI-konfiguration i Tomcat krävs.

**Vid DROP SCHEMA** (kanal `geoserver_schema_drop`):
- Tar bort ACL-reglerna för båda workspaces
- Tar bort både `{schema}` och `{schema}_w` med `recurse=true`, vilket raderar datastores och publicerade lager automatiskt
- Tar bort GeoServer-rollerna `r_{schema}` och `w_{schema}`
- Förhindrar att GeoServer gör upprepade anrop mot ett schema som inte längre existerar

Vilka scheman som publiceras styrs av kolumnen `publiceras_geoserver` i
`hex_standardiserade_skyddsnivaer` — som standard `sk0` och `sk1`. `sk2` och `skx`
publiceras inte och kräver manuell konfiguration. Kolumnen `anonym_las` styr om
läs-workspacet får `ROLE_ANONYMOUS` i sin ACL-regel (standard `true` för `sk0`).
Se `docs/08_geoserver-lyssnaren.md`.

**Avstämning:** lyssnaren stämmer av GeoServer mot databasen vid uppstart och
därefter periodiskt (`HEX_RECONCILE_INTERVAL`, standard 43200 s = 12 h). Saknade workspaces
och datastores återskapas, avvikande ACL-regler korrigeras, och datastorens
autentiseringsuppgifter skrivs om från `hex_rolluppgifter`.

Avstämningen rapporterar också workspaces vars PostgreSQL-schema saknas i
samtliga övervakade databaser. Standard är att bara varna; `HEX_ORPHAN_CLEANUP`
(`off` | `dry-run` | `on`) kan låta lyssnaren städa bort dem — men bara när
workspacen bevisligen är skapad av Hex, aldrig en manuell rasterpublicering vars
namn råkar matcha schemamönstret. Se `docs/08_geoserver-lyssnaren.md`.

**Felhantering:**
- Automatisk retry med backoff vid timeout eller anslutningsfel mot GeoServer (upp till 4 försök)
- Valfria e-postnotifieringar vid misslyckad publicering, misslyckad workspace-borttagning, PostgreSQL-anslutningsavbrott och återhämtning
- Konfigureras via `HEX_SMTP_*`-miljövariabler (Office 365/Exchange som standard)

Lyssnaren körs som en Windows-tjänst (`HexGeoServerListener`) via `services.msc`.
Se `src/geoserver/SETUP.md` för fullständig installationsguide.

### 5. **Stöd för verktyg som skapar tabeller i två steg (t.ex. FME)**

Vissa ETL-verktyg (FME, GDAL m.fl.) skapar tabeller i två separata DDL-steg:

1. `CREATE TABLE ... (datakolumner)` — utan geometrikolumn
2. `ALTER TABLE ... ADD COLUMN geom geometry(...)` — geometrin läggs till efteråt

Systemet hanterar detta via tabellen `hex_systemanvandare`. När en session matchar en registrerad systemanvändare (`session_user`, `current_user` eller `application_name`):

- `hex_hantera_ny_tabell` tillåter att tabellen skapas utan geometrikolumn, trots att tabellnamnet har geometrisuffix
- Tabellen registreras i `hex_afvaktande_geometri` som "väntande"
- Geometrispecifik efterbehandling (GiST-index, geometrivalidering) skjuts upp
- När `ALTER TABLE ADD COLUMN geom` senare körs slutför `hex_hantera_ny_kolumn` den uppskjutna hanteringen: verifierar att suffixet stämmer med geometritypen, skapar GiST-index och tar bort raden från `hex_afvaktande_geometri`

**Konfiguration**: Lägg till verktygets databasanvändare i `hex_systemanvandare`. FME (`fme`) är förregistrerat som standard.

### 6. **Historik och kvalitetssäkring**
För scheman konfigurerade med QA-kolumner skapas:
- Historiktabeller (`tabellnamn_h`) som loggar alla ändringar
- Triggers som automatiskt uppdaterar de standardkolumner som har `historik_qa = true` i `hex_standardiserade_kolumner` (standardkonfiguration: `andrad_tidpunkt` och `andrad_av`)

#### `hex_validera_geometri(geom)`
Validerar geometrikvalitet för scheman vars datakategori har `hex_validera_geometri = true` i `hex_standardiserade_datakategorier` (standardkonfiguration: `_kba_`, manuellt redigerade data).

**Kontroller**:
- ST_IsValid - geometrin följer OGC-specifikationen
- NOT ST_IsEmpty - geometrin innehåller faktiska koordinater
- Inga exakta konsekutiva duplicerade punkter (ST_RemoveRepeatedPoints, nolltolerans)
- NOT ST_HasArc - geometrin innehåller inga kurvsegment

**Användning**: Används som CHECK constraint, appliceras automatiskt av `hex_hantera_ny_tabell` på scheman vars datakategori har `hex_validera_geometri = true` (standardkonfiguration: `_kba_`).

## Installation

### Systemkrav

- **Målplattform: Windows Server.** Hex körs i produktion på Windows Server 2022,
  och kommandona i dokumentationen är skrivna för Windows (`python`, `py`).
- **PostgreSQL 16 eller senare.** Installern kontrollerar serverversionen och
  avbryter mot äldre versioner.
- **PostGIS installerat på servern** — paketet `postgresql-<version>-postgis-3`
  eller motsvarande för plattformen. Installern kör `CREATE EXTENSION IF NOT
  EXISTS postgis`, vilket bara fungerar om PostGIS redan finns på maskinen där
  PostgreSQL körs. Saknas paketet avbryter installationen med
  `ERROR: extension "postgis" is not available`.
- **pgcrypto** — ingår i `postgresql-contrib` och skapas automatiskt av
  installern.
- **Python 3** och `psycopg2` (`pip install psycopg2-binary`) för den
  automatiska installationen.
- **Ägarrollen** (`owner_role`) — skapas automatiskt av installern om den
  saknas, se [Automatisk installation](#automatisk-installation-rekommenderat).

> **Linux?** Databasdelen är plattformsoberoende — `install_hex.py`, all SQL och
> hela testsviten körs lika bra på Linux. Enda skillnaden är kommandonamnet: byt
> `python` mot `python3`, eftersom Debian/Ubuntu inte installerar något
> `python`-kommando som standard.
>
> Undantaget är `src/geoserver/geoserver_service.py` — en Windows-tjänst byggd på
> pywin32 som inte går att köra på Linux. Lyssnaren i sig
> (`geoserver_listener.py`) har inga Windows-beroenden och har en egen `main()`,
> men att köra den under en Linux-processövervakare är inte en testad uppsättning.

Installern kontrollerar också att `PUBLIC` saknar `CREATE` på schemat `public`
och varnar annars. Det har varit standard sedan PostgreSQL 15, men en databas
som uppgraderats från version 14 eller äldre behåller sin gamla ACL oavsett
vilken version den körs på i dag — versionsgolvet skyddar alltså inte mot det,
utan installerns kontroll gör det. Hex:s `SECURITY DEFINER`-funktioner slår upp
objekt i `public`, så rättigheten bör återkallas:

```sql
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

### Automatisk installation (rekommenderat)

Redigera listan `DATABASES` i `install_hex.py`. Varje post är ett dict med
psycopg2-anslutningsparametrar plus `owner_role` — rollen som ska äga
Hex-objekt och hantera roller. Sätt `owner_role` till `None` för att låta den
anslutande användaren äga objekten. Anslutningen måste köras som `postgres`
(eller annan superuser) eftersom event-triggers kräver det.

```python
DATABASES = [
    {
        "host": "localhost",       # Använd "127.0.0.1" på Windows Server
        "port": 5432,
        "dbname": "geodata",       # Databas att installera Hex i
        "user": "postgres",
        "password": "losenord_har",
        "owner_role": "gis_admin", # Ägarroll för Hex-objekt, skapas om den saknas
    },
]
```

Finns inte ägarrollen i klustret skapar installern den som `NOLOGIN` utan
lösenord och rapporterar det som en varning på slutet. Rollen behöver aldrig
logga in — den äger Hex:s objekt och får `ADMIN OPTION` på schemats `r_`- och
`w_`-roller, vilket fungerar för en `NOLOGIN`-roll. Ska rollen kunna logga in
lägger du själv till det:

```sql
ALTER ROLE gis_admin LOGIN PASSWORD '...';
```

> **OBS:** Ett felstavat `owner_role` skapar en ny roll i stället för att
> återanvända den avsedda. Kontrollera varningen på slutet av installationen.

Lägg till fler poster i listan för att installera i flera databaser i samma
körning — installern loopar över alla och skriver ut en sammanfattning.

```bash
python install_hex.py              # Installera
python install_hex.py --upgrade    # Uppgradera (bevarar inställningar)
python install_hex.py --uninstall  # Avinstallera
```

> **OBS vid `--upgrade`:** konfigurationstabellerna bevaras, men lösenorden i
> `hex_rolluppgifter` **roteras** — GeoServers datastores behöver de nya
> uppgifterna. Starta om lyssnartjänsten efter uppgraderingen, se
> [docs/09](docs/09_installera-uppdatera-hex.md#hex_rolluppgifter-roteras--den-bevaras-inte).

### Manuell installation

Skapa först tilläggen som Hex kräver (installern gör detta automatiskt):

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_bytes() för lösenordsgenerering
```

Kör sedan filerna i ordningen nedan. Ordningen är en beroendeordning — hoppa
inte över filer och byt inte plats på dem.

> **OBS:** `hex_systemagare.sql` måste köras först och måste redigeras innan
> den körs (ändra `'gis_admin'` till din ägarroll). Detta är den enda filen
> installern inte kör — den genererar funktionen dynamiskt från `owner_role`.
>
> Det är också den enda filen du behöver redigera. Övriga filer hårdkodar
> aldrig ett rollnamn, utan sätter ägarskapet mot `hex_systemagare()`:
>
> ```sql
> DO $$
> BEGIN
>     EXECUTE format(
>         'ALTER TABLE public.hex_metadata OWNER TO %I',
>         public.hex_systemagare()
>     );
> END;
> $$;
> ```
>
> Manuell installation ger därför exakt samma ägarskap som `install_hex.py`.
>
> Undantagen ägs av `postgres` och sätts statiskt i SQL:en:
> - **Alla event-triggers** — de skapas av en superuser och behåller
>   `postgres`-ägande även när `owner_role` är satt.
> - **`hex_systemagare()`** samt de tre `SECURITY DEFINER`-triggerfunktionerna
>   `hex_hantera_ny_tabell()`, `hex_hantera_std_roller()` och
>   `hex_ta_bort_schemaroller()`.
>
> Övriga sju triggerfunktioner (`hex_hantera_ny_kolumn`, `hex_hantera_ny_vy`,
> `hex_hantera_borttagen_tabell`, `hex_validera_schemanamn`,
> `hex_blockera_schema_namnbyte`, `hex_notifiera_gs`,
> `hex_notifiera_gs_borttagning`) ägs av ägarrollen som allt annat. De är inte
> `SECURITY DEFINER` och behöver därför inget `postgres`-ägande — en
> event-triggerfunktion körs ändå med den anropande användarens rättigheter.

### Detaljerad installationsordning

```sql
-- 0. Konfiguration (MÅSTE köras först, redigera filen innan!)
src/sql/00_config/hex_systemagare.sql
src/sql/00_config/hex_geoserver_roller.sql

-- 1. Skapa anpassade datatyper
src/sql/01_types/hex_geom_info.sql
src/sql/01_types/hex_kolumnkonfig.sql
src/sql/01_types/hex_kolumnegenskaper.sql
src/sql/01_types/hex_tabellregler.sql

-- 2. Skapa konfigurationstabeller
src/sql/02_tables/hex_standardiserade_skyddsnivaer.sql
-- hex_schema_regex() läser hex_standardiserade_skyddsnivaer – måste köras efter tabellen
src/sql/00_config/hex_schema_regex.sql
src/sql/02_tables/hex_standardiserade_datakategorier.sql
src/sql/02_tables/hex_standardiserade_kolumner.sql
src/sql/02_tables/hex_standardiserade_roller.sql
src/sql/02_tables/hex_metadata.sql
src/sql/02_tables/hex_systemanvandare.sql
src/sql/02_tables/hex_grupprattigheter.sql
src/sql/02_tables/hex_afvaktande_geometri.sql
src/sql/02_tables/hex_dummy_geometrier.sql
src/sql/02_tables/hex_avvikande_srid.sql
src/sql/02_tables/hex_rolluppgifter.sql

-- 3. Skapa funktioner (i beroendeordning)
-- 3.1 Strukturhantering
src/sql/03_functions/01_structure/hex_hamta_geometri_definition.sql
src/sql/03_functions/01_structure/hex_hamta_kolumnstandard.sql

-- 3.2 Validering
src/sql/03_functions/02_validation/hex_validera_tabell.sql
src/sql/03_functions/02_validation/hex_validera_vynamn.sql
src/sql/03_functions/02_validation/hex_validera_schemanamn.sql
src/sql/03_functions/02_validation/hex_blockera_schema_namnbyte.sql
src/sql/03_functions/02_validation/hex_validera_geometri.sql
src/sql/03_functions/02_validation/hex_forklara_geometrifel.sql

-- 3.3 Regelhantering
src/sql/03_functions/03_rules/hex_spara_tabellregler.sql
src/sql/03_functions/03_rules/hex_spara_kolumnegenskaper.sql
src/sql/03_functions/03_rules/hex_aterskapa_tabellregler.sql
src/sql/03_functions/03_rules/hex_aterskapa_kolumnegenskaper.sql

-- 3.4 Hjälpfunktioner
src/sql/03_functions/04_utility/hex_byt_ut_tabell.sql
src/sql/03_functions/04_utility/hex_uppdatera_sekvensnamn.sql
src/sql/03_functions/04_utility/hex_skapa_historik_qa.sql
src/sql/03_functions/04_utility/hex_aterskapa_qa_trigger.sql
src/sql/03_functions/04_utility/hex_tilldela_rollrattigheter.sql
src/sql/03_functions/04_utility/hex_tillampa_grupprattigheter.sql
src/sql/03_functions/04_utility/hex_tvinga_gid_fran_sekvens.sql
src/sql/03_functions/04_utility/hex_underhall.sql

-- 3.5 Triggerfunktioner
src/sql/03_functions/05_trigger_functions/hex_ta_bort_dummy_rad.sql
src/sql/03_functions/04_utility/hex_lagg_till_dummy_geometri.sql
src/sql/03_functions/05_trigger_functions/hex_kontrollera_geometri.sql
src/sql/03_functions/05_trigger_functions/hex_hantera_ny_tabell.sql
src/sql/03_functions/05_trigger_functions/hex_hantera_ny_kolumn.sql
src/sql/03_functions/05_trigger_functions/hex_hantera_ny_vy.sql
src/sql/03_functions/05_trigger_functions/hex_ta_bort_schemaroller.sql
src/sql/03_functions/05_trigger_functions/hex_hantera_std_roller.sql
src/sql/03_functions/05_trigger_functions/hex_hantera_borttagen_tabell.sql
src/sql/03_functions/05_trigger_functions/hex_notifiera_gs.sql
src/sql/03_functions/05_trigger_functions/hex_notifiera_gs_borttagning.sql

-- 4. Skapa databastriggers
src/sql/04_triggers/hex_hantera_ny_tabell_trigger.sql
src/sql/04_triggers/hex_hantera_ny_kolumn_trigger.sql
src/sql/04_triggers/hex_hantera_ny_vy_trigger.sql
src/sql/04_triggers/hex_ta_bort_schemaroller_trigger.sql
src/sql/04_triggers/hex_hantera_std_roller_trigger.sql
src/sql/04_triggers/hex_hantera_borttagen_tabell_trigger.sql
src/sql/04_triggers/hex_validera_schemanamn_trigger.sql
src/sql/04_triggers/hex_blockera_schema_namnbyte_trigger.sql
src/sql/04_triggers/hex_notifiera_gs_trigger.sql
src/sql/04_triggers/hex_notifiera_gs_borttagning_trigger.sql
```

> Ordningen ovan speglar `INSTALL_ORDER` i `install_hex.py` (plus
> `hex_systemagare.sql`, som installern genererar själv). Ändras den ena
> måste den andra ändras likadant.

### Vanliga fel vid manuell installation

Installern gör flera saker automatiskt som du måste göra själv vid manuell
installation: skapa tilläggen, skapa ägarrollen och köra filerna i rätt
ordning. Nedan är felen det ger, med den faktiska texten PostgreSQL skriver.

**`ERROR: function public.hex_systemagare() does not exist`**
Kommer på `hex_geom_info.sql`, den andra filen i ordningen — den första
(`hex_geoserver_roller.sql`) skapar bara en roll och rör inget ägarskap.
`hex_systemagare.sql` kördes inte först, och alla filer därefter sätter sitt
ägarskap mot den funktionen.
*Åtgärd:* kör `src/sql/00_config/hex_systemagare.sql` (redigerad) före allt annat.

**`ERROR: role "<ägarroll>" does not exist`**
Med `CONTEXT: SQL statement "ALTER TYPE public.hex_geom_info OWNER TO ..."` —
alltså samma fil som ovan, den första som sätter ägarskap. Rollen som
`hex_systemagare()` returnerar finns inte i klustret. Installern skapar den
automatiskt, manuell installation gör det inte.
*Åtgärd:* `CREATE ROLE <ägarroll> NOLOGIN;` — rollen behöver aldrig logga in.

**`ERROR: type geometry does not exist`**
PostGIS saknas. Felet dyker upp först vid `hex_validera_geometri.sql`, långt
in i ordningen — tidigare filer går igenom utan tillägget.
*Åtgärd:* `CREATE EXTENSION postgis;` och kör om från den filen.

**`ERROR: permission denied to create event trigger "..."`**
Anslutningen är inte superuser. Event-triggers kräver det.
*Åtgärd:* anslut som `postgres`.

**Inga `gs_r_`/`gs_w_`-roller skapas — men installationen såg ut att lyckas**
`pgcrypto` saknas. `hex_hantera_std_roller()` behöver `gen_random_bytes()` för
att generera lösenorden. Det här är det enda felet som inte avbryter något:
installationen går igenom, `CREATE SCHEMA` fungerar och `r_`/`w_` skapas som
vanligt — bara GeoServer-tjänstekontona uteblir, med en `WARNING` som är lätt
att missa.
*Åtgärd:* `CREATE EXTENSION pgcrypto;` innan installationen. Är skadan redan
skedd räcker det inte med `hex_underhall()` — rollerna skapas bara vid
`CREATE SCHEMA`, så berörda scheman måste tas bort och skapas om.

## Detaljerad funktionsbeskrivning

### Datatyper (Custom Types)

#### `hex_geom_info`
**Syfte**: Lagrar strukturerad information om en geometrikolumn.

**Användning**: Används internt av valideringsfunktioner för att analysera och validera geometrikolumner. Innehåller fält som geometrityp, SRID, dimensioner och en komplett geometridefinition.

**Exempel**: När systemet hittar en geometrikolumn analyseras den och informationen sparas i denna typ för vidare bearbetning.

#### `hex_kolumnegenskaper`
**Syfte**: Bevarar kolumnspecifika egenskaper vid tabellomstrukturering.

**Användning**: När en tabell ska omstruktureras sparas först alla DEFAULT-värden, NOT NULL-begränsningar, CHECK-begränsningar och IDENTITY-definitioner i denna typ så de kan återskapas efteråt.

**Praktisk nytta**: Säkerställer att inga hex_kolumnegenskaper förloras när tabeller omstruktureras automatiskt.

#### `hex_metadata`
**Syfte**: Kopplar varje Hex-hanterad föräldertabell till dess historiktabell och QA-triggerfunktion via OID.

**Varför OID?** OID:er är stabila vid `ALTER TABLE RENAME TO`, till skillnad från namnkonventionsuppslag (`tabell_h`) som slutar fungera direkt vid omdöpning. `hex_metadata` är därför den auktoritativa källan för rensning och namnpropagering.

**Livscykel**:
- *Registreras* av `hex_skapa_historik_qa()` när en historiktabell skapas
- *Uppdateras* av `hex_hantera_ny_kolumn()` vid `ALTER TABLE RENAME TO` (historiktabell och parent_table uppdateras)
- *Raderas* av `hex_hantera_borttagen_tabell()` vid `DROP TABLE`

**Praktisk nytta**: En kvarliggande rad vars föräldertabell inte längre finns indikerar ett ofullständigt DROP — granska och rensa manuellt vid behov.

#### `hex_systemanvandare`
**Syfte**: Register över kända systemanvändare och verktyg som skapar tabeller i två steg (t.ex. FME).

**Användning**: När `session_user`, `current_user` eller `application_name` matchar en post här tillåter `hex_hantera_ny_tabell` att en tabell med geometrisuffix skapas utan geometrikolumn. Tabellen registreras istället i `hex_afvaktande_geometri` och geometrispecifik efterbehandling (GiST-index, valideringsbegränsning) slutförs av `hex_hantera_ny_kolumn` när geometrikolumnen läggs till via `ALTER TABLE`.

**Underhålls av**: DBA/systemadministratör. Innehåller som standard en rad för `fme`.

#### `hex_afvaktande_geometri`
**Syfte**: Tillfällig registreringstabell för tabeller skapade av en systemanvändare med geometrisuffix men utan geometrikolumn.

**Livscykel**:
- *Registreras* av `hex_hantera_ny_tabell()` när en systemanvändare skapar en tabell med geometrisuffix men utan `geom`-kolumn
- *Raderas* av `hex_hantera_ny_kolumn()` när geometrikolumnen väl har lagts till och GiST-index skapats
- *Raderas* av `hex_hantera_borttagen_tabell()` om tabellen droppas innan geometrin hinner läggas till

**Praktisk nytta**: En kvarliggande rad längre tid indikerar att verktyget (t.ex. FME) aldrig slutförde sitt andra steg — tabellen bör då granskas och eventuellt droppas manuellt.

#### `hex_kolumnkonfig`
**Syfte**: Definierar en kolumns struktur med namn, position och datatyp.

**Användning**: Används för att bygga upp den slutliga tabellstrukturen genom att kombinera standardkolumner med användardefinierade kolumner.

**Exempel**: `(gid, 1, 'integer GENERATED ALWAYS AS IDENTITY')` definierar primärnyckeln.

#### `hex_tabellregler`
**Syfte**: Bevarar tabellövergripande regler vid omstrukturering.

**Användning**: Sparar index, främmande nycklar och constraints innan en tabell omstruktureras, så de kan återskapas exakt som de var.

**Praktisk nytta**: Förhindrar att viktiga databaskopplingar och prestandaindex förloras.

### Konfigurationstabell

#### `hex_standardiserade_kolumner`
**Syfte**: Central konfiguration för vilka standardkolumner som ska läggas till tabeller.

**Användning**: Administratörer kan här definiera vilka kolumner som automatiskt ska läggas till nya tabeller, deras position (först/sist), datatyp och standardvärden.

**Kraftfull funktion - schema_uttryck**: Genom att ange SQL-uttryck kan du styra vilka scheman som får specifika kolumner. Exempel:
- `LIKE '%_kba_%'` - endast interna datakällor får dessa kolumner
- `= 'sk0_ext_sgu'` - endast detta specifika schema
- `IS NOT NULL` - alla scheman (standard)

**Historik_qa-flaggan**: Styr om kolumnen ska uppdateras via trigger (true) eller DEFAULT-värde (false).

### Strukturhanteringsfunktioner

#### `hex_hamta_geometri_definition(schema, tabell)`
**Syfte**: Analyserar en tabells geometrikolumn och returnerar fullständig information.

**Användning**: Anropas automatiskt när systemet behöver förstå vilken typ av geometri en tabell innehåller. Validerar att det finns exakt en geometrikolumn som heter 'geom'.

**Returvärde**: En `hex_geom_info`-struktur med komplett geometriinformation inklusive typ, SRID och dimensioner.

**Felhantering**: Ger tydliga felmeddelanden om tabellen har flera geometrikolumner eller om kolumnen har fel namn.

#### `hex_hamta_kolumnstandard(schema, tabell, geometriinfo)`
**Syfte**: Bestämmer exakt vilka kolumner en tabell ska ha efter omstrukturering.

**Användning**: Kombinerar tre källor:
1. Standardkolumner från `hex_standardiserade_kolumner` (filtrerade per schema)
2. Användarens ursprungliga kolumner från CREATE TABLE
3. Geometrikolumn (om sådan finns)

**Intelligent schemafiltrering**: Använder `schema_uttryck` för att avgöra vilka standardkolumner som passar för schemat.

**Returvärde**: Array med `hex_kolumnkonfig`-objekt i rätt ordning för den nya tabellstrukturen.

### Valideringsfunktioner

#### `hex_validera_schemanamn()`
**Syfte**: Säkerställer att schemanamn följer Hex namngivningskonvention.

**Mönster**: byggs dynamiskt från `hex_standardiserade_skyddsnivaer` och `hex_standardiserade_datakategorier` (standardkonfiguration: `^(sk0|sk1|sk2|skx)_(ext|kba|sys)_.+$`)

**Validering omfattar**:
- Kontroll av säkerhetsnivå (sk0, sk1, sk2, skx i standardkonfiguration)
- Kontroll av kategori (ext, kba, sys i standardkonfiguration)
- Krav på beskrivande suffix efter kategori

**Undantag**: Systemscheman (`public`, `information_schema`, `pg_*`) valideras inte.

**Trigger**: Körs vid CREATE SCHEMA - blockerar skapande av scheman med ogiltiga namn.

#### `hex_validera_tabell(schema, tabell)`
**Syfte**: Säkerställer att tabeller följer namngivningsstandarden.

**Validering omfattar**:
- Kontroll av geometrisuffix (_p, _l, _y, _g)
- Verifiering att endast en geometrikolumn finns
- Kontroll att geometrikolumnen heter 'geom'

**Returvärde**: Geometriinformation om tabellen har geometri, annars NULL.

**Praktisk nytta**: Förhindrar förvirrande tabellnamn och säkerställer konsekvent namngivning i hela databasen.

#### `hex_validera_vynamn(schema, vy)`
**Syfte**: Validerar att vyer följer namngivningsstandarden.

**Krav på vynamn**:
- Måste börja med `v_`
- Suffix baserat på geometriinnehåll (samma som tabeller)
- Vid geometritransformationer krävs explicit typkonvertering

**Exempel på korrekt vy**: `v_ledningar_p` för en vy med punktgeometrier.

### Regelhanteringsfunktioner

#### `hex_spara_tabellregler(schema, tabell)`
**Syfte**: Bevarar alla tabellövergripande regler innan omstrukturering.

**Sparar**:
- Index (förutom PRIMARY KEY och UNIQUE constraints)
- Främmande nycklar
- Constraints (PRIMARY KEY, UNIQUE, multi-kolumn CHECK)

**Returvärde**: `hex_tabellregler`-objekt med alla regler.

**Användning**: Anropas automatiskt innan en tabell omstruktureras för att inte förlora viktiga databaskopplingar.

#### `hex_spara_kolumnegenskaper(schema, tabell)`
**Syfte**: Bevarar kolumnspecifika egenskaper innan omstrukturering.

**Sparar**:
- DEFAULT-värden
- NOT NULL-begränsningar
- Kolumnspecifika CHECK-begränsningar
- IDENTITY-definitioner

**Returvärde**: `hex_kolumnegenskaper`-objekt med alla egenskaper.

**Separation från hex_tabellregler**: Håller tydlig skillnad mellan tabellövergripande regler och kolumnspecifika egenskaper.

#### `hex_aterskapa_tabellregler(schema, tabell, regler)`
**Syfte**: Återställer alla hex_tabellregler efter omstrukturering.

**Återskapar i ordning**:
1. Index (behövs ofta av constraints)
2. Constraints (PRIMARY KEY, UNIQUE, CHECK)
3. Främmande nycklar (sist för att undvika cirkelreferenser)

**Felhantering**: Detaljerad loggning av varje SQL-sats för enkel felsökning.

#### `hex_aterskapa_kolumnegenskaper(schema, tabell, egenskaper)`
**Syfte**: Återställer hex_kolumnegenskaper efter omstrukturering.

**Återskapar**:
1. NOT NULL-begränsningar
2. CHECK-begränsningar
3. DEFAULT-värden (hoppar över standardkolumner)
4. IDENTITY-definitioner

**Intelligent hantering**: Hoppar över standardkolumner som redan har rätt DEFAULT-värden.

### Hjälpfunktioner

#### `hex_byt_ut_tabell(schema, tabell, temp_tabell)`
**Syfte**: Atomisk tabellersättning utan dataförlust.

**Process**:
1. Tar bort ursprungstabellen (CASCADE för beroenden)
2. Döper om temporär tabell till originalnamnet

**Användning**: Kritisk del av omstruktureringsprocessen för att byta ut gamla tabeller mot nya.

#### `hex_uppdatera_sekvensnamn(schema, tabell, temp_suffix)`
**Syfte**: Korrigerar IDENTITY-sekvensnamn efter tabellbyte.

**Problem som löses**: När IDENTITY-kolumner skapas i temporära tabeller får sekvenserna temporära namn som måste korrigeras.

**Parameter**: `temp_suffix` – Suffixet att söka efter i sekvensnamnen (default `_temp_0001`).

**Returvärde**: Antal omdöpta sekvenser.

#### `hex_skapa_historik_qa(schema, tabell)`
**Syfte**: Skapar komplett historikhantering för kvalitetssäkring.

**Skapar**:
1. Historiktabell med suffix `_h` och alla originalkolumner
2. Triggerfunktion som loggar UPDATE och DELETE
3. Trigger som automatiskt uppdaterar QA-kolumner
4. Index för snabb sökning på gid och tidpunkt

**Returvärde**: true om historik skapades, false om inte behövs.

**Praktisk användning**: Möjliggör fullständig spårbarhet av alla dataändringar.

### Triggerfunktioner

#### `hex_hantera_ny_tabell()`
**Syfte**: Huvudfunktion som omstrukturerar nyskapade tabeller.

**Process (11 steg)**:
1. Validerar tabellnamn och geometri
2. Sparar befintliga regler och egenskaper
3. Bestämmer ny kolumnstruktur
4. Skapar temporär tabell med ny struktur
5. Byter ut tabellerna
5.5. Överför ägarskap på tabell och sekvenser till hex_systemagare()
6. Återskapar alla regler
7. Återskapar alla egenskaper
8. Skapar GiST-index för geometrikolumn
9. Lägger till geometrivalidering för scheman vars datakategori har `hex_validera_geometri = true` i `hex_standardiserade_datakategorier` (standardkonfiguration: `_kba_`)
10. Skapar historik/QA om konfigurerat

**Trigger**: Körs automatiskt vid CREATE TABLE.

**Undantag**: Hoppar över public-schema och historiktabeller.

#### `hex_hantera_ny_kolumn()`
**Syfte**: Omorganiserar kolumner när nya läggs till.

**Problem som löses**: När ALTER TABLE ADD COLUMN körs hamnar nya kolumner sist, vilket bryter standardstrukturen.

**Process**:
1. Flyttar standardkolumner med negativ position till slutet
2. Flyttar geometrikolumn allra sist

**Trigger**: Körs vid ALTER TABLE.

**Rekursionsskydd**: Använder flagga för att undvika oändliga loopar.

#### `hex_hantera_ny_vy()`
**Syfte**: Validerar att nyskapade vyer följer namnstandarden.

**Validering**: Kontrollerar prefix (v_) och suffix baserat på geometriinnehåll.

**Trigger**: Körs vid CREATE VIEW.

**Felmeddelanden**: Ger tydliga instruktioner om korrekt namngivning.

#### `hex_validera_schemanamn()`
**Syfte**: Validerar att nya scheman följer namngivningskonventionen.

**Validering**: Kontrollerar att schemanamn matchar ett mönster byggt dynamiskt från `hex_standardiserade_skyddsnivaer` och `hex_standardiserade_datakategorier`.

**Trigger**: Körs vid CREATE SCHEMA - blockerar ogiltiga schemanamn.

**Undantag**: Systemscheman (public, information_schema, pg_*) valideras inte.

#### `hex_hantera_std_roller()`
**Syfte**: Skapar roller automatiskt när nya scheman skapas, baserat på konfiguration i tabellen `hex_standardiserade_roller`.

**Funktionalitet**:
- Läser rollkonfiguration från `hex_standardiserade_roller`-tabellen
- Evaluerar `schema_uttryck` för att avgöra vilka roller som ska skapas
- Skapar NOLOGIN-grupproller (`r_`/`w_`) och LOGIN-tjänstekonton för GeoServer (`gs_r_`/`gs_w_`), per schema
- Ingen roll är längre global över flera scheman; åtkomst till flera scheman på en gång hanteras via `hex_grupprattigheter`

**Trigger**: Körs vid CREATE SCHEMA via `hex_hantera_std_roller_trigger`.

#### `hex_ta_bort_schemaroller()`
**Syfte**: Städar upp oanvända roller när scheman tas bort.

**Process**: Identifierar borttagna scheman och tar bort roller konfigurerade i `hex_standardiserade_roller` där `ta_bort_med_schema = true`. Hanterar både grupproller och LOGIN-roller.

**Trigger**: Körs vid DROP SCHEMA.

**Nytta**: Håller databasen ren från oanvända säkerhetsobjekt.

#### `hex_hantera_borttagen_tabell()`
**Syfte**: Städar upp när bastabeller tas bort.

**Process**: Identifierar borttagna tabeller och tar bort:
- Motsvarande historiktabell (`_h`) och QA-triggerfunktion (om tabellen hade historik)
- Raden i `hex_afvaktande_geometri` (om tabellen droppades innan geometrin hann läggas till)
- Raden i `hex_metadata` (om tabellen var registrerad där)

**Trigger**: Körs vid DROP TABLE (SQL_DROP-event).

**Nytta**: Förhindrar att övergivna historiktabeller, funktioner och afvaktande-rader ackumuleras i databasen.

#### `hex_notifiera_gs()`
**Syfte**: Skickar `pg_notify` till GeoServer-lyssnaren när nya scheman med `publiceras_geoserver = true` skapas (standardkonfiguration: sk0 och sk1).

**Funktionalitet**:
- Filtrerar scheman vars skyddsnivå har `publiceras_geoserver = true` i `hex_standardiserade_skyddsnivaer`
- Skickar schemanamnet som payload på kanalen `geoserver_schema`
- Fel i notifieringen blockerar **inte** schemaskapandet

**Trigger**: Körs vid CREATE SCHEMA via `hex_notifiera_gs_trigger`.

**Mottagare**: Python-lyssnaren (`geoserver_listener.py`) som skapar workspace och PostGIS-datastore i GeoServer.

#### `hex_notifiera_gs_borttagning()`
**Syfte**: Skickar `pg_notify` till GeoServer-lyssnaren när scheman med `publiceras_geoserver = true` tas bort, så att motsvarande workspace rensas ut från GeoServer.

**Funktionalitet**:
- Identifierar borttagna scheman via `pg_event_trigger_dropped_objects()`
- Filtrerar mot `hex_standardiserade_skyddsnivaer` via namnprefixet (schemat är redan borttaget och kan inte frågas direkt)
- Skickar schemanamnet som payload på kanalen `geoserver_schema_drop`
- Fel i notifieringen blockerar **inte** borttagningen av schemat

**Trigger**: Körs vid DROP SCHEMA via `hex_notifiera_gs_borttagning_trigger`.

**Mottagare**: Python-lyssnaren (`geoserver_listener.py`) som tar bort workspace och tillhörande datastores och lager i GeoServer via `DELETE /rest/workspaces/{namn}?recurse=true`.

## Exempel på användning

### Skapa schema med korrekt namngivning

```sql
-- Korrekt namngivning - fungerar
CREATE SCHEMA sk0_ext_sgu;      -- Öppen data från SGU
CREATE SCHEMA sk1_kba_bygg;     -- Kommunal byggdata
CREATE SCHEMA sk2_sys_admin;    -- Begränsad systemdata

-- Felaktig namngivning - blockeras av validering
CREATE SCHEMA min_data;         -- FEL: Följer inte mönstret
CREATE SCHEMA sk3_ext_test;     -- FEL: sk3 finns inte i hex_standardiserade_skyddsnivaer
CREATE SCHEMA sk0_foo_bar;      -- FEL: "foo" finns inte i hex_standardiserade_datakategorier
```

### Grundläggande tabellskapande

```sql
-- Skapa en tabell - systemet lägger automatiskt till standardkolumner
CREATE TABLE sk1_kba_bygg.vattenledningar_l (
    diameter integer,
    material text,
    geom geometry(LineString, 3007)
);

-- Resultatet blir automatiskt (med standardkonfigurationen i
-- hex_standardiserade_kolumner, och eftersom schemat är ett _kba_-schema):
-- gid (primärnyckel)
-- diameter
-- material  
-- skapad_tidpunkt
-- skapad_av
-- andrad_tidpunkt
-- andrad_av
-- geom (flyttad sist)
```

Vilka standardkolumner som läggs till styrs av `schema_uttryck` per rad i
`hex_standardiserade_kolumner`. I standardkonfigurationen får alla scheman `gid`
och `skapad_tidpunkt`, medan `skapad_av`, `andrad_tidpunkt` och `andrad_av` bara
läggs till i `_kba_`-scheman. Samma tabell i t.ex. `sk0_ext_sgu` hade alltså
bara fått `gid` och `skapad_tidpunkt`.

### Lägga till kolumner

```sql
-- Lägg till en kolumn - strukturen bevaras automatiskt
ALTER TABLE sk1_kba_bygg.vattenledningar_l ADD COLUMN tryck numeric;

-- Kolumnen läggs till före standardkolumnerna och geometrin
```

### Skapa vyer med korrekt namngivning

```sql
-- Korrekt namngivning för vy med punktgeometrier
CREATE VIEW sk1_kba_bygg.v_brunnar_p AS
SELECT * FROM sk1_kba_bygg.brunnar_p
WHERE status = 'aktiv';

-- Vid geometritransformationer, använd explicit typkonvertering
CREATE VIEW sk1_kba_bygg.v_buffrade_ledningar_y AS
SELECT 
    gid,
    ST_Buffer(geom, 10)::geometry(Polygon, 3007) as geom
FROM sk1_kba_bygg.vattenledningar_l;
```

## Konfiguration

### Anpassa standardkolumner

```sql
-- Lägg till en ny standardkolumn för externa datakällor
INSERT INTO hex_standardiserade_kolumner(
    kolumnnamn, 
    ordinal_position, 
    datatyp, 
    schema_uttryck, 
    beskrivning,
    historik_qa
) VALUES (
    'extern_id',           -- Kolumnnamn
    2,                     -- Position (efter gid)
    'text',                -- Datatyp
    'LIKE ''%_ext_%''',    -- Endast för externa scheman
    'ID från extern datakälla',
    false                  -- Använd DEFAULT, inte trigger
);

-- Lägg till kolumn som uppdateras via trigger
INSERT INTO hex_standardiserade_kolumner(
    kolumnnamn, 
    ordinal_position, 
    datatyp,
    default_varde,
    schema_uttryck, 
    beskrivning,
    historik_qa
) VALUES (
    'senaste_kontroll',
    -5,                    -- Placeras sist
    'timestamptz',
    'NOW()',              -- Standardvärde
    'LIKE ''%_kba_%''',   -- Endast för interna scheman
    'Tidpunkt för senaste kvalitetskontroll',
    true                  -- Uppdateras via trigger
);
```

### Schemauttryck - exempel

```sql
-- Olika sätt att filtrera vilka scheman som får kolumner:

-- Alla scheman
schema_uttryck = 'IS NOT NULL'

-- Specifikt schema
schema_uttryck = '= ''sk0_ext_sgu'''

-- Scheman som innehåller viss text
schema_uttryck = 'LIKE ''%_ext_%'''    -- Externa datakällor
schema_uttryck = 'LIKE ''%_kba_%'''    -- Interna datakällor

-- Scheman som INTE innehåller viss text
schema_uttryck = 'NOT LIKE ''%_sys_%''' -- Inte systemscheman

-- Flera specifika scheman
schema_uttryck = 'IN (''sk0_ext_sgu'', ''sk1_ext_lantmateriet'')'

-- Kombinerade villkor
schema_uttryck = 'LIKE ''sk%'' AND NOT LIKE ''%_sys_%'''
```

### Anpassa roller per schema

Vilka roller som skapas när ett schema skapas styrs av tabellen `hex_standardiserade_roller`:

```sql
-- Visa aktuell rollkonfiguration
SELECT rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran, ta_bort_med_schema
FROM hex_standardiserade_roller
ORDER BY gid;

-- Lägg till ett dedikerat läs-tjänstekonto för ett internt verktyg,
-- men bara för sk2-scheman (som inte publiceras till GeoServer).
INSERT INTO hex_standardiserade_roller (
    rollnamn,
    rolltyp,
    schema_uttryck,
    kan_logga_in,
    arvs_fran,
    ta_bort_med_schema
) VALUES (
    'app_r_{schema}',       -- {schema} ersätts med det faktiska schemanamnet
    'read',
    'LIKE ''sk2_%''',       -- Matchar alla sk2-scheman
    true,                   -- LOGIN-tjänstekonto med autogenererat lösenord
    'r_{schema}',           -- Ärver behörigheter från NOLOGIN-gruppen r_{schema}
    true                    -- Tas bort när schemat droppas
);
```

Fördefinierade roller (installeras med Hex):

| Roll | Typ | Matchar | kan_logga_in | Ärver från | Raderas med schema |
|---|---|---|---|---|---|
| `r_{schema}` | read | IS NOT NULL (alla) | Nej (NOLOGIN) | — | Ja |
| `w_{schema}` | write | IS NOT NULL (alla) | Nej (NOLOGIN) | — | Ja |
| `gs_r_{schema}` | read | IS NOT NULL (alla) | Ja (LOGIN) | `r_{schema}` | Ja |
| `gs_w_{schema}` | write | IS NOT NULL (alla) | Ja (LOGIN) | `w_{schema}` | Ja |

> Se LOGIC_MAP.md avsnitt 2 (CREATE SCHEMA) för detaljerat flöde.

## Felsökning

### Aktivera detaljerad loggning

```sql
-- Visa alla NOTICE-meddelanden för detaljerad information
SET client_min_messages = 'notice';

-- Testa systemet med en enkel tabell
CREATE TABLE sk0_ext_test.test_tabell_p (
    namn text,
    geom geometry(Point, 3007)
);

-- Kontrollera resultatet
\d sk0_ext_test.test_tabell_p
```

### Vanliga problem och lösningar

**Problem**: Schema kan inte skapas  
**Lösning**: Kontrollera att schemanamnet följer namnkonventionen — se giltiga prefix och kategorier i `hex_standardiserade_skyddsnivaer` och `hex_standardiserade_datakategorier` (t.ex. `sk0_kba_bygg`, `skx_ext_test`)

**Problem**: Tabell skapas inte med standardkolumner  
**Lösning**: Kontrollera att alla triggers är aktiverade och att schemat inte är 'public'

**Problem**: Geometrikolumn hamnar inte sist  
**Lösning**: Verifiera att geometrikolumnen heter exakt 'geom'

**Problem**: Fel vid omstrukturering  
**Lösning**: Kontrollera loggmeddelanden för detaljerad felinformation

**Problem**: Historiktabell skapas inte  
**Lösning**: Verifiera att minst en kolumn har `historik_qa = true` i `hex_standardiserade_kolumner`

### Kontrollera systemstatus

```sql
-- Lista alla event triggers
SELECT evtname, evtevent, evtenabled 
FROM pg_event_trigger 
ORDER BY evtname;

-- Lista alla konfigurerade standardkolumner
SELECT kolumnnamn, ordinal_position, datatyp, schema_uttryck, historik_qa
FROM hex_standardiserade_kolumner
ORDER BY ordinal_position;

-- Kontrollera vilka av dem ett visst schema faktiskt får.
-- OBS: schema_uttryck är ett SQL-predikat ('IS NOT NULL', 'LIKE ''%_kba_%''')
-- och inte ett LIKE-mönster – det måste evalueras dynamiskt.
DO $$
DECLARE
    mal_schema text := 'sk1_kba_bygg';
    r record;
    traffar boolean;
BEGIN
    FOR r IN SELECT kolumnnamn, ordinal_position, datatyp, schema_uttryck
             FROM hex_standardiserade_kolumner ORDER BY ordinal_position
    LOOP
        EXECUTE format('SELECT %L %s', mal_schema, r.schema_uttryck) INTO traffar;
        IF traffar THEN
            RAISE NOTICE '% (pos %, %)', r.kolumnnamn, r.ordinal_position, r.datatyp;
        END IF;
    END LOOP;
END;
$$;

-- Verifiera att funktionerna finns (samtliga har hex_-prefix)
SELECT p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname LIKE 'hex\_%'
ORDER BY p.proname;
```

## Avinstallation

### Rekommenderad metod — installationsskriptet

Det enklaste sättet att ta bort systemet är via installationsskriptet:

```bash
python install_hex.py --uninstall
```

Skriptet kör alla DROP-satser i rätt ordning och rullar tillbaka om något misslyckas.

### Manuell avinstallation

Om du föredrar att köra SQL direkt, kör följande block som superanvändare (t.ex. `postgres`). Ordningen är viktig — event triggers måste tas bort innan funktioner, typer sist.

```sql
-- 1. Ta bort event triggers (måste tas bort innan funktioner)
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_borttagning_trigger;
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_trigger;
DROP EVENT TRIGGER IF EXISTS hex_validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_std_roller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_kolumn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_borttagen_tabell_trigger;

-- 2. Ta bort triggerfunktioner
DROP FUNCTION IF EXISTS public.hex_notifiera_gs_borttagning();
DROP FUNCTION IF EXISTS public.hex_notifiera_gs();
DROP FUNCTION IF EXISTS public.hex_hantera_std_roller();
DROP FUNCTION IF EXISTS public.hex_ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_kolumn();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hex_hantera_borttagen_tabell();

-- 3. Ta bort hjälpfunktioner
DROP FUNCTION IF EXISTS public.hex_tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.hex_skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.hex_uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.hex_byt_ut_tabell(text, text, text);

-- 4. Ta bort regelfunktioner
DROP FUNCTION IF EXISTS public.hex_aterskapa_kolumnegenskaper(text, text, hex_kolumnegenskaper);
DROP FUNCTION IF EXISTS public.hex_aterskapa_tabellregler(text, text, hex_tabellregler);
DROP FUNCTION IF EXISTS public.hex_spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.hex_spara_tabellregler(text, text);

-- 5. Ta bort valideringsfunktioner
DROP FUNCTION IF EXISTS public.hex_validera_geometri(geometry) CASCADE;
DROP FUNCTION IF EXISTS public.hex_validera_schemanamn();
DROP FUNCTION IF EXISTS public.hex_validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.hex_validera_tabell(text, text);

-- 6. Ta bort strukturfunktioner
DROP FUNCTION IF EXISTS public.hex_hamta_kolumnstandard(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_hamta_geometri_definition(text, text);

-- 7. Ta bort konfigurationsfunktion
DROP FUNCTION IF EXISTS public.hex_systemagare();

-- 8. Ta bort konfigurationstabeller
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.hex_standardiserade_roller;
DROP TABLE IF EXISTS public.hex_standardiserade_kolumner;
DROP TABLE IF EXISTS public.hex_standardiserade_skyddsnivaer;
DROP TABLE IF EXISTS public.hex_standardiserade_datakategorier;

-- 9. Ta bort anpassade typer (måste tas bort efter funktioner som använder dem)
DROP TYPE IF EXISTS public.hex_tabellregler;
DROP TYPE IF EXISTS public.hex_kolumnegenskaper;
DROP TYPE IF EXISTS public.hex_kolumnkonfig;
DROP TYPE IF EXISTS public.hex_geom_info;
```

## Licens

MIT License - Se LICENSE-filen för detaljer

## Bidrag

Bidrag välkomnas! Skapa en issue eller pull request på GitHub.

## Support

För frågor och support, kontakta databasadministratören eller skapa en issue i projektets GitHub-repository.
