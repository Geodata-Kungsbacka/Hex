# 12. Pausa Hex vid pg_dump och pg_restore

Hex reagerar på DDL. En återläsning **är** DDL – tusentals satser i rad. Går de
satserna genom Hex tio event-triggers blir resultatet inte bara långsamt utan
destruktivt, och tre av fyra sätt är tysta.

Men det gäller inte varje återläsning. Vilken form dumpen läses in i avgör om
Hex ens är igång när satserna kommer, och det avgör i sin tur om pausen behövs.
Börja därför med nästa avsnitt – det säger vilken rutin som gäller ditt fall.

---

## Behöver just din återläsning pausen?

`pg_dump` lägger event-triggers **sist** i dumpen. Det går att se direkt:

```bash
pg_restore -l prod.dump | grep -n "EVENT TRIGGER"
```

De hamnar efter alla `TABLE DATA`-poster och efter index och villkor. Det ger
fem lägen:

| Återläsningens form | Är Hex igång under körningen? | Vad som krävs |
| --- | --- | --- |
| Full dump till en **tom** måldatabas | Nej. Event-triggarna finns inte förrän på slutet, och skapas då påslagna. | Ingen paus |
| Full dump med `--clean` till en Hex-databas | Nej. `--clean` droppar event-triggarna först av allt och skapar om dem sist. | Ingen paus |
| **Delvis** återläsning till en levande Hex-databas (`-n <schema>`, `--data-only`, enstaka tabeller) | **Ja.** Dumpen rör aldrig event-triggarna, så de står påslagna hela tiden. | **Paus – och målschemat måste droppas inuti pausen.** Se *Delvis återläsning* |
| Dump från en **icke-Hex**-databas till en Hex-databas | **Ja.** Samma skäl. | **Paus** |
| `-n <schema>`-dump till en databas **utan** Hex | Nej, där finns ingen Hex att pausa. | Pausen hjälper inte. Se *Dump till en databas utan Hex* |

Uppmätt mot en testdatabas med `vagar_l` (50 rader, geometri), `punkter_p`
(1 rad, geometri) och `referens` (20 rader, ingen geometri):

| Fall | Avslutskod | Fel | Data efteråt |
| --- | --- | --- | --- |
| Full dump → tom databas | 0 | 0 | komplett |
| Full dump `--clean` → Hex-databas | 0 | 0 | komplett |
| `-n schema` → levande Hex, schemat kvar, **med** paus | 1 | 38 | oförändrad – `gid`-nyckeln blockerar |
| `-n schema` → levande Hex, `DROP SCHEMA` **inuti** pausen | 0 | 0 | komplett |
| `-n schema` → databas utan Hex | 1, men **0 via psql** | 22 | geometritabellerna skapas aldrig |

> **De två första raderna gäller bara Hex med låst `search_path`.** Fram till
> den här versionen saknade `hex_validera_geometri()` sin `SET search_path`.
> `pg_restore` kör med `search_path = ''`, så `ST_IsValid` inuti funktionen gick
> inte att slå upp, `CHECK`-villkoret `validera_geom_<tabell>` föll på varje rad
> och `COPY` avbröts. Resultatet var en tabell med rätt struktur och **noll
> rader** – i just de två fall som här står som riskfria. Se
> *Geometrivalideringen och tom search_path* nedan innan du läser in mot en
> databas som kör en äldre Hex.

> **Efterarbetet behövs alltid.** Rollerna är kluster-globala och ligger
> inte i dumpen, ägarskapet försvinner med `--no-owner`, och GeoServer vet
> ingenting om den nya databasen. Kör därför alltid `hex_ateruppta()` efteråt,
> också när ingen paus togs – den kör `hex_underhall()`, som är reparationen.
> Se *Återupptagandet* nedan.
>
> Efter en **full** återläsning med `--no-owner` räcker det inte:
> `public.hex_*` står då kvar med `postgres` som ägare, och det lägger varken
> `hex_ateruppta()` eller `hex_underhall()` tillbaka. Kör
> `install_hex.py --upgrade` också. Se *`--no-owner` tar ägarskapet* nedan.

---

## Kortversionen

```sql
-- 1. I MÅLDATABASEN, som superanvändare
SELECT * FROM hex_pausa('pg_restore av prod till test, ärende 12345', 8);

-- 2. Bara vid DELVIS återläsning: rensa målschemat, och gör det INUTI pausen.
--    Utan det här steget kolliderar dumpen med objekt som redan finns.
--    Utanför pausen river DROP SCHEMA i stället roller och GeoServer-workspace.
DROP SCHEMA IF EXISTS sk1_kba_vagar CASCADE;
```

