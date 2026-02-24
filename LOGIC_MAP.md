# Hex — Systemlogik och funktionsflöden

> Presentationsunderlag. Alla DDL-händelser visas från inträde till utfall,
> med fullständiga funktionskedjor och rekursionsskydd.

---

## Innehåll

1. [Konfigurationstabeller (systemets "regler")](#1-konfigurationstabeller)
2. [CREATE SCHEMA](#2-create-schema)
3. [CREATE TABLE](#3-create-table)
4. [ALTER TABLE — ADD COLUMN](#4-alter-table--add-column)
5. [ALTER TABLE — RENAME TO](#5-alter-table--rename-to)
6. [CREATE VIEW](#6-create-view)
7. [DROP TABLE](#7-drop-table)
8. [DROP SCHEMA](#8-drop-schema)
9. [Externt system: GeoServer-lyssnaren (Python)](#9-externt-system-geoserver-lyssnaren)
10. [Rekursionsskydd](#10-rekursionsskydd)
11. [Snabbreferens: alla funktioner](#11-snabbreferens-alla-funktioner)

---

## 1. Konfigurationstabeller

Systemets beteende styrs av data, inte hårdkodad logik.
Inga kodredigeringar behövs för att lägga till kolumner, roller eller ändra regler.

### `standardiserade_kolumner`
Definierar vilka kolumner som automatiskt injiceras i alla tabeller.

| Kolumn | Syfte |
|---|---|
| `kolumnnamn` | Namn på kolumnen som injiceras |
| `ordinal_position` | Positiv = hamnar först, negativ = hamnar sist, 0 = ogiltigt |
| `datatyp` | PostgreSQL-datatyp |
| `default_varde` | DEFAULT-uttryck (t.ex. `NOW()`, `session_user`) |
| `schema_uttryck` | SQL-filter — kolumnen injiceras bara om schemanamnet matchar (t.ex. `LIKE '%_kba_%'`) |
| `historik_qa` | `true` = värdet sätts av QA-triggern vid UPDATE/DELETE, inte av DEFAULT |

**Fördefinierade standardkolumner:**

| Kolumn | Position | Default | schema_uttryck | historik_qa |
|---|---|---|---|---|
| `gid` | 1 (först) | GENERATED ALWAYS AS IDENTITY | IS NOT NULL (alla) | false |
| `skapad_tidpunkt` | -4 (näst sist) | NOW() | IS NOT NULL (alla) | false |
| `skapad_av` | -3 | session_user | LIKE '%\_kba\_%' | false |
| `andrad_tidpunkt` | -2 | NOW() | LIKE '%\_kba\_%' | **true** |
| `andrad_av` | -1 (sist, före geom) | session_user | LIKE '%\_kba\_%' | **true** |

---

### `standardiserade_roller`
Definierar vilka roller som automatiskt skapas för nya scheman.

| Kolumn | Syfte |
|---|---|
| `rollnamn` | Rollnamnsmall, `{schema}` ersätts med schemanamn |
| `rolltyp` | `read` eller `write` |
| `schema_uttryck` | SQL-filter — rollen skapas bara om schemanamnet matchar |
| `global_roll` | `true` = rollen är global och tas **inte** bort med schemat |
| `ta_bort_med_schema` | `false` för globala roller |
| `login_roller` | Array med suffix/prefix för LOGIN-roller (t.ex. `['_geoserver', '_qgis']`) |

**Fördefinierade roller:**

| Rollnamn | Typ | Matchar | Global | LOGIN-varianter |
|---|---|---|---|---|
| `r_sk0_global` | read | `LIKE 'sk0_%'` | ja | `r_sk0_global_geoserver`, `r_sk0_global_qgis` |
| `r_sk1_global` | read | `LIKE 'sk1_%'` | ja | `r_sk1_global_geoserver`, `r_sk1_global_qgis` |
| `r_{schema}` | read | `LIKE 'sk2_%'` | nej | `r_{schema}_geoserver`, `r_{schema}_qgis` |
| `w_{schema}` | write | IS NOT NULL (alla) | nej | `w_{schema}_geoserver`, `w_{schema}_qgis` |

---

### `hex_metadata`
Kopplar tabell-OID till historiktabell och QA-triggerfunktion.

| Kolumn | Syfte |
|---|---|
| `parent_oid` | OID från pg_class — stabil vid RENAME TO |
| `parent_schema` / `parent_table` | Aktuella namn (uppdateras vid rename) |
| `history_table` | Namn på historiktabellen (kan vara trunkerat till 63 byte) |
| `trigger_funktion` | Namn på QA-triggerfunktionen |

> **Varför OID?** PostgreSQL trunkerar identifierare till 63 byte.
> Om historiktabellen heter `lång_tabell_h` och originalet döps om,
> hittar vi den ändå via OID — ett namnbaserat uppslag hade gett fel resultat.

---

## 2. CREATE SCHEMA

```
CREATE SCHEMA sk0_kba_bygg
```

Tre eventutlösare körs i ordning vid `DDL_COMMAND_END`:

---

### Steg 1 — `validera_schemanamn_trigger` → `validera_schemanamn()`

**Syfte:** Blockera ogiltiga schemanamn innan något annat händer.

```
validera_schemanamn()
  ├── Hoppar över: public, information_schema, pg_*
  ├── Kontrollerar mönster: ^sk[012]_(ext|kba|sys)_.+$
  │     sk0 / sk1 / sk2  = säkerhetsnivå (0=öppen, 1=kommunal, 2=skyddad)
  │     ext              = extern datakälla (bulkladdad, t.ex. via FME)
  │     kba              = kommunens egna data (manuellt redigerat)
  │     sys              = systemdata
  │     .+               = beskrivande namn
  └── Ogiltigt namn → EXCEPTION → transaktion rullas tillbaka
```

---

### Steg 2 — `hantera_standardiserade_roller_trigger` → `hantera_standardiserade_roller()`

**Syfte:** Skapa rollstruktur automatiskt baserat på `standardiserade_roller`.
**Kör som:** SECURITY DEFINER (postgres) — krävs för att skapa roller.

```
hantera_standardiserade_roller()
  ├── Hoppar över systemscheman
  ├── För varje rad i standardiserade_roller:
  │     ├── Evaluerar schema_uttryck mot schemanamnet
  │     │     Exempel: 'LIKE ''sk0_%''' → matchar sk0_kba_bygg, inte sk2_kba_mark
  │     └── Om matchar:
  │           ├── Skapar NOLOGIN-grupprollen (t.ex. r_sk0_global, w_sk0_kba_bygg)
  │           │     CREATE ROLE <rollnamn> WITH NOLOGIN
  │           │     GRANT <rollnamn> TO system_owner() WITH ADMIN OPTION
  │           │
  │           ├── → tilldela_rollrattigheter(schema, roll, typ)
  │           │       ├── GRANT USAGE ON SCHEMA (alla rolltyper)
  │           │       ├── read:  GRANT SELECT ON ALL TABLES
  │           │       │          ALTER DEFAULT PRIVILEGES … GRANT SELECT
  │           │       └── write: GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES
  │           │                  ALTER DEFAULT PRIVILEGES … GRANT SELECT, INSERT, UPDATE, DELETE
  │           │     (DEFAULT PRIVILEGES säkerställer att framtida tabeller
  │           │      också får rätt behörigheter automatiskt)
  │           │
  │           └── För varje post i login_roller-arrayen (t.ex. ['_geoserver', '_qgis']):
  │                 ├── Suffix (_geoserver) → r_sk0_global_geoserver
  │                 ├── Prefix (geoserver_) → geoserver_r_sk0_global
  │                 ├── CREATE ROLE <loginrollnamn> WITH LOGIN
  │                 └── GRANT <grupprolle> TO <loginroll>  (ärver behörigheter)
  │
  └── Resultat för sk0_kba_bygg:
        NOLOGIN: r_sk0_global, w_sk0_kba_bygg
        LOGIN:   r_sk0_global_geoserver, r_sk0_global_qgis,
                 w_sk0_kba_bygg_geoserver, w_sk0_kba_bygg_qgis
```

---

### Steg 3 — `notifiera_geoserver_trigger` → `notifiera_geoserver()`

**Syfte:** Signalera till den externa GeoServer-lyssnaren att skapa workspace och datakälla.

```
notifiera_geoserver()
  ├── Hoppar över systemscheman
  ├── Extraherar prefix: sk0 eller sk1
  │     (sk2 exponeras inte mot GeoServer)
  ├── Om prefix = sk0 eller sk1:
  │     pg_notify('geoserver_schema', 'sk0_kba_bygg')
  └── Icke-kritisk: om GeoServer inte nås rullas inte schemat tillbaka
        → se avsnitt 9 för vad som händer i Python-lyssnaren
```

---

## 3. CREATE TABLE

```sql
CREATE TABLE sk0_kba_bygg.byggnader_y (
    beteckning text,
    geom       geometry(Polygon, 3007)
);
```

En eventutlösare körs vid `DDL_COMMAND_END`:

`hantera_ny_tabell_trigger` → `hantera_ny_tabell()`

```
hantera_ny_tabell()
  ├── Rekursionsskydd: avbryt om temp.tabellstrukturering_pagar = true
  ├── Hoppar över: public-schema, tabeller som slutar på _h
  │     (om en tabell slutar på _h utan förälder → EXCEPTION)
  │
  ├── [1] VALIDERA TABELL
  │     → validera_tabell(schema, tabell)
  │           ├── Utan geometri: tabell får INTE sluta på _p/_l/_y/_g
  │           ├── Med geometri:
  │           │     ├── Exakt 1 geometrikolumn måste finnas
  │           │     ├── Kolumnen MÅSTE heta 'geom'
  │           │     ├── Suffix måste matcha geometritypen:
  │           │     │     _p = POINT/MULTIPOINT
  │           │     │     _l = LINESTRING/MULTILINESTRING
  │           │     │     _y = POLYGON/MULTIPOLYGON
  │           │     │     _g = övriga typer
  │           │     └── → hamta_geometri_definition(schema, tabell)
  │           │               ├── Hämtar typ, SRID, dimensioner från geometry_columns
  │           │               ├── Beräknar suffix: Z / M / ZM / (inget)
  │           │               ├── Bygger definition: geometry(PolygonZ, 3007)
  │           │               └── Returnerar geom_info-struct
  │           └── Validering misslyckad → EXCEPTION → rollback
  │
  ├── [2] SPARA TABELLREGLER (innan tabellen rivs)
  │     → spara_tabellregler(schema, tabell)
  │           ├── Indexdefinitioner (ej PK, ej UNIQUE)  → CREATE INDEX …
  │           ├── Främmande nycklar                     → conname;definition
  │           └── PK, UNIQUE, multi-kolumn-CHECK        → conname;definition
  │           Returnerar: tabellregler-struct
  │
  ├── [3] SPARA KOLUMNEGENSKAPER (innan tabellen rivs)
  │     → spara_kolumnegenskaper(schema, tabell)
  │           ├── DEFAULT-värden per kolumn             → colname;uttryck
  │           ├── NOT NULL-flaggor                      → kolumnnamn
  │           ├── Enkla CHECK-villkor (1 kolumn)        → conname;colname;definition
  │           └── IDENTITY-definitioner                 → colname;GENERATED ALWAYS …
  │           Returnerar: kolumnegenskaper-struct
  │
  ├── [4] BYGG SLUTLIG KOLUMNLISTA
  │     → hamta_kolumnstandard(schema, tabell, geom_info)
  │           ├── Evaluerar schema_uttryck för varje rad i standardiserade_kolumner
  │           │     Exempel för sk0_kba_bygg:
  │           │       gid          → 'IS NOT NULL' → matchar → inkluderas
  │           │       skapad_av    → 'LIKE '%_kba_%'' → matchar → inkluderas
  │           │       andrad_tidpunkt → matchar → inkluderas (historik_qa=true → ingen DEFAULT)
  │           │       andrad_av    → matchar → inkluderas (historik_qa=true → ingen DEFAULT)
  │           ├── Sammanfogar i ordning:
  │           │     1. Standardkolumner med positiv ordinal_position  (gid)
  │           │     2. Användarens egna kolumner                      (beteckning)
  │           │     3. Standardkolumner med negativ ordinal_position  (skapad_av, andrad_tidpunkt, andrad_av)
  │           │     4. Geometrikolumnen                               (geom)
  │           └── Returnerar: array av kolumnkonfig-struct i slutlig ordning
  │
  ├── [5] BYT UT TABELL
  │     Sätter: temp.tabellstrukturering_pagar = true
  │     → byt_ut_tabell(schema, tabell, temp_tabell)
  │           ├── DROP TABLE original CASCADE
  │           │     (tar bort beroenden: index, constraints, triggers)
  │           └── ALTER TABLE temp_tabell RENAME TO original
  │
  ├── [6] UPPDATERA SEKVENSNAMN
  │     → uppdatera_sekvensnamn(schema, tabell)
  │           ├── Letar sekvenser som ägs av tabellen och innehåller '_temp_0001_'
  │           └── Döper om: tar bort '_temp_0001_'-delen från sekvensnamnet
  │
  ├── [7] ÅTERSKAPA TABELLREGLER
  │     → aterskapa_tabellregler(schema, tabell, regler)
  │           ├── 1. CREATE INDEX (index)
  │           ├── 2. ADD CONSTRAINT (PK, UNIQUE, multi-kolumn-CHECK)
  │           └── 3. ADD CONSTRAINT (FOREIGN KEY) — sist, kan referera andra tabeller
  │
  ├── [8] ÅTERSKAPA KOLUMNEGENSKAPER
  │     → aterskapa_kolumnegenskaper(schema, tabell, egenskaper)
  │           ├── 1. SET NOT NULL
  │           ├── 2. ADD CONSTRAINT (enkla CHECK-villkor)
  │           ├── 3. SET DEFAULT (hoppar över standardkolumner med historik_qa=true)
  │           └── 4. ADD GENERATED ALWAYS AS IDENTITY
  │
  ├── [9] SKAPA GiST-INDEX
  │     ├── Gäller alla scheman som har geometrikolumn
  │     └── CREATE INDEX … USING gist(geom)
  │           (indexnamnet trunkeras till 50 tecken för att undvika
  │            namnkollision med historiktabellens index på _h-versionen)
  │
  ├── [10] GEOMETRIVALIDERING (villkorligt)
  │     ├── Gäller BARA scheman som matchar ^sk[0-2]_kba_
  │     │     (externt laddade _ext_-scheman valideras i FME, inte här)
  │     └── ADD CONSTRAINT … CHECK (validera_geometri(geom))
  │                 → validera_geometri(geom, tolerans=0.001)
  │                       ├── ST_IsValid()            — OGC-korrekt topologi
  │                       ├── NOT ST_IsEmpty()        — innehåller koordinater
  │                       ├── Inga upprepade punkter  — ST_NPoints-jämförelse
  │                       ├── Polygon: area > 1 mm²   — tolerans²
  │                       └── Linje: längd > 1 mm     — tolerans
  │
  └── [11] SKAPA HISTORIK OCH QA (villkorligt)
        → skapa_historik_qa(schema, tabell)
              ├── Kontrollerar om någon standardkolumn har historik_qa=true
              │     Ja: andrad_tidpunkt, andrad_av → fortsätter
              │     Nej: returnerar false, ingenting skapas
              │
              ├── Skapar HISTORIKTABELL (tabell_h):
              │     ├── h_typ       char(1)      NOT NULL CHECK IN ('U','D')
              │     ├── h_tidpunkt  timestamptz  NOT NULL DEFAULT NOW()
              │     ├── h_av        text         NOT NULL DEFAULT session_user
              │     └── [alla kolumner från moderntabellen i samma ordning]
              │     Skapar INDEX på (gid, h_tidpunkt DESC) för prestanda
              │
              ├── Skapar QA-TRIGGERFUNKTION (trg_fn_<tabell>_qa):
              │     ├── ON UPDATE: kopierar OLD → historik som 'U'
              │     │             sätter NEW.andrad_tidpunkt = NOW()
              │     │             sätter NEW.andrad_av = session_user
              │     │             (session_user = faktisk inloggad roll,
              │     │              inte rollen man SET ROLE till)
              │     └── ON DELETE: kopierar OLD → historik som 'D'
              │
              ├── Skapar TRIGGER (trg_<tabell>_qa):
              │     BEFORE UPDATE OR DELETE ON <tabell>
              │     FOR EACH ROW EXECUTE FUNCTION trg_fn_<tabell>_qa()
              │
              └── Registrerar i hex_metadata:
                    parent_oid, parent_schema, parent_table,
                    history_schema, history_table, trigger_funktion
```

---

## 4. ALTER TABLE — ADD COLUMN

```sql
ALTER TABLE sk0_kba_bygg.byggnader_y ADD COLUMN antal_bostad integer;
```

`hantera_kolumntillagg_trigger` → `hantera_kolumntillagg()`

```
hantera_kolumntillagg()
  ├── Rekursionsskydd: avbryt om temp.reorganization_in_progress = true
  ├── Avbryt om temp.tabellstrukturering_pagar = true
  │     (hantera_ny_tabell håller på — stör inte)
  │
  ├── Är det en RENAME TO-operation? → se avsnitt 5
  │
  ├── [1] IDENTIFIERA KOLUMNER ATT FLYTTA
  │     ├── Hämtar standardkolumner med ordinal_position < 0 (ska ligga sist)
  │     └── Evaluerar schema_uttryck för varje — hoppar över de som inte matchar
  │
  ├── [2] FLYTTA STANDARDKOLUMNER TILL SIST
  │     För varje kolumn (skapad_av, andrad_tidpunkt, andrad_av):
  │       ADD COLUMN <kolumn>_temp0001  <datatyp>
  │       UPDATE SET <kolumn>_temp0001 = <kolumn>
  │       DROP COLUMN <kolumn>
  │       RENAME <kolumn>_temp0001 TO <kolumn>
  │     (Data bevaras; kolumnen hamnar sist tack vare PostgreSQL:s ordning)
  │
  ├── [3] FLYTTA GEOMETRIKOLUMN TILL ABSOLUT SIST
  │     ├── → hamta_geometri_definition(schema, tabell)  (hämtar aktuell definition)
  │     └── Samma 4-stegs temp-kolumnteknik som ovan
  │
  └── [4] SYNKRONISERA HISTORIKTABELL (om den finns)
        ├── Jämför kolumner i modertabell mot historiktabell
        │     Kolumn finns i parent men saknas i historik → ADD COLUMN till historiktabellen
        │     Kolumn finns i historik men saknas i parent → logga (behålls, ingen borttagning)
        │     Typavvikelse → logga varning (kräver manuell åtgärd)
        │
        ├── Inaktiverar QA-triggern tillfälligt (om synk sker)
        ├── Regenererar QA-triggerfunktionen med ny kolumnlista
        ├── Flyttar standardkolumner till sist i historiktabellen
        ├── Flyttar geom till sist i historiktabellen
        └── Återaktiverar QA-triggern
```

---

## 5. ALTER TABLE — RENAME TO

```sql
ALTER TABLE sk0_kba_bygg.byggnader_y RENAME TO fastigheter_y;
```

`hantera_kolumntillagg_trigger` → `hantera_kolumntillagg()`

```
hantera_kolumntillagg()
  ├── Detekterar RENAME TO i frågesträngen
  │
  ├── Slår upp tabellen i hex_metadata via OID (stabilt genom rename)
  │     Hittar: history_table='byggnader_y_h'
  │
  ├── Beräknar nytt historiktabellnamn: fastigheter_y_h
  │     (trunkeras om > 63 byte)
  │
  ├── ALTER TABLE byggnader_y_h RENAME TO fastigheter_y_h
  │
  ├── Uppdaterar hex_metadata:
  │     SET parent_table = 'fastigheter_y'
  │         history_table = 'fastigheter_y_h'
  │
  └── Returnerar — ingen kolumnomordning görs vid rename
```

---

## 6. CREATE VIEW

```sql
CREATE VIEW sk0_kba_bygg.v_byggnader_aktiva_y AS
  SELECT * FROM sk0_kba_bygg.byggnader_y WHERE status = 'aktiv';
```

`hantera_ny_vy_trigger` → `hantera_ny_vy()`

```
hantera_ny_vy()
  ├── Hoppar över public-schema
  └── → validera_vynamn(schema, vynamn)
          ├── Kontrollerar prefix: måste börja med v_
          │
          ├── Räknar geometrier i geometry_columns för vyn
          │     0 geometrier → inget suffix (t.ex. v_statistik)
          │     1 geometri   → suffix baserat på typ:
          │                    _p = POINT/MULTIPOINT
          │                    _l = LINESTRING/MULTILINESTRING
          │                    _y = POLYGON/MULTIPOLYGON
          │                    _g = övriga
          │     2+ geometrier → alltid _g
          │
          ├── Kontrollerar att vynamnet slutar med rätt suffix
          │
          ├── Specialfall: ST_*-transformationer med generisk GEOMETRY-typ
          │     Om vydefinitionen innehåller ST_*-anrop OCH
          │     geometry_columns returnerar generisk GEOMETRY (utan explicit cast):
          │     → EXCEPTION med hjälpmeddelande:
          │       "Typcasta resultatet explicit, t.ex.:
          │        ST_Buffer(geom, 100)::geometry(Polygon,3007)"
          │
          └── Validering misslyckad → EXCEPTION → rollback
```

---

## 7. DROP TABLE

```sql
DROP TABLE sk0_kba_bygg.byggnader_y;
```

`hantera_borttagen_tabell_trigger` → `hantera_borttagen_tabell()`
Körs vid `SQL_DROP` (före den faktiska borttagningen).

```
hantera_borttagen_tabell()
  ├── Rekursionsskydd: avbryt om temp.historikborttagning_pagar = true
  ├── Avbryt om temp.tabellstrukturering_pagar = true
  │     (byt_ut_tabell droppar internt — det är inte en riktig DROP)
  │
  ├── Sätter: temp.historikborttagning_pagar = true
  │
  └── För varje tabell i pg_event_trigger_dropped_objects():
        ├── Hoppar över: tabeller som slutar på _h, public-schema, pg_*-scheman
        │
        ├── Slår upp i hex_metadata via OID
        │     Hittad  → använder lagrade history_table och trigger_funktion
        │     Ej hittad → fallback till namnkonvention (tabell || '_h')
        │
        ├── DROP TABLE IF EXISTS <historiktabell>
        │     (utlöser rekursivt DROP TABLE-event → stoppas av rekursionsskyddet)
        │
        ├── DROP FUNCTION IF EXISTS trg_fn_<tabell>_qa()
        │
        └── DELETE FROM hex_metadata WHERE parent_oid = <oid>
```

---

## 8. DROP SCHEMA

```sql
DROP SCHEMA sk0_kba_bygg CASCADE;
```

`ta_bort_schemaroller_trigger` → `ta_bort_schemaroller()`
Körs vid `SQL_DROP`.
**Kör som:** SECURITY DEFINER (postgres) — krävs för att ta bort roller.

```
ta_bort_schemaroller()
  ├── Hoppar över systemscheman
  │
  └── För varje rad i standardiserade_roller där ta_bort_med_schema = true:
        ├── Bygger rollnamn: ersätter {schema} med faktiskt schemanamn
        │
        ├── Tar bort LOGIN-roller FÖRST (måste göras före grupprollen):
        │     För varje post i login_roller:
        │       ├── Bygger login-rollnamn (suffix/prefix-variant)
        │       ├── REASSIGN OWNED BY <loginroll> TO postgres
        │       ├── DROP OWNED BY <loginroll>
        │       └── DROP ROLE <loginroll>
        │
        ├── Tar bort NOLOGIN-grupprollen:
        │     ├── REASSIGN OWNED BY <grupprolle> TO postgres
        │     ├── DROP OWNED BY <grupprolle>
        │     └── DROP ROLE <grupprolle>
        │
        └── Globala roller (global_roll = true) berörs INTE
              r_sk0_global och r_sk1_global överlever DROP SCHEMA
```

> PostgreSQL hanterar borttagningen av själva schemat och dess objekt
> (tabeller, vyer etc.) via CASCADE — det är standardbeteende.
> Hex tar hand om det som PostgreSQL inte rensar: roller och eventuella
> historiktabeller i andra scheman.

---

## 9. Externt system: GeoServer-lyssnaren (Python)

Lyssnaren är ett fristående program (eller Windows-tjänst) som kopplar upp
mot PostgreSQL och väntar på `pg_notify`-meddelanden.

```
┌─────────────────────────────────────────────────────────────────────┐
│  PostgreSQL                                                         │
│    notifiera_geoserver() ──→ pg_notify('geoserver_schema',         │
│                                         'sk0_kba_bygg')            │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │  LISTEN / NOTIFY
┌──────────────────────────────────▼──────────────────────────────────┐
│  Python-lyssnaren (geoserver_listener.py)                           │
│                                                                     │
│  Startordning:                                                      │
│    load_config()                                                    │
│      ├── Miljövariabler eller .env-fil                              │
│      ├── Stöd för flera databaser: HEX_DB_1_*, HEX_DB_2_* …       │
│      └── Legacy-format: HEX_PG_*, HEX_JNDI_*                      │
│                                                                     │
│    run_all_listeners()                                              │
│      ├── En databas  → körs i huvudtråden                          │
│      └── Flera databaser → en tråd per databas                     │
│                                                                     │
│  Per databas: listen_loop()                                         │
│    ├── Ansluter med autocommit                                      │
│    ├── LISTEN geoserver_schema                                      │
│    ├── select() med 5 s timeout (håller anslutningen levande)      │
│    ├── Tar emot notifiering → handle_schema_notification()         │
│    ├── Tappad anslutning → väntar HEX_RECONNECT_DELAY (std 5 s)   │
│    │    → e-post om EmailNotifier är konfigurerad                  │
│    └── Återkopplad → e-post om EmailNotifier är konfigurerad      │
│                                                                     │
│  handle_schema_notification('sk0_kba_bygg', jndi_map, gs_client)   │
│    ├── Validerar mönster: ^sk[01]_(ext|kba|sys)_.+$                │
│    ├── Extraherar prefix: sk0                                       │
│    ├── Slår upp JNDI: jndi_map['sk0']                              │
│    │     = 'java:comp/env/jdbc/server.database'                    │
│    └── → GeoServerClient                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│  GeoServerClient (HTTP Basic Auth mot GeoServer REST API)           │
│                                                                     │
│  Retry-logik: timeout/nätverksfel → 3 försök (2s, 5s, 10s)        │
│               4xx/5xx-svar         → misslyckas direkt             │
│                                                                     │
│  1. GET  /rest/workspaces/sk0_kba_bygg.json                        │
│       200 = workspace finns redan → hoppa över                     │
│       404 = finns inte → skapa                                     │
│                                                                     │
│  2. POST /rest/workspaces                                           │
│       {"workspace": {"name": "sk0_kba_bygg"}}                      │
│       → 201 Created                                                 │
│                                                                     │
│  3. GET  /rest/workspaces/sk0_kba_bygg/datastores/sk0_kba_bygg.json│
│       200 = datakälla finns redan → hoppa över                     │
│       404 = finns inte → skapa                                     │
│                                                                     │
│  4. POST /rest/workspaces/sk0_kba_bygg/datastores                  │
│       PostGIS JNDI-konfiguration:                                  │
│         dbtype:             postgis                                 │
│         jndiReferenceName:  java:comp/env/jdbc/server.database     │
│         schema:             sk0_kba_bygg                           │
│         Expose primary keys: true                                   │
│         fetch size:         1000                                    │
│         Loose bbox:         true                                    │
│         Estimated extends:  true                                    │
│         encode functions:   true                                    │
│       → 201 Created                                                 │
└─────────────────────────────────────────────────────────────────────┘

  EmailNotifier (valfri, konfigureras via HEX_SMTP_*)
    ├── STARTTLS mot Office 365 (port 587 som standard)
    ├── Skickas vid: anslutningsförlust, GeoServer-fel
    ├── Skickas vid: återkoppling (återhämtning)
    └── Spam-skydd: 300 s cooldown per unikt meddelande
```

**Windows-tjänst** (`geoserver_service.py`):

```
HexGeoServerService (win32serviceutil.ServiceFramework)
  Tjänstnamn:    HexGeoServerListener
  Visningsnamn:  Hex GeoServer Schema Listener
  Loggfiler:     C:\ProgramData\Hex\geoserver_listener.log
                 (roterande, 5 MB, 5 kopior)
  Kommandon:     install / start / stop / remove / status
```

---

## 10. Rekursionsskydd

Systemet skapar tabeller internt (t.ex. vid `byt_ut_tabell`) och tar bort dem —
det utlöser i sin tur nya eventutlösare. Tre flaggor förhindrar oändliga kedjor:

| Flagga | Sätts av | Kontrolleras av | Syfte |
|---|---|---|---|
| `temp.tabellstrukturering_pagar` | `hantera_ny_tabell` | `hantera_ny_tabell`, `hantera_kolumntillagg`, `hantera_borttagen_tabell` | Förhindrar re-entry under `byt_ut_tabell` |
| `temp.reorganization_in_progress` | `hantera_kolumntillagg` | `hantera_kolumntillagg` | Förhindrar re-entry under kolumnflyttning |
| `temp.historikborttagning_pagar` | `hantera_borttagen_tabell` | `hantera_borttagen_tabell` | Förhindrar re-entry när `_h`-tabellen droppas |

> `temp.*` är PostgreSQL-sessionsvariabler — de återställs automatiskt
> när transaktionen avslutas, oavsett om den lyckas eller rullas tillbaka.

---

## 11. Snabbreferens: alla funktioner

### Eventutlösarfunktioner (DDL-event)

| Funktion | Utlösare av | Händelse |
|---|---|---|
| `validera_schemanamn()` | `validera_schemanamn_trigger` | CREATE SCHEMA, DDL_COMMAND_END |
| `hantera_standardiserade_roller()` | `hantera_standardiserade_roller_trigger` | CREATE SCHEMA, DDL_COMMAND_END |
| `notifiera_geoserver()` | `notifiera_geoserver_trigger` | CREATE SCHEMA, DDL_COMMAND_END |
| `hantera_ny_tabell()` | `hantera_ny_tabell_trigger` | CREATE TABLE, DDL_COMMAND_END |
| `hantera_kolumntillagg()` | `hantera_kolumntillagg_trigger` | ALTER TABLE, DDL_COMMAND_END |
| `hantera_ny_vy()` | `hantera_ny_vy_trigger` | CREATE VIEW, DDL_COMMAND_END |
| `hantera_borttagen_tabell()` | `hantera_borttagen_tabell_trigger` | DROP TABLE, SQL_DROP |
| `ta_bort_schemaroller()` | `ta_bort_schemaroller_trigger` | DROP SCHEMA, SQL_DROP |

### Valideringsfunktioner

| Funktion | Anropas av | Syfte |
|---|---|---|
| `validera_tabell(schema, tabell)` | `hantera_ny_tabell` | Kontrollerar namnkonvention och geometristruktur |
| `validera_vynamn(schema, vy)` | `hantera_ny_vy` | Kontrollerar prefix och suffix |
| `validera_geometri(geom, tolerans)` | CHECK-villkor på tabeller | OGC-validering + kvalitetskontroll |

### Strukturfunktioner

| Funktion | Anropas av | Syfte |
|---|---|---|
| `hamta_geometri_definition(schema, tabell)` | `validera_tabell`, `hantera_kolumntillagg`, `skapa_historik_qa` | Extraherar geometry_columns-info till geom_info-struct |
| `hamta_kolumnstandard(schema, tabell, geom_info)` | `hantera_ny_tabell` | Bygger slutlig kolumnlista utifrån standardiserade_kolumner |

### Regelhanteringsfunktioner

| Funktion | Anropas av | Syfte |
|---|---|---|
| `spara_tabellregler(schema, tabell)` | `hantera_ny_tabell` | Extraherar index, FK, constraints |
| `spara_kolumnegenskaper(schema, tabell)` | `hantera_ny_tabell` | Extraherar DEFAULT, NOT NULL, CHECK, IDENTITY |
| `aterskapa_tabellregler(schema, tabell, regler)` | `hantera_ny_tabell` | Återskapar i beroendeordning |
| `aterskapa_kolumnegenskaper(schema, tabell, egenskaper)` | `hantera_ny_tabell` | Återskapar i beroendeordning |

### Verktygsfunktioner

| Funktion | Anropas av | Syfte |
|---|---|---|
| `byt_ut_tabell(schema, tabell, temp)` | `hantera_ny_tabell` | DROP original + RENAME temp |
| `uppdatera_sekvensnamn(schema, tabell)` | `hantera_ny_tabell` | Döper om IDENTITY-sekvenser |
| `skapa_historik_qa(schema, tabell)` | `hantera_ny_tabell` | Skapar historiktabell + QA-trigger |
| `tilldela_rollrattigheter(schema, roll, typ)` | `hantera_standardiserade_roller` | GRANT USAGE/SELECT/INSERT/UPDATE/DELETE |

### Anpassade typer

| Typ | Används av | Innehåll |
|---|---|---|
| `geom_info` | `validera_tabell`, `hamta_kolumnstandard`, `skapa_historik_qa` | Geometrikolumnens namn, typ, SRID, suffix, definition |
| `kolumnkonfig` | `hamta_kolumnstandard` | Kolumnnamn, position, datatyp |
| `kolumnegenskaper` | `spara_kolumnegenskaper`, `aterskapa_kolumnegenskaper` | DEFAULT, NOT NULL, CHECK, IDENTITY per kolumn |
| `tabellregler` | `spara_tabellregler`, `aterskapa_tabellregler` | Index, FK, PK/UNIQUE/CHECK på tabellnivå |
