# PostgreSQL Automatisk Tabellstrukturering med PostGIS

## Översikt

Detta system automatiserar databasstrukturering i PostgreSQL med PostGIS-stöd. När du skapar en ny tabell läggs automatiskt standardkolumner till (som primärnyckel, tidsstämplar och användarspårning), geometrikolumner placeras alltid sist, och tabellnamn valideras enligt en strikt namngivningsstandard. Systemet skapar även automatiskt säkerhetsroller för varje schema och kan generera historiktabeller för ändringsloggning. Huvudsyftet är att säkerställa konsekvent databasstruktur utan manuellt arbete, vilket minskar fel och ökar produktiviteten i geodatabashantering.

## Huvudfunktionalitet

### 1. **Automatisk tabellstrukturering**
När du skapar en tabell med `CREATE TABLE` omstruktureras den automatiskt med:
- Standardkolumner som `gid` (primärnyckel), `skapad_tidpunkt`, `skapad_av`, `andrad_tidpunkt`, `andrad_av`
- Korrekt kolumnordning (standardkolumner först/sist, geometri alltid sist)
- Bevarande av alla ursprungliga tabellregler och begränsningar

### 2. **Namngivningsvalidering**

#### Schemanamn
Schemanamn måste följa mönstret `sk[0-2]_(ext|kba|sys)_*`:
- `sk0`, `sk1`, `sk2` = Säkerhetsnivå (0=öppen, 1=kommun, 2=begränsad)
- `ext` = Externa datakällor
- `kba` = Interna kommunala datakällor
- `sys` = Systemdata

Exempel på giltiga schemanamn:
- `sk0_ext_sgu`
- `sk1_kba_bygg`
- `sk2_sys_admin`

#### Tabellnamn
Systemet kräver specifika suffix baserat på geometrityp:
- `_p` för punktgeometrier (POINT, MULTIPOINT)
- `_l` för linjegeometrier (LINESTRING, MULTILINESTRING)
- `_y` för ytgeometrier (POLYGON, MULTIPOLYGON)
- `_g` för generiska eller blandade geometrier
- Tabeller utan geometri får inte använda dessa suffix

### 3. **Automatisk rollhantering**
För varje nytt schema skapas automatiskt:
- `r_schemanamn` - roll med läsrättigheter
- `w_schemanamn` - roll med läs- och skrivrättigheter

### 4. **Historik och kvalitetssäkring**
För scheman konfigurerade med QA-kolumner skapas:
- Historiktabeller (`tabellnamn_h`) som loggar alla ändringar
- Triggers som automatiskt uppdaterar `andrad_tidpunkt` och `andrad_av`

## Installation

```sql
-- Kör skripten i följande ordning:
-- 1. Alla filer i /01_types/
-- 2. Alla filer i /02_tables/
-- 3. Alla filer i /03_functions/ (i underkatalogers nummerordning)
-- 4. Alla filer i /04_triggers/

Alternativt kör "install_praxis.py" och mata in databas detaljer.
    kan köras som:
        python install_praxis.py 
        python install_praxis.py --uninstall
    för att installera eller ta bort.
```

### Detaljerad installationsordning