```bash
# 3. Dump och återläsning. --exit-on-error gör att ett fel stoppar körningen
#    i stället för att räknas och passeras.
pg_dump    -Fc -f prod.dump prod_db
pg_restore -d test_db --no-owner --no-privileges --exit-on-error prod.dump
```

```sql
-- 4. Tillbaka i måldatabasen
SELECT * FROM hex_ateruppta();

-- 5. Kontrollera
SELECT * FROM hex_pausstatus();
```

`hex_ateruppta()` kör `hex_underhall()` som del av steg 3. Det är där rollerna,
rättigheterna, ägarskapet och GeoServer-notifieringarna kommer tillbaka.

**Hoppa aldrig över steg 3, inte ens när steg 1 aldrig kördes.** Underhållet
körs även när databasen inte är pausad – reparationen behövs oavsett hur
dumpen lästes in, och pausen kan dessutom ha raderats av själva återläsningen
(se *Dumpen bär med sig pausen*).

---

## Geometrivalideringen och tom search_path

Det här är inte ett pausproblem. Det slår mot varje återläsning, också de som
tabellen ovan markerar som riskfria, och det är den enda felvägen som förstör
data i stället för att bara bråka.

`pg_dump` och `pg_restore` inleder sin utmatning med

```sql
SELECT pg_catalog.set_config('search_path', '', false);
```

Tom `search_path` är rätt av dumpen: allting den skriver är schemakvalificerat,
och en tom sökväg gör att inget objekt av misstag slås upp någon annanstans.
Men den gäller också allt som **Hex** kör inifrån återläsningen.

`hex_validera_geometri()` sitter som `CHECK`-villkor på varje `_kba_`-tabell med
geometri, och `hex_kontrollera_geometri_trigger()` som radtrigger. Båda anropar
`ST_IsValid` och andra PostGIS-funktioner utan schemaprefix. Slås namnen upp via
anroparens tomma `search_path` finns de inte:

```
pg_restore: error: COPY failed for table "vagar_l": ERROR:  function st_isvalid(public.geometry) does not exist
```

`COPY` avbryts för hela tabellen. Kvar blir en tabell med rätt kolumner, rätt
index, rätt triggers – och noll rader. `pg_restore` returnerar 1, men allt ser
riktigt ut i pgAdmin. Det var så alla `_kba_`-tabeller med geometri tömdes.

Tre funktioner har därför låst `search_path`:

| Funktion | Var den körs från |
| --- | --- |
| `hex_validera_geometri(geometry)` | `CHECK`-villkoret `validera_geom_<tabell>` |
| `hex_forklara_geometrifel(geometry)` | geometritriggerns felmeddelanden |
| `hex_kontrollera_geometri_trigger()` | radtriggern `hex_kontrollera_geom` |

Kontrollera att låsningen finns i måldatabasen innan du läser in:

```sql
SELECT proname, proconfig
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  proname IN ('hex_validera_geometri',
                   'hex_forklara_geometrifel',
                   'hex_kontrollera_geometri_trigger');
```

`proconfig` ska innehålla `search_path=public, pg_temp`. Är den `NULL` kör
databasen en Hex från före den här versionen.

### Om måldatabasen kör en äldre Hex

Uppgradera den först – det är den enda åtgärd som håller. Går inte det, lås
funktionerna för hand **innan** datat läses in:

```sql
ALTER FUNCTION public.hex_validera_geometri(geometry)    SET search_path = public, pg_temp;
ALTER FUNCTION public.hex_forklara_geometrifel(geometry) SET search_path = public, pg_temp;
ALTER FUNCTION public.hex_kontrollera_geometri_trigger() SET search_path = public, pg_temp;
```

För en **tom** måldatabas finns inte funktionerna än när återläsningen börjar.
Dela då upp den i tre sektioner och lås mellan struktur och data:

```bash
pg_restore -d nytt_db --no-owner --no-privileges --section=pre-data  --exit-on-error prod.dump
psql       -d nytt_db -v ON_ERROR_STOP=1 -f las_search_path.sql      # ALTER-satserna ovan
pg_restore -d nytt_db --no-owner --no-privileges --section=data      --exit-on-error prod.dump
pg_restore -d nytt_db --no-owner --no-privileges --section=post-data --exit-on-error prod.dump
```

