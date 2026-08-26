# 11. Pausa Hex vid pg_dump och pg_restore

Hex reagerar på DDL. En återläsning **är** DDL – tusentals satser i rad. Utan
paus går varje `CREATE TABLE`, `ALTER TABLE` och `DROP SCHEMA` i dumpen genom
Hex tio event-triggers.

Den här guiden beskriver rutinen som IT kan följa.

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

### 2. COPY-steget kan haverera – och pg_restore avslutar ändå med kod 0

Det här är det farliga. pg_restore räknar felen som ignorerade varningar:

```
pg_restore: warning: errors ignored on restore: 10
$ echo $?
0
```

Tabellen finns, den ser rimlig ut i pgAdmin, och den innehåller ingenting av
källdatat. En rutin som kontrollerar avslutskoden ser en lyckad återläsning.

### 3. `--clean` river roller och GeoServer-uppsättning innan något läses in

`pg_restore --clean` börjar med `DROP`-satser mot den **befintliga**
databasen, där Hex är igång. `DROP SCHEMA` utlöser då:

- `hex_ta_bort_schemaroller()` – tar bort schemats fyra roller
  (`r_`, `w_`, `gs_r_`, `gs_w_`).
- `hex_notifiera_gs_borttagning()` – ber GeoServer-lyssnaren radera workspace
  och PostGIS-datastore.

Rollerna finns inte i dumpen (de är kluster-globala) och GeoServer-uppsättningen
finns inte heller där. Båda måste byggas upp igen efteråt.

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

Kolumnen `avvikelse` fångar tre lägen som annars är tysta:

| Läge | Vad det betyder |
| --- | --- |
| Event-triggers påslagna medan `hex_paus` säger pausat | En ominstallation har körts. Filerna i `src/sql/04_triggers/` gör `DROP` + `CREATE EVENT TRIGGER`, och en nyskapad event-trigger är alltid påslagen. Kör `hex_ateruppta()` för att städa bokföringen. |
| Event-triggers avstängda utan att Hex är pausat | Dump tagen under paus, eller ett manuellt `ALTER EVENT TRIGGER`. |
| `pausad_till` har passerat | Någon glömde återuppta. |

`install_hex.py` varnar också vid installation mot en pausad databas.

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

```sql
SELECT * FROM hex_ateruppta(p_underhall => false);  -- hoppa över underhållet
```

Använd `false` bara när pausen inte omgav en återläsning och ingenting behöver
repareras.

---

## Efterkontroll

```sql
-- 1. Inga avvikelser
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

`hex_pausstatus()` kräver inga särskilda rättigheter och är avsedd för
övervakning.