```sql
-- 1. Skapa anpassade datatyper
src/sql/01_types/geom_info.sql
src/sql/01_types/kolumnegenskaper.sql
src/sql/01_types/kolumnkonfig.sql
src/sql/01_types/tabellregler.sql

-- 2. Skapa konfigurationstabell
src/sql/02_tables/standardiserade_kolumner.sql
src/sql/02_tables/standardiserade_roller.sql

-- 3. Skapa funktioner (i beroendeordning)
-- 3.1 Strukturhantering
src/sql/03_functions/01_structure/hamta_geometri_definition.sql
src/sql/03_functions/01_structure/hamta_kolumnstandard.sql

-- 3.2 Validering
src/sql/03_functions/02_validation/validera_tabell.sql
src/sql/03_functions/02_validation/validera_vynamn.sql
src/sql/03_functions/02_validation/validera_schemanamn.sql

-- 3.3 Regelhantering
src/sql/03_functions/03_rules/spara_tabellregler.sql
src/sql/03_functions/03_rules/spara_kolumnegenskaper.sql
src/sql/03_functions/03_rules/aterskapa_tabellregler.sql
src/sql/03_functions/03_rules/aterskapa_kolumnegenskaper.sql

-- 3.4 Hjälpfunktioner
src/sql/03_functions/04_utility/byt_ut_tabell.sql
src/sql/03_functions/04_utility/uppdatera_sekvensnamn.sql
src/sql/03_functions/04_utility/skapa_historik_qa.sql
src/sql/03_functions/04_utility/tilldela_rollrattigheter.sql

-- 3.5 Triggerfunktioner
src/sql/03_functions/05_trigger_functions/hantera_ny_tabell.sql
src/sql/03_functions/05_trigger_functions/hantera_kolumntillagg.sql
src/sql/03_functions/05_trigger_functions/hantera_ny_vy.sql
src/sql/03_functions/05_trigger_functions/skapa_ny_schemaroll_r.sql
src/sql/03_functions/05_trigger_functions/skapa_ny_schemaroll_w.sql
src/sql/03_functions/05_trigger_functions/ta_bort_schemaroller.sql
src/sql/03_functions/05_trigger_functions/hantera_standardiserade_roller.sql

-- 4. Skapa databastriggers
src/sql/04_triggers/hantera_ny_tabell_trigger.sql
src/sql/04_triggers/hantera_kolumntillagg_trigger.sql
src/sql/04_triggers/hantera_ny_vy_trigger.sql
src/sql/04_triggers/ta_bort_schemaroller_trigger.sql
src/sql/04_triggers/hantera_standardiserade_roller_trigger.sql
src/sql/04_triggers/validera_schemanamn_trigger.sql
```

## Detaljerad funktionsbeskrivning

### Datatyper (Custom Types)

#### `geom_info`
**Syfte**: Lagrar strukturerad information om en geometrikolumn.

**Användning**: Används internt av valideringsfunktioner för att analysera och validera geometrikolumner. Innehåller fält som geometrityp, SRID, dimensioner och en komplett geometridefinition.

**Exempel**: När systemet hittar en geometrikolumn analyseras den och informationen sparas i denna typ för vidare bearbetning.

#### `kolumnegenskaper`
**Syfte**: Bevarar kolumnspecifika egenskaper vid tabellomstrukturering.

**Användning**: När en tabell ska omstruktureras sparas först alla DEFAULT-värden, NOT NULL-begränsningar, CHECK-begränsningar och IDENTITY-definitioner i denna typ så de kan återskapas efteråt.

**Praktisk nytta**: Säkerställer att inga kolumnegenskaper förloras när tabeller omstruktureras automatiskt.

#### `kolumnkonfig`
**Syfte**: Definierar en kolumns struktur med namn, position och datatyp.

**Användning**: Används för att bygga upp den slutliga tabellstrukturen genom att kombinera standardkolumner med användardefinierade kolumner.

**Exempel**: `(gid, 1, 'integer GENERATED ALWAYS AS IDENTITY')` definierar primärnyckeln.

#### `tabellregler`
**Syfte**: Bevarar tabellövergripande regler vid omstrukturering.

**Användning**: Sparar index, främmande nycklar och constraints innan en tabell omstruktureras, så de kan återskapas exakt som de var.

**Praktisk nytta**: Förhindrar att viktiga databaskopplingar och prestandaindex förloras.

### Konfigurationstabell

#### `standardiserade_kolumner`
**Syfte**: Central konfiguration för vilka standardkolumner som ska läggas till tabeller.

**Användning**: Administratörer kan här definiera vilka kolumner som automatiskt ska läggas till nya tabeller, deras position (först/sist), datatyp och standardvärden.

**Kraftfull funktion - schema_uttryck**: Genom att ange SQL-uttryck kan du styra vilka scheman som får specifika kolumner. Exempel:
- `LIKE '%_kba_%'` - endast interna datakällor får dessa kolumner
- `= 'sk0_ext_sgu'` - endast detta specifika schema
- `IS NOT NULL` - alla scheman (standard)

**Historik_qa-flaggan**: Styr om kolumnen ska uppdateras via trigger (true) eller DEFAULT-värde (false).

### Strukturhanteringsfunktioner

#### `hamta_geometri_definition(schema, tabell)`
**Syfte**: Analyserar en tabells geometrikolumn och returnerar fullständig information.