Ordningen fungerar därför att `pg_dump` lägger funktioner i `pre-data` och
event-triggers i `post-data`: när datat kommer finns geometrifunktionerna, och
Hex är ännu inte igång.

Handpålagda `ALTER FUNCTION` överlever inte. `CREATE OR REPLACE FUNCTION` ersätter
funktionens **alla** attribut, så både `--install`, `--upgrade` och nästa
`pg_restore --clean` av en dump tagen från en äldre databas tar bort låsningen
igen, tyst. Det är därför den ligger i `src/sql/` och inte i en rutin.

> **PostGIS förutsätts ligga i `public`.** Låsningen ersätter anroparens
> `search_path`, så ligger extensionen i ett eget schema hittas `ST_*` inte av
> någon anropare alls. Flyttas PostGIS måste schemat läggas till i alla tre
> funktionerna.

---

## Varför pausen behövs

Det räcker inte att säga att det blir "mycket brus i loggen". Utan paus går
återläsningen fel på fyra sätt, och tre av dem är tysta. (Det femte sättet,
den tomma `search_path`, är inte pausens att lösa och har ett eget avsnitt
ovan.)

### 1. Varje återläst tabell omstruktureras

`hex_hantera_ny_tabell()` fångar dumpens `CREATE TABLE` och gör om tabellen
enligt `hex_standardiserade_kolumner`: lägger till `gid`, QA-kolumner,
sekvens, GiST-index, historiktabell och fem radtriggers. När pg_restore sedan
kommer till sina egna satser för samma objekt får den:

```
pg_restore: error: could not execute query: ERROR:  relation "vagar_l_h" already exists
pg_restore: error: could not execute query: ERROR:  trigger "hex_tvinga_gid" for relation "vagar_l" already exists
```

### 2. Fel räknas som ignorerade varningar och körningen fortsätter

`pg_restore` avbryter inte på fel utan `--exit-on-error`. Den räknar dem och
går vidare:

```
pg_restore: warning: errors ignored on restore: 10
```

Avslutskoden blir **1** när fel ignorerades, så en rutin som kontrollerar
`$?` fångar just den här körningen. Två saker gör ändå att felen är lätta att
missa:

- Läses dumpen in med `psql` i stället för `pg_restore` – vilket gäller
  textformat, alltså `pg_dump` utan `-Fc`/`-Fd` – avslutar `psql` med **0**
  om inte `ON_ERROR_STOP` är satt. Uppmätt: 32 fel i loggen, avslutskod 0,
  och två av sex tabeller saknades. Med `-v ON_ERROR_STOP=1` blev koden 3.
- Utan paus är felen tiotals `already exists` från steg 1 – 38 på ett schema
  med tre tabeller – och ett verkligt `COPY`-fel drunknar i mängden. Tabellen
  finns, ser rimlig ut i pgAdmin, och saknar rader.

Därför är radantalskontrollen i *Efterkontroll* det som faktiskt svarar på om
datat kom fram. Avslutskoden räcker inte.

### 3. `DROP SCHEMA` river roller och GeoServer-uppsättning

`DROP SCHEMA` mot en databas där Hex är igång utlöser:

- `hex_ta_bort_schemaroller()` – tar bort schemats roller (`r_`, `w_`,
  `gs_r_`, `gs_w_`). Den lyckas inte alltid med alla fyra: en roll som äger
  objekt någon annanstans, till exempel default-rättigheter, ger en `WARNING`
  och blir kvar. Uppmätt lämnades `r_` och `w_` kvar medan `gs_`-rollerna togs
  – halv städning, utan att `DROP SCHEMA` misslyckades.
- `hex_notifiera_gs_borttagning()` – ber GeoServer-lyssnaren radera workspace
  och PostGIS-datastore.

Rollerna finns inte i dumpen (de är kluster-globala) och GeoServer-uppsättningen
finns inte heller där. Båda måste byggas upp igen efteråt.

**Men inte vid `--clean` av en full Hex-dump.** `pg_restore --clean` skickar
sina `DROP`-satser i omvänd ordning mot dumpens innehållsförteckning, och
event-triggarna ligger sist där. De droppas alltså allra först, innan
`DROP SCHEMA` hinner köras, och det som återstår går inte genom Hex:

```
DROP EVENT TRIGGER IF EXISTS hex_validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_ta_bort_schemaroller_trigger;
...
```

