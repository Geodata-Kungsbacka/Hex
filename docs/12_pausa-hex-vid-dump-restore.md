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
tre olika lägen:

| Återläsningens form | Är Hex igång under körningen? | Paus |
| --- | --- | --- |
| Full dump till en **tom** måldatabas | Nej. Event-triggarna finns inte förrän på slutet, och skapas då påslagna. | Behövs inte |
| Full dump med `--clean` till en Hex-databas | Nej. `--clean` droppar event-triggarna först av allt och skapar om dem sist. | Behövs inte för DDL-vågen – men läs varningen nedan |
| **Delvis** återläsning till en levande Hex-databas (`-n <schema>`, `--data-only`, enstaka tabeller) | **Ja.** Dumpen rör aldrig event-triggarna, så de står påslagna hela tiden. | **Krävs** |
| Dump från en **icke-Hex**-databas till en Hex-databas | **Ja.** Samma skäl. | **Krävs** |

Skillnaden är stor. En `pg_restore -n sk0_kba_vagar` mot en levande Hex-databas
ger i storleksordningen tio fel av typen `relation "vagar_l_h" already exists`;
samma återläsning med pausen på ger noll. En full återläsning till en tom
databas ger noll fel även utan paus.

> **Men efterarbetet behövs alltid.** Rollerna är kluster-globala och ligger
> inte i dumpen, ägarskapet försvinner med `--no-owner`, och GeoServer vet
> ingenting om den nya databasen. Kör därför alltid `hex_ateruppta()` efteråt,
> också när ingen paus togs – den kör `hex_underhall()`, som är reparationen.
> Se *Återupptagandet* nedan.

---

## Kortversionen

```sql
-- 1. I MÅLDATABASEN, som superanvändare
SELECT * FROM hex_pausa('pg_restore av prod till test, ärende 12345', 8);
```

```bash
# 2. Dump och återläsning
pg_dump  -Fc -f prod.dump prod_db
pg_restore -d test_db --no-owner --no-privileges prod.dump
```

```sql
-- 3. Tillbaka i måldatabasen
SELECT * FROM hex_ateruppta();

-- 4. Kontrollera
SELECT * FROM hex_pausstatus();
```

`hex_ateruppta()` kör `hex_underhall()` som del av steg 3. Det är där rollerna,
rättigheterna, ägarskapet och GeoServer-notifieringarna kommer tillbaka.

**Hoppa aldrig över steg 3, inte ens när steg 1 aldrig kördes.** Underhållet
körs även när databasen inte är pausad – reparationen behövs oavsett hur
dumpen lästes in, och pausen kan dessutom ha raderats av själva återläsningen
(se *Dumpen bär med sig pausen*).

---

## Varför pausen behövs

Det räcker inte att säga att det blir "mycket brus i loggen". Utan paus går
återläsningen fel på fyra sätt, och tre av dem är tysta.

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
  om inte `ON_ERROR_STOP` är satt. Då finns ingen avslutskod att gå på alls.
- Utan paus är felen tio- eller hundratals `already exists` från steg 1, och
  ett verkligt `COPY`-fel drunknar i mängden. Tabellen finns, ser rimlig ut i
  pgAdmin, och saknar rader.

Därför är radantalskontrollen i *Efterkontroll* det som faktiskt svarar på om
datat kom fram. Avslutskoden räcker inte.

### 3. `DROP SCHEMA` river roller och GeoServer-uppsättning

`DROP SCHEMA` mot en databas där Hex är igång utlöser:

- `hex_ta_bort_schemaroller()` – tar bort schemats fyra roller
  (`r_`, `w_`, `gs_r_`, `gs_w_`).
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
  hand.
- **Främmande nycklar.** Interna triggar lämnas påslagna med flit – en paus ska
  inte kunna smuggla in referensbrott.
- **Roller.** De är kluster-globala och ligger inte i en `pg_dump`. Se nedan.

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
- sätter ägarskap på scheman, tabeller, sekvenser och funktioner,
- delar ut schemarättigheter,
- kopplar tillbaka radtriggers som saknas,
- skickar `pg_notify('geoserver_schema', ...)` för varje publicerat schema.

Alternativet är att ta med rollerna själv:

```bash
pg_dumpall --globals-only --roles-only > roller.sql
```

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

-- 4. Radantal mot källan, per tabell
SELECT schemaname, relname, n_live_tup
FROM   pg_stat_user_tables
WHERE  schemaname ~ hex_schema_regex()
ORDER  BY schemaname, relname;
```

Punkt 4 är den viktigaste. Avslutskoden från `pg_restore` säger ingenting om
huruvida datat kom fram.

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