**Användning**: Anropas automatiskt när systemet behöver förstå vilken typ av geometri en tabell innehåller. Validerar att det finns exakt en geometrikolumn som heter 'geom'.

**Returvärde**: En `geom_info`-struktur med komplett geometriinformation inklusive typ, SRID och dimensioner.

**Felhantering**: Ger tydliga felmeddelanden om tabellen har flera geometrikolumner eller om kolumnen har fel namn.

#### `hamta_kolumnstandard(schema, tabell, geometriinfo)`
**Syfte**: Bestämmer exakt vilka kolumner en tabell ska ha efter omstrukturering.

**Användning**: Kombinerar tre källor:
1. Standardkolumner från `standardiserade_kolumner` (filtrerade per schema)
2. Användarens ursprungliga kolumner från CREATE TABLE
3. Geometrikolumn (om sådan finns)

**Intelligent schemafiltrering**: Använder `schema_uttryck` för att avgöra vilka standardkolumner som passar för schemat.

**Returvärde**: Array med `kolumnkonfig`-objekt i rätt ordning för den nya tabellstrukturen.

### Valideringsfunktioner

#### `validera_schemanamn()`
**Syfte**: Säkerställer att schemanamn följer Praxis namngivningskonvention.

**Mönster**: `sk[0-2]_(ext|kba|sys)_*`

**Validering omfattar**:
- Kontroll av säkerhetsnivå (sk0, sk1, sk2)
- Kontroll av kategori (ext, kba, sys)
- Krav på beskrivande suffix efter kategori

**Undantag**: Systemscheman (`public`, `information_schema`, `pg_*`) valideras inte.

**Trigger**: Körs vid CREATE SCHEMA - blockerar skapande av scheman med ogiltiga namn.

#### `validera_tabell(schema, tabell)`
**Syfte**: Säkerställer att tabeller följer namngivningsstandarden.

**Validering omfattar**:
- Kontroll av geometrisuffix (_p, _l, _y, _g)
- Verifiering att endast en geometrikolumn finns
- Kontroll att geometrikolumnen heter 'geom'

**Returvärde**: Geometriinformation om tabellen har geometri, annars NULL.

**Praktisk nytta**: Förhindrar förvirrande tabellnamn och säkerställer konsekvent namngivning i hela databasen.

#### `validera_vynamn(schema, vy)`
**Syfte**: Validerar att vyer följer namngivningsstandarden.

**Krav på vynamn**:
- Måste börja med `v_`
- Suffix baserat på geometriinnehåll (samma som tabeller)
- Vid geometritransformationer krävs explicit typkonvertering

**Exempel på korrekt vy**: `v_ledningar_p` för en vy med punktgeometrier.

### Regelhanteringsfunktioner

#### `spara_tabellregler(schema, tabell)`
**Syfte**: Bevarar alla tabellövergripande regler innan omstrukturering.

**Sparar**:
- Index (förutom PRIMARY KEY och UNIQUE constraints)
- Främmande nycklar
- Constraints (PRIMARY KEY, UNIQUE, multi-kolumn CHECK)

**Returvärde**: `tabellregler`-objekt med alla regler.

**Användning**: Anropas automatiskt innan en tabell omstruktureras för att inte förlora viktiga databaskopplingar.

#### `spara_kolumnegenskaper(schema, tabell)`
**Syfte**: Bevarar kolumnspecifika egenskaper innan omstrukturering.

**Sparar**:
- DEFAULT-värden
- NOT NULL-begränsningar
- Kolumnspecifika CHECK-begränsningar
- IDENTITY-definitioner

**Returvärde**: `kolumnegenskaper`-objekt med alla egenskaper.

**Separation från tabellregler**: Håller tydlig skillnad mellan tabellövergripande regler och kolumnspecifika egenskaper.

#### `aterskapa_tabellregler(schema, tabell, regler)`
**Syfte**: Återställer alla tabellregler efter omstrukturering.

**Återskapar i ordning**:
1. Index (behövs ofta av constraints)
2. Constraints (PRIMARY KEY, UNIQUE, CHECK)
3. Främmande nycklar (sist för att undvika cirkelreferenser)

**Felhantering**: Detaljerad loggning av varje SQL-sats för enkel felsökning.