Verifierat: efter en `--clean`-återläsning av en full Hex-dump står schemats
fyra roller kvar.

Faran gäller i stället de fall där dumpen inte innehåller Hex event-triggers –
en dump från en icke-Hex-databas, eller ett manuellt `DROP SCHEMA` före
återläsningen. Då är triggarna kvar och påslagna, och rollerna försvinner.

### 4. Ett ogiltigt schemanamn i dumpen rullar tillbaka hela transaktionen

`hex_validera_schemanamn()` kastar `EXCEPTION` för namn som inte matchar
mönstret. Läser du in ett äldre schema som inte följer dagens konvention
stoppas återläsningen där.

---

## Vad `hex_pausa()` gör

| Steg | Åtgärd |
| --- | --- |
| 1 | `ALTER EVENT TRIGGER ... DISABLE` på alla event-triggers som pekar på en `public.hex_*`-funktion |
| 2 | `ALTER TABLE ... DISABLE TRIGGER` på alla icke-interna radtriggers i Hex-scheman (om `p_radtriggers = true`) |
| 3 | Skriver en rad i `hex_paus` med lägena som gällde före pausen |

Parametrar:

```sql
hex_pausa(
    p_anledning   text    DEFAULT NULL,   -- fritext, hamnar i hex_paus
    p_max_timmar  integer DEFAULT 24,     -- varningsgräns, NULL = ingen
    p_radtriggers boolean DEFAULT true    -- stäng även av radtriggers
)
```

`p_max_timmar` återupptar ingenting automatiskt. Den sätter `pausad_till`, och
`hex_pausstatus()` flaggar när gränsen passerats. Det är vad som gör en glömd
paus möjlig att upptäcka i en övervakningsfråga.

### Vad pausen inte täcker

- **CHECK-villkor.** Geometrivalideringen `validera_geom_<tabell>` gäller varje
  `INSERT`, även under paus. Data som passerade valideringen i källdatabasen
  passerar den vid återläsning. Äldre data som aldrig validerats gör det inte,
  och då behöver villkoret tas bort och läggas tillbaka som `NOT VALID` för
  hand. Att villkoret alls går att utvärdera under en återläsning beror på
  `search_path`-låsningen, inte på pausen – se avsnittet om den ovan.
- **Främmande nycklar.** Interna triggar lämnas påslagna med flit – en paus ska
  inte kunna smuggla in referensbrott.
- **Roller.** De är kluster-globala och ligger inte i en `pg_dump`. Se nedan.
- **Objekt som redan finns.** Pausen hindrar Hex från att skapa nya objekt. Den
  tar inte bort de gamla. Läses ett schema in ovanpå sig självt kolliderar
  dumpens satser med det som redan står där, och radtabellerna får dubbletter.
  Målschemat måste bort först – se nästa avsnitt.
- **Historiktabeller.** `_h`-tabellerna har ingen primärnyckel, eftersom samma
  `gid` med flit förekommer i flera versioner. En återläsning ovanpå ett
  befintligt schema **lägger därför till** rader i `_h` utan att någonting
  klagar. Modertabellerna skyddas av `PRIMARY KEY (gid)`; historiken gör det
  inte.

---

## Delvis återläsning: målschemat måste bort först

Pausen ensam räcker inte för `pg_restore -n <schema>` mot en levande
Hex-databas. Uppmätt på ett schema med tre tabeller: **38 fel** med pausen på,
noll utan att en enda rad kommit in i geometritabellerna. Alla 38 är
kollisioner mot objekt som redan fanns – tabeller, sekvenser, index,
triggerfunktioner, `PRIMARY KEY`.

Två av felen är värda att läsa noga:

```
pg_restore: error: COPY failed for table "referens": ERROR:  duplicate key value violates unique constraint "referens_pkey"
```

Det är `PRIMARY KEY (gid)` som fångar dumpens rader mot de befintliga. Utan den
nyckeln hade samma återläsning tyst **lagt till** hela dumpen ovanpå: en tabell
som gick från 20 till 40 rader, utan ett enda felmeddelande. Nyckeln gör
kollisionen hörbar, men den gör inte återläsningen rätt.

Rätt ordning är att tömma målet **inuti** pausen:

```sql
-- 1. Pausa FÖRST
SELECT * FROM hex_pausa('pg_restore av sk1_kba_vagar, ärende 12345', 8);

-- 2. Rensa målschemat. Ordningen är hela poängen: utanför pausen utlöser
--    DROP SCHEMA hex_ta_bort_schemaroller() och hex_notifiera_gs_borttagning(),
--    alltså bortrivna roller, tömd hex_rolluppgifter och ett raderat
--    GeoServer-workspace. Under pausen händer ingetdera.
DROP SCHEMA IF EXISTS sk1_kba_vagar CASCADE;
```

```bash
pg_dump    -Fc -n sk1_kba_vagar -f schema.dump kalla_db
pg_restore -d mal_db --no-owner --no-privileges --exit-on-error schema.dump
```

```sql
-- 3. Återuppta
SELECT * FROM hex_ateruppta();
```

Uppmätt: avslutskod 0, noll fel, alla rader på plats, alla fyra roller kvar och
samtliga radtriggers påslagna igen.

`DROP SCHEMA` under paus lämnar rollerna. Det är önskvärt här – de är
kluster-globala, dumpen bär dem inte, och `hex_underhall()` skulle annars
generera nya `gs_`-lösenord i onödan. Ska schemat bort på riktigt, och inte
bara ersättas, droppa det **utan** paus så att Hex städar rollerna och
GeoServer.

> Utanför pausen städar `DROP SCHEMA` dessutom bara halvvägs.
> `hex_ta_bort_schemaroller()` tar `gs_r_` och `gs_w_`, men `r_` och `w_` blir
> kvar med en `WARNING` när de äger objekt någon annanstans – till exempel
> default-rättigheter. Ett `WARNING`, inte ett fel, och `DROP SCHEMA` returnerar
> ändå framgång.

---

## Dump till en databas utan Hex

`pg_dump -n <schema>` tar med schemat och ingenting annat. `public.hex_*` följer
alltså **inte** med, men de återskapade tabellerna refererar till dem:

- `CHECK (public.hex_validera_geometri(geom))` på varje `_kba_`-geometritabell
- `EXECUTE FUNCTION public.hex_tvinga_gid_fran_sekvens()` på varje Hex-tabell

I en måldatabas utan Hex finns funktionerna inte, så `CREATE TABLE` faller på
sitt eget villkor och **tabellen skapas aldrig**. Allt som därefter refererar
till den faller också. Uppmätt: 22 fel, och av sex tabeller landade bara
`referens` och de tre `_h`-tabellerna – båda geometritabellerna saknades helt.

Värst är avslutskoden. Med `pg_restore` blir den 1. Läses samma sak in som
textdump genom `psql` utan `ON_ERROR_STOP` blir den **0**, med 32 fel i loggen.
En rutin som bara kontrollerar avslutskoden rapporterar en lyckad återläsning
av en databas som saknar sina geometritabeller.

Pausen ändrar ingenting här – det finns ingen Hex i måldatabasen att pausa.
Välj i stället en av tre vägar:

1. **Installera Hex i måldatabasen först.** Då finns funktionerna, och fallet
   blir "delvis återläsning" enligt föregående avsnitt.
2. **Ta med `public`.** `pg_dump -n public -n sk1_kba_vagar` får med
   Hex-funktionerna. Tabellerna behåller sina villkor och triggers, och
   måldatabasen blir i praktiken en Hex-databas.
3. **Frikoppla schemat.** Vill du ha rena tabeller utan Hex-beroenden, ta bort
   villkoren och triggarna i en kopia av källschemat innan du dumpar:

   ```sql
   -- i en kopia, inte i produktionsschemat
   DO $$
   DECLARE r record;
   BEGIN
       FOR r IN SELECT n.nspname, c.relname, con.conname
                FROM pg_constraint con
                JOIN pg_class c ON c.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'sk1_kba_vagar' AND con.conname LIKE 'validera_geom_%'
       LOOP
           EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', r.nspname, r.relname, r.conname);
       END LOOP;

       FOR r IN SELECT n.nspname, c.relname, t.tgname
                FROM pg_trigger t
                JOIN pg_class c ON c.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'sk1_kba_vagar' AND NOT t.tgisinternal
       LOOP
           EXECUTE format('DROP TRIGGER %I ON %I.%I', r.tgname, r.nspname, r.relname);
       END LOOP;
   END $$;
   ```

Kör alltid `psql` med `-v ON_ERROR_STOP=1` när dumpen är textformat. Utan den
finns ingen avslutskod att gå på.

---

## Roller följer inte med dumpen

`pg_dump` dumpar en databas. Roller ligger i klustret. Läser du in i ett **nytt**
kluster saknas alltså `r_`, `w_`, `gs_r_` och `gs_w_` för varje schema, och
dumpens `GRANT`-satser faller.