#### `aterskapa_kolumnegenskaper(schema, tabell, egenskaper)`
**Syfte**: Återställer kolumnegenskaper efter omstrukturering.

**Återskapar**:
1. NOT NULL-begränsningar
2. CHECK-begränsningar
3. DEFAULT-värden (hoppar över standardkolumner)
4. IDENTITY-definitioner

**Intelligent hantering**: Hoppar över standardkolumner som redan har rätt DEFAULT-värden.

### Hjälpfunktioner

#### `byt_ut_tabell(schema, tabell, temp_tabell)`
**Syfte**: Atomisk tabellersättning utan dataförlust.

**Process**:
1. Tar bort ursprungstabellen (CASCADE för beroenden)
2. Döper om temporär tabell till originalnamnet

**Användning**: Kritisk del av omstruktureringsprocessen för att byta ut gamla tabeller mot nya.

#### `uppdatera_sekvensnamn(schema, tabell)`
**Syfte**: Korrigerar IDENTITY-sekvensnamn efter tabellbyte.

**Problem som löses**: När IDENTITY-kolumner skapas i temporära tabeller får sekvenserna temporära namn som måste korrigeras.

**Returvärde**: Antal omdöpta sekvenser.

#### `skapa_historik_qa(schema, tabell)`
**Syfte**: Skapar komplett historikhantering för kvalitetssäkring.

**Skapar**:
1. Historiktabell med prefix `h_` och alla originalkolumner
2. Triggerfunktion som loggar UPDATE och DELETE
3. Trigger som automatiskt uppdaterar QA-kolumner
4. Index för snabb sökning på gid och tidpunkt

**Returvärde**: true om historik skapades, false om inte behövs.

**Praktisk användning**: Möjliggör fullständig spårbarhet av alla dataändringar.

### Triggerfunktioner

#### `hantera_ny_tabell()`
**Syfte**: Huvudfunktion som omstrukturerar nyskapade tabeller.

**Process (8 steg)**:
1. Validerar tabellnamn och geometri
2. Sparar befintliga regler och egenskaper
3. Bestämmer ny kolumnstruktur
4. Skapar temporär tabell med ny struktur
5. Byter ut tabellerna
6. Återskapar alla regler
7. Återskapar alla egenskaper
8. Skapar historik/QA om konfigurerat

**Trigger**: Körs automatiskt vid CREATE TABLE.

**Undantag**: Hoppar över public-schema och historiktabeller.

#### `hantera_kolumntillagg()`
**Syfte**: Omorganiserar kolumner när nya läggs till.

**Problem som löses**: När ALTER TABLE ADD COLUMN körs hamnar nya kolumner sist, vilket bryter standardstrukturen.

**Process**:
1. Flyttar standardkolumner med negativ position till slutet
2. Flyttar geometrikolumn allra sist

**Trigger**: Körs vid ALTER TABLE.

**Rekursionsskydd**: Använder flagga för att undvika oändliga loopar.

#### `hantera_ny_vy()`
**Syfte**: Validerar att nyskapade vyer följer namnstandarden.

**Validering**: Kontrollerar prefix (v_) och suffix baserat på geometriinnehåll.

**Trigger**: Körs vid CREATE VIEW.

**Felmeddelanden**: Ger tydliga instruktioner om korrekt namngivning.

#### `validera_schemanamn()`
**Syfte**: Validerar att nya scheman följer namngivningskonventionen.

**Validering**: Kontrollerar att schemanamn matchar mönstret `sk[0-2]_(ext|kba|sys)_*`.

**Trigger**: Körs vid CREATE SCHEMA - blockerar ogiltiga schemanamn.

**Undantag**: Systemscheman (public, information_schema, pg_*) valideras inte.

#### `skapa_ny_schemaroll_r()` och `skapa_ny_schemaroll_w()`
**Syfte**: Automatiserar säkerhetshantering genom att skapa roller för nya scheman.

**r_-roll (read)**:
- SELECT på alla tabeller, vyer och sekvenser
- USAGE på schemat

**w_-roll (write)**:
- ALL PRIVILEGES på tabeller och vyer
- EXECUTE på funktioner och procedurer
- Fullständiga rättigheter

**Trigger**: Körs vid CREATE SCHEMA.