Kör därför återläsningen med `--no-owner --no-privileges` och låt
`hex_underhall()` bygga upp behörigheterna i stället. Den körs automatiskt av
`hex_ateruppta()` och:

- återskapar rollerna från `hex_standardiserade_roller` (som ligger *i*
  databasen och därför följer med dumpen),
- sätter ägarskap på scheman, tabeller, sekvenser och funktioner **i
  Hex-schemana**,
- delar ut schemarättigheter,
- kopplar tillbaka radtriggers som saknas,
- skickar `pg_notify('geoserver_schema', ...)` för varje publicerat schema.

Alternativet är att ta med rollerna själv:

```bash
pg_dumpall --globals-only --roles-only > roller.sql
```

### `--no-owner` tar ägarskapet på Hex egna funktioner, och underhållet lägger inte tillbaka det

Det här är undantaget från stycket ovan, och det är lätt att missa eftersom
allting fortsätter fungera – tills något GRANT:ar.

En full återläsning med `--no-owner` skapar om **alla** `public.hex_*` med
`postgres` som ägare. `hex_underhall()` rör dem inte: det sätter ägarskap på
objekten i Hex-schemana, inte på Hex egen funktionskatalog i `public`. Uppmätt
efter en `pg_restore --clean --no-owner` av en full dump:

```
   agare   | count
-----------+-------
 postgres  |    41
```

Mot en ren installation:

```
   agare   | count
-----------+-------
 gis_admin |    37
 postgres  |     4
```

De fyra som ska vara `postgres` är `hex_systemagare()` och de tre
`SECURITY DEFINER`-triggerfunktionerna. Fördelningen går inte att härleda ur
katalogen – `hex_tillampa_grupprattigheter` är också `SECURITY DEFINER` men ska
ägas av `hex_systemagare()` – så det finns ingen körningsregel som kan reparera
den. Källan är `ALTER FUNCTION ... OWNER TO` i `src/sql/`.

Följden är konkret: `hex_tillampa_grupprattigheter` som ägs av `postgres`
kan inte `GRANT`:a Hex-rollerna vidare, eftersom ägaren saknar `ADMIN OPTION`
på dem. `tests/test_grupprattigheter.sql` fångar just det.

**Reparationen är `install_hex.py --upgrade`, inte `hex_ateruppta()`.**
Uppgraderingen kör om SQL-filerna, och det är där ägarskapet står. Uppmätt:
41 postgres-ägda funktioner före, 37/4 efter – samma fördelning som en ren
installation.

```bash
# efter en full återläsning med --no-owner
python install_hex.py --upgrade
```

Kontrollera med:

```sql
SELECT pg_get_userbyid(proowner) AS agare, count(*)
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND proname LIKE 'hex\_%'
GROUP  BY 1;
```

Står **noll** funktioner på `hex_systemagare()` har återläsningen tagit
ägarskapet. Någon enstaka avvikelse är något annat och ska undersökas för hand.

### GeoServer-lösenord roteras

Saknas en `gs_`-roll helt i målklustret genererar `hex_underhall()` ett **nytt**
lösenord och skriver över raden i `hex_rolluppgifter`. Lösenorden från dumpen
gäller alltså inte efteråt. Lyssnaren läser `hex_rolluppgifter` och plockar upp
de nya vid notifieringen, så GeoServer ställer om sig själv – förutsatt att
lyssnaren kör mot det nya klustret.

---

## Dumpen bär med sig pausen

`pg_dump` skriver ut avstängningen:

```sql
ALTER EVENT TRIGGER hex_hantera_ny_tabell_trigger DISABLE;
```

Och `hex_paus` är en vanlig tabell, så bokföringsraden följer också med. En dump
tagen under paus läses alltså in som **pausad**.

Det är oftast önskvärt – den återlästa kopian är avstängd tills någon medvetet
återupptar den – men det är lätt att missa. `hex_pausstatus()` är till för det:

```sql
SELECT * FROM hex_pausstatus() WHERE pausad OR avvikelse IS NOT NULL;
```

Kolumnen `avvikelse` fångar de lägen som annars är tysta:

| Läge | Vad det betyder |
| --- | --- |
| Event-triggers påslagna medan `hex_paus` säger pausat | En ominstallation har körts. Filerna i `src/sql/04_triggers/` gör `DROP` + `CREATE EVENT TRIGGER`, och en nyskapad event-trigger är alltid påslagen. Kör `hex_ateruppta()` för att städa bokföringen. |
| Event-triggers avstängda utan att Hex är pausat | Dump tagen under paus, eller ett manuellt `ALTER EVENT TRIGGER`. |
| Radtriggers som pausen stängde av är påslagna igen | `hex_underhall()` eller en ominstallation har skapat om dem, och en nyskapad trigger är alltid påslagen. Pausen håller inte fullt ut. |
| Pausmarkör satt men `hex_paus` tom | En återläsning har droppat tabellen. Se nedan. |
| `pausad_till` har passerat | Någon glömde återuppta. |

`install_hex.py` varnar också vid installation mot en pausad databas.

### `pg_restore --clean` raderar bokföringen

`hex_paus` är en vanlig tabell i `public`. `--clean` droppar den tillsammans
med allt annat i dumpen, och skapar sedan om event-triggarna påslagna. Kvar
blir en databas som ser opausad och felfri ut, mitt i den återläsning pausen
skulle skydda.

Därför sätter `hex_pausa()` också en **pausmarkör** utanför databasens
objektgraf:

```sql
ALTER DATABASE <db> SET "hex.paus" = '<tidpunkt>';
```

Den ligger i `pg_db_role_setting`, som hör till databasobjektet och inte till
innehållet. `pg_restore --clean` rör den inte, och en `pg_dump` utan `--create`
bär inte med sig den. Läs den med `hex_pausmarkor()`.

Överlever markören medan `hex_paus` försvann är det kvittot på att en
återläsning tog bokföringen, och `hex_pausstatus()` säger det rakt ut:

```
pausad | pausmarkor | avvikelse
-------+------------+---------------------------------------------------------
 f     | t          | Pausmarkör satt sedan 2026-08-26 …, men hex_paus är tom.
                      En återläsning (pg_restore --clean) har droppat tabellen…
```

Lägena före pausen gick förlorade med tabellen – de stod bara i
`tidigare_lage`. `hex_ateruppta()` kör då underhållet och **redovisar** vad som
fortfarande står avstängt i stället för att gissa att allt var påslaget:

```
 objekt                          | typ           | atgard
---------------------------------+---------------+--------------------------------------
 hex_hantera_ny_tabell_trigger   | event-trigger | avstängd – ingen bokföring, bedöm för hand
```

### Installation under paus

Både `--install` och `--upgrade` skapar om event-triggarna, och en nyskapad
event-trigger är alltid påslagen. En installation häver alltså pausen. Skillnaden
mellan lägena:

| Körning | Vad som händer med `hex_paus` |
| --- | --- |
| `--install` | Raden ligger kvar (`CREATE TABLE IF NOT EXISTS`). |
| `--upgrade` | Tabellen droppas och skapas om, men raden återställs — `hex_paus` står i `PRESERVE_STATE`. |

I båda fallen är raden kvar medan event-triggarna är påslagna, och
`hex_pausstatus()` flaggar just den motsägelsen. Kör `hex_ateruppta()` efteråt:
den lägger tillbaka radtriggarna från `tidigare_lage` och städar bort raden.

Att raden bevaras över `--upgrade` är avsiktligt. Uppgraderingen återskapar
bara de radtriggers vars triggerfunktion ligger i `public` — de droppas av
`DROP FUNCTION ... CASCADE` och skapas om påslagna av `hex_underhall()`. De vars
funktion ligger i Hex-schemat (`trg_<tabell>_qa`, `hex_tvinga_anvandarvarden`)
överlever avinstallationen och rörs aldrig: `hex_underhall()` skapar **saknade**
triggers, men slår inte på **avstängda**. Utan `tidigare_lage` vore de omöjliga
att hitta, och historik och QA-kolumner skulle sluta uppdateras tyst på de
tabellerna.

Pågår en återläsning: avbryt installationen och kör den efteråt.

---

## Återupptagandet, steg för steg

`hex_ateruppta()` gör sakerna i den här ordningen, och ordningen är avsiktlig:

1. **Radtriggers återställs** till lägena från `hex_paus.tidigare_lage` – inte
   "allt på". En trigger som var avstängd redan före pausen förblir avstängd.
2. **`hex_underhall()` körs medan event-triggarna fortfarande är avstängda.**
   Underhållet gör själv `ALTER TABLE` och `CREATE TRIGGER`. Vore
   event-triggarna påslagna skulle varje sådan sats gå genom
   `hex_hantera_ny_kolumn()` och riskera att omstrukturera nyss återlästa
   tabeller.