#### `ta_bort_schemaroller()`
**Syfte**: Städar upp oanvända roller när scheman tas bort.

**Process**: Identifierar borttagna scheman och tar bort motsvarande r_ och w_ roller.

**Trigger**: Körs vid DROP SCHEMA.

**Nytta**: Håller databasen ren från oanvända säkerhetsobjekt.

## Exempel på användning

### Skapa schema med korrekt namngivning

```sql
-- Korrekt namngivning - fungerar
CREATE SCHEMA sk0_ext_sgu;      -- Öppen data från SGU
CREATE SCHEMA sk1_kba_bygg;     -- Kommunal byggdata
CREATE SCHEMA sk2_sys_admin;    -- Känslig systemdata

-- Felaktig namngivning - blockeras av validering
CREATE SCHEMA min_data;         -- FEL: Följer inte mönstret
CREATE SCHEMA sk3_ext_test;     -- FEL: sk3 finns inte
CREATE SCHEMA sk0_foo_bar;      -- FEL: "foo" är inte ext/kba/sys
```

### Grundläggande tabellskapande

```sql
-- Skapa en tabell - systemet lägger automatiskt till standardkolumner
CREATE TABLE sk1_kba_bygg.vattenledningar_l (
    diameter integer,
    material text,
    geom geometry(LineString, 3007)
);

-- Resultatet blir automatiskt:
-- gid (primärnyckel)
-- diameter
-- material  
-- skapad_tidpunkt
-- skapad_av
-- andrad_tidpunkt
-- andrad_av
-- geom (flyttad sist)
```

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
INSERT INTO standardiserade_kolumner(
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
INSERT INTO standardiserade_kolumner(
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
**Lösning**: Kontrollera att schemanamnet följer mönstret `sk[0-2]_(ext|kba|sys)_*`

**Problem**: Tabell skapas inte med standardkolumner  
**Lösning**: Kontrollera att alla triggers är aktiverade och att schemat inte är 'public'

**Problem**: Geometrikolumn hamnar inte sist  
**Lösning**: Verifiera att geometrikolumnen heter exakt 'geom'

**Problem**: Fel vid omstrukturering  
**Lösning**: Kontrollera loggmeddelanden för detaljerad felinformation

**Problem**: Historiktabell skapas inte  
**Lösning**: Verifiera att minst en kolumn har `historik_qa = true` i `standardiserade_kolumner`

### Kontrollera systemstatus

```sql
-- Lista alla event triggers
SELECT evtname, evtevent, evtenabled 
FROM pg_event_trigger 
ORDER BY evtname;

-- Kontrollera standardkolumner för ett schema
SELECT * FROM standardiserade_kolumner
WHERE 'sk1_kba_bygg' LIKE schema_uttryck
ORDER BY ordinal_position;

-- Verifiera att funktioner finns
SELECT proname 
FROM pg_proc 
WHERE proname LIKE 'hantera_%' 
   OR proname LIKE 'validera_%'
ORDER BY proname;
```

## Avinstallation

Om du behöver ta bort systemet:

```sql
-- 1. Ta bort triggers
DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger CASCADE;
DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger CASCADE;
DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger CASCADE;
DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger CASCADE;
DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger CASCADE;
DROP EVENT TRIGGER IF EXISTS ta_bort_schemaroller_trigger CASCADE;

-- 2. Ta bort funktioner (i omvänd beroendeordning)
-- [Lista alla DROP FUNCTION-satser här]

-- 3. Ta bort konfigurationstabell
DROP TABLE IF EXISTS standardiserade_kolumner CASCADE;
DROP TABLE IF EXISTS standardiserade_roller CASCADE;

-- 4. Ta bort anpassade typer
DROP TYPE IF EXISTS tabellregler CASCADE;
DROP TYPE IF EXISTS kolumnkonfig CASCADE;
DROP TYPE IF EXISTS kolumnegenskaper CASCADE;
DROP TYPE IF EXISTS geom_info CASCADE;
```

## Licens

MIT License - Se LICENSE-filen för detaljer

## Bidrag

Bidrag välkomnas! Skapa en issue eller pull request på GitHub.

## Support

För frågor och support, kontakta databasadministratören eller skapa en issue i projektets GitHub-repository.