3. **Event-triggarna slås på sist**, till sina tidigare lägen.
4. **Raden i `hex_paus` tas bort.**

Objekt som försvann under återläsningen hoppas över och rapporteras som
`saknas – hoppas över`. Det är väntat när en återläsning ersatt tabeller;
`hex_underhall()` i steg 2 har redan skapat om triggarna.

### Utan bokföring körs underhållet ändå

Saknas raden i `hex_paus` gör `hex_ateruppta()` **inte** ingenting. Den kör
underhållet och redovisar vad som står avstängt. Skälet är att raden kan ha
försvunnit i just den återläsning den skulle skydda – eller aldrig ha funnits,
för i en tom måldatabas går det inte att pausa innan Hex är installerat.

Det var den tidigare tystnaden som var farlig: efter en `--clean`-återläsning
svarade funktionen "Hex är inte pausat – ingenting att göra", och rollerna,
ägarskapet, rättigheterna och GeoServer-notifieringarna byggdes aldrig upp
igen.

```sql
SELECT * FROM hex_ateruppta(p_underhall => false);  -- hoppa över underhållet
```

Använd `false` bara när pausen inte omgav en återläsning och ingenting behöver
repareras. Utan paus och med `false` är funktionen en ren nullåtgärd.

---

## Efterkontroll

```sql
-- 1. Inga avvikelser. Fångar även en bokföring som en återläsning raderat,
--    via pausmarkören.
SELECT * FROM hex_pausstatus();

-- 2. Alla tio event-triggers påslagna
SELECT evtname, evtenabled FROM pg_event_trigger ORDER BY evtname;

-- 3. Inga avstängda radtriggers kvar i Hex-scheman
SELECT n.nspname, c.relname, t.tgname
FROM   pg_trigger   t
JOIN   pg_class     c ON c.oid = t.tgrelid
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  NOT t.tgisinternal
  AND  n.nspname ~ hex_schema_regex()
  AND  t.tgenabled = 'D';

-- 4. Geometrifunktionernas search_path är låst. Är proconfig NULL kommer
--    nästa återläsning att tömma varje _kba_-tabell med geometri.
SELECT proname, proconfig
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  proname IN ('hex_validera_geometri',
                   'hex_forklara_geometrifel',
                   'hex_kontrollera_geometri_trigger');

-- 5. Ägarskapet på Hex egna funktioner. Noll rader på hex_systemagare()
--    betyder att en --no-owner-återläsning tagit ägarskapet; reparera med
--    install_hex.py --upgrade, inte med hex_ateruppta().
SELECT pg_get_userbyid(proowner) AS agare, count(*)
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND proname LIKE 'hex\_%'
GROUP  BY 1;

-- 6. Exakt radantal per tabell. Kör samma fråga mot källan och jämför.
--    n_live_tup i pg_stat_user_tables duger inte: den är en uppskattning
--    som inte uppdateras förrän ANALYZE körts.
SELECT table_schema, table_name,
       (xpath('/row/c/text()', query_to_xml(
           format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
           false, true, '')))[1]::text::bigint AS rader
FROM   information_schema.tables
WHERE  table_schema ~ hex_schema_regex()
  AND  table_type = 'BASE TABLE'
ORDER  BY 1, 2;
```

Punkt 6 är den viktigaste. Avslutskoden från `pg_restore` säger ingenting om
huruvida datat kom fram, och den vanligaste felvägen ger en tabell som finns,
har rätt struktur och är tom.

En tabell som ligger på **exakt dubbla** källans radantal är det andra utfallet
att leta efter: då lades dumpen till ovanpå befintliga rader i stället för att
ersätta dem. Se *Delvis återläsning*.

---

## Behörigheter

`hex_pausa()` och `hex_ateruppta()` kräver **superanvändare**. `ALTER EVENT
TRIGGER` kräver ägarskap, och enbart superanvändare får äga event-triggers.
Funktionerna är därför medvetet inte `SECURITY DEFINER` – att stänga av Hex ska
inte gå att delegera till ägarrollen (`gis_admin`).

Markören sätts med `ALTER DATABASE ... SET`, vilket kräver ägarskap av
databasen eller superanvändare – samma krav som resten av funktionen redan
ställer.

`hex_pausstatus()` och `hex_pausmarkor()` kräver inga särskilda rättigheter och
är avsedda för övervakning.
