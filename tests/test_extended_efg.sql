-- ============================================================
-- HEX EXTENDED TEST SUITE — GROUPS E, F & G
--
-- E  Historiktabell-synkronisering (ALTER TABLE ADD COLUMN on kba table)
--    E0  Precondition: history table exists before sync tests
--    E1  ADD COLUMN synced to history table automatically
--    E2  geom stays last in both main and history table after sync
--    E3  Adding second column: both appear in history table
--    E4  ADD COLUMN twice when already in sync: no duplicates
--
-- F  Dataöverlevnad (existing rows survive ADD COLUMN restructuring)
--    F1  Existing rows and numeric values intact after ADD COLUMN
--    F2  Geometry values valid and intact after ADD COLUMN
--    F3  QA trigger works after ADD COLUMN: UPDATE writes history + bumps andrad_tidpunkt
--    F4  DELETE writes to history table with h_typ='D'
--
-- G  QA-trigger-säkerhet vid ADD COLUMN (kolumnordningsfix)
--    G0  Precondition: history table and QA trigger exist
--    G1  First ADD COLUMN: no orphaned _temp0001 columns
--    G2  New column before geom in main table
--    G3  New column before geom in history table
--    G4  QA trigger re-enabled after ADD COLUMN (UPDATE writes history)
--    G5  Second ADD COLUMN also places column before geom
--    G6  No orphaned _temp0001 after four ADD COLUMNs in sequence
--    G7  geom last in both tables after four ADD COLUMNs
--    G8  ADD COLUMN on table with existing rows: data intact, no crash
--    G9  ext-schema ADD COLUMN (no QA trigger): column before geom, no orphans
--
-- Schemas used: sk2_kba_test, sk2_ext_test
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX EXTENDED TEST SUITE — GROUPS E, F & G'
\echo '============================================================'

-- ============================================================
-- Cleanup and setup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_test CASCADE;

CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_ext_test;

-- ============================================================
-- E: HISTORY TABLE AUTO-SYNC (ALTER TABLE ADD COLUMN on kba table)
-- ============================================================
\echo ''
\echo '--- GROUP E: History table auto-sync on ALTER TABLE ---'

CREATE TABLE sk2_kba_test.sync_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    ) THEN
        RAISE NOTICE 'TEST E0 PASSED: sync_test_y_h history table exists before sync tests';
    ELSE
        RAISE WARNING 'TEST E0 FAILED: No history table for sync_test_y - cannot run E tests';
    END IF;
END $$;

ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN extra_data text;

-- E1: New column must appear in history table automatically
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
        AND column_name = 'extra_data'
    ) THEN
        RAISE NOTICE 'TEST E1 PASSED: ADD COLUMN extra_data auto-synced to history table';
    ELSE
        RAISE WARNING 'TEST E1 FAILED: extra_data not synced to history table sync_test_y_h';
    END IF;
END $$;

-- E2: geom must stay last in BOTH main table and history table after sync
DO $$
DECLARE
    geom_pos_main  integer;
    last_pos_main  integer;
    geom_pos_hist  integer;
    last_pos_hist  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y';

    SELECT ordinal_position INTO geom_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h';

    IF geom_pos_main = last_pos_main AND geom_pos_hist = last_pos_hist THEN
        RAISE NOTICE 'TEST E2 PASSED: geom is last in both main (pos %/%) and history (pos %/%)',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    ELSE
        RAISE WARNING 'TEST E2 FAILED: geom not last. main: %/%, history: %/%',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    END IF;
END $$;

-- E3: Adding a second column - both should appear in history table
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN kategori integer;

DO $$
DECLARE synced integer;
BEGIN
    SELECT COUNT(*) INTO synced FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name IN ('extra_data', 'kategori');
    IF synced = 2 THEN
        RAISE NOTICE 'TEST E3 PASSED: Both extra_data and kategori synced to history table';
    ELSE
        RAISE WARNING 'TEST E3 FAILED: Only % of 2 expected columns synced to history table', synced;
    END IF;
END $$;

-- E4: Running ADD COLUMN twice when already in sync - must not duplicate
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN stable_col text;
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN another_col text;

DO $$
DECLARE dup_count integer;
BEGIN
    SELECT COUNT(*) INTO dup_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name = 'stable_col';
    IF dup_count = 1 THEN
        RAISE NOTICE 'TEST E4 PASSED: stable_col appears exactly once in history (no duplicates from repeated syncs)';
    ELSE
        RAISE WARNING 'TEST E4 FAILED: stable_col appears % times in history table (expected 1)', dup_count;
    END IF;
END $$;

-- ============================================================
-- F: DATA SURVIVAL
-- ============================================================
\echo ''
\echo '--- GROUP F: Data survival ---'

CREATE TABLE sk2_kba_test.data_test_y (
    naam       text,
    waarde     numeric(10,2),
    categorie  text,
    geom       geometry(Polygon, 3007)
);

INSERT INTO sk2_kba_test.data_test_y (naam, waarde, categorie, geom) VALUES
    ('objekt_1', 123.45, 'A', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3007)),
    ('objekt_2', 678.90, 'B', ST_GeomFromText('POLYGON((200 200,300 200,300 300,200 300,200 200))', 3007));

-- F1: ADD COLUMN - existing rows and values must survive
ALTER TABLE sk2_kba_test.data_test_y ADD COLUMN extra text;

DO $$
DECLARE
    row_count integer;
    sum_val   numeric;
BEGIN
    SELECT COUNT(*), SUM(waarde) INTO row_count, sum_val
    FROM sk2_kba_test.data_test_y;
    IF row_count = 2 AND sum_val = 802.35 THEN
        RAISE NOTICE 'TEST F1 PASSED: Both rows and numeric values intact after ADD COLUMN (count=%, sum=%)', row_count, sum_val;
    ELSE
        RAISE WARNING 'TEST F1 FAILED: Data not preserved. rows=%, sum=%', row_count, sum_val;
    END IF;
END $$;

-- F2: Geometry values must survive ADD COLUMN
DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk2_kba_test.data_test_y
    WHERE ST_IsValid(geom) AND NOT ST_IsEmpty(geom);
    IF geom_count = 2 THEN
        RAISE NOTICE 'TEST F2 PASSED: Both geometry values valid and intact after ADD COLUMN';
    ELSE
        RAISE WARNING 'TEST F2 FAILED: Expected 2 valid geometries, found %', geom_count;
    END IF;
END $$;

-- F3: QA trigger works after ADD COLUMN - UPDATE writes history and bumps andrad_tidpunkt
DO $$
DECLARE
    hist_count integer;
    old_ts     timestamptz;
    new_ts     timestamptz;
BEGIN
    SELECT andrad_tidpunkt INTO old_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';

    PERFORM pg_sleep(0.05);

    UPDATE sk2_kba_test.data_test_y SET waarde = 999.99 WHERE naam = 'objekt_1';

    SELECT andrad_tidpunkt INTO new_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';
    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_1' AND h_typ = 'U';

    -- andrad_tidpunkt has historik_qa=true so no DEFAULT - it starts NULL and is set by
    -- the UPDATE trigger. Check that new_ts IS NOT NULL and (was NULL or advanced).
    IF hist_count = 1 AND new_ts IS NOT NULL AND (old_ts IS NULL OR new_ts > old_ts) THEN
        RAISE NOTICE 'TEST F3 PASSED: UPDATE wrote 1 history row and bumped andrad_tidpunkt (old=%, new=%)',
            old_ts, new_ts;
    ELSIF hist_count = 1 AND new_ts IS NULL THEN
        RAISE WARNING 'TEST F3 FAILED: History row written but andrad_tidpunkt still NULL after UPDATE (old=%, new=%)',
            old_ts, new_ts;
    ELSIF hist_count = 1 THEN
        RAISE WARNING 'TEST F3 PARTIAL: History row written but andrad_tidpunkt not advanced (old=%, new=%)',
            old_ts, new_ts;
    ELSE
        RAISE WARNING 'TEST F3 FAILED: Expected 1 history row, got %. andrad_tidpunkt: old=%, new=%',
            hist_count, old_ts, new_ts;
    END IF;
END $$;

-- F4: DELETE writes to history table with h_typ='D'
DO $$
DECLARE hist_count integer;
BEGIN
    DELETE FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_2';
    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_2' AND h_typ = 'D';
    IF hist_count = 1 THEN
        RAISE NOTICE 'TEST F4 PASSED: DELETE wrote 1 history row with h_typ=''D''';
    ELSE
        RAISE WARNING 'TEST F4 FAILED: Expected 1 DELETE history row, got %', hist_count;
    END IF;
END $$;

-- ============================================================
-- G: QA TRIGGER SAFETY DURING ADD COLUMN (COLUMN-ORDER FIX)
--
-- Bug: steg 4 och 5 i hantera_kolumntillagg gör UPDATE-satser
-- för att kopiera kolumndata till en temporär _temp0001-kolumn.
-- QA-triggern (trg_<tabell>_qa) fångar UPDATEn och kör:
--   INSERT INTO <historiktabell> SELECT OLD.*
-- Men historiktabellen har inte _temp0001-kolumnen ännu, vilket ger:
--   "INSERT has more expressions than target columns"
-- EXCEPTION-blocket fångar felet men lämnar _temp0001-kolumnen kvar.
-- Vid nästa ADD COLUMN hittar _temp0001-vakten de föräldralösa
-- kolumnerna och hoppar över steg 3-5 (CONTINUE), vilket gör att
-- geom aldrig flyttas sist → nya kolumner hamnar efter geom.
--
-- Fix: inaktivera QA-triggern innan steg 3/4/5 påbörjas, inte
-- inne i steg 6 efter att felet redan inträffat.
-- ============================================================
\echo ''
\echo '--- GROUP G: QA trigger safety during ADD COLUMN (column-order fix) ---'

-- G-setup: färsk kba-tabell som automatiskt får QA-trigger och historiktabell
CREATE TABLE sk2_kba_test.qa_order_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

-- G0: Förutsättning - historiktabell och QA-trigger ska finnas
DO $$
DECLARE
    has_history boolean;
    has_trigger boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h'
    ) INTO has_history;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_schema = 'sk2_kba_test'
          AND event_object_table = 'qa_order_test_y'
          AND trigger_name LIKE 'trg_%_qa'
    ) INTO has_trigger;

    IF has_history AND has_trigger THEN
        RAISE NOTICE 'TEST G0 PASSED: History table and QA trigger exist (bug preconditions verified)';
    ELSIF NOT has_history THEN
        RAISE WARNING 'TEST G0 FAILED: No history table qa_order_test_y_h - kba schema setup broken';
    ELSE
        RAISE WARNING 'TEST G0 FAILED: No QA trigger on qa_order_test_y - trigger creation broken';
    END IF;
END $$;

-- G1: Första ADD COLUMN får inte lämna kvar föräldralösa _temp0001-kolumner
--     Bugg: steg 4.1 (ADD _temp0001) lyckades, steg 4.2 (UPDATE) triggade QA-triggern
--     som kraschade med "INSERT has more expressions than target columns".
--     EXCEPTION fångade felet men _temp0001 lämnades kvar.
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_a text;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_order_test_y', 'qa_order_test_y_h')
      AND column_name LIKE '%_temp0001';

    IF orphan_count = 0 THEN
        RAISE NOTICE 'TEST G1 PASSED: No orphaned _temp0001 columns after first ADD COLUMN (QA trigger correctly disabled during restructuring)';
    ELSE
        RAISE WARNING 'TEST G1 FAILED: % orphaned _temp0001 column(s) - QA trigger fired during restructuring UPDATE and left orphans', orphan_count;
    END IF;
END $$;

-- G2: Ny kolumn ska ligga FÖRE geom i huvudtabellen efter första ADD COLUMN
DO $$
DECLARE
    col_a_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_a_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'col_a';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    IF col_a_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G2 PASSED: col_a (pos %) before geom (pos %/%) in parent table', col_a_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G2 FAILED: geom is not last in parent. geom=%, last=%', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G2 FAILED: col_a (pos %) is after geom (pos %) - restructuring was skipped (orphan guard fired)', col_a_pos, geom_pos;
    END IF;
END $$;

-- G3: Ny kolumn ska ligga FÖRE geom i historiktabellen efter första ADD COLUMN
DO $$
DECLARE
    col_a_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_a_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'col_a';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h';

    IF col_a_pos IS NULL THEN
        RAISE WARNING 'TEST G3 FAILED: col_a not found in history table - history sync failed';
    ELSIF col_a_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G3 PASSED: col_a (pos %) before geom (pos %/%) in history table', col_a_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G3 FAILED: geom not last in history. geom=%, last=%', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G3 FAILED: col_a (pos %) is after geom (pos %) in history table', col_a_pos, geom_pos;
    END IF;
END $$;

-- G4: QA-triggern måste vara återaktiverad efter ADD COLUMN
--     Fixet inaktiverar triggern temporärt - den måste återaktiveras annars skrivs ingen historik.
INSERT INTO sk2_kba_test.qa_order_test_y (info, col_a, geom)
VALUES ('test_rad', 'initial', ST_GeomFromText('POLYGON((0 0,10 0,10 10,0 10,0 0))', 3007));

DO $$
DECLARE hist_count integer;
BEGIN
    UPDATE sk2_kba_test.qa_order_test_y SET col_a = 'updated' WHERE info = 'test_rad';

    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.qa_order_test_y_h
    WHERE info = 'test_rad' AND h_typ = 'U';

    IF hist_count = 1 THEN
        RAISE NOTICE 'TEST G4 PASSED: QA trigger re-enabled after ADD COLUMN - UPDATE wrote 1 history row';
    ELSE
        RAISE WARNING 'TEST G4 FAILED: Expected 1 history row from UPDATE, got % (QA trigger may still be disabled)', hist_count;
    END IF;
END $$;

-- G5: Andra ADD COLUMN ska också placera kolumnen FÖRE geom
--     Buggkedja: föräldralösa _temp0001 från G1 skulle göra att _temp0001-vakten
--     hoppar över steg 3-5 vid nästa ADD COLUMN → ny kolumn hamnar efter geom.
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_b integer;

DO $$
DECLARE
    col_b_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_b_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'col_b';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    IF col_b_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G5 PASSED: col_b (pos %) before geom (pos %/%) after second ADD COLUMN (no orphan cascade)', col_b_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G5 FAILED: geom not last after second ADD COLUMN (geom=%, last=%). Orphan _temp0001 guard likely skipped restructuring.', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G5 FAILED: col_b (pos %) after geom (pos %) - orphan _temp0001 guard blocked restructuring on second ADD COLUMN', col_b_pos, geom_pos;
    END IF;
END $$;

-- G6: Inga föräldralösa _temp0001-kolumner efter flera ADD COLUMNs i rad
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_c boolean;
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_d timestamptz;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_order_test_y', 'qa_order_test_y_h')
      AND column_name LIKE '%_temp0001';

    IF orphan_count = 0 THEN
        RAISE NOTICE 'TEST G6 PASSED: No orphaned _temp0001 columns after four ADD COLUMNs';
    ELSE
        RAISE WARNING 'TEST G6 FAILED: % orphaned _temp0001 column(s) after four ADD COLUMNs', orphan_count;
    END IF;
END $$;

-- G7: geom är sist i BÅDA tabellerna efter fyra ADD COLUMNs
DO $$
DECLARE
    geom_pos_main  integer;
    last_pos_main  integer;
    geom_pos_hist  integer;
    last_pos_hist  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    SELECT ordinal_position INTO geom_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h';

    IF geom_pos_main = last_pos_main AND geom_pos_hist = last_pos_hist THEN
        RAISE NOTICE 'TEST G7 PASSED: geom last in parent (pos %/%) and history (pos %/%) after four ADD COLUMNs',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    ELSE
        RAISE WARNING 'TEST G7 FAILED: geom not last. parent: %/%, history: %/%',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    END IF;
END $$;

-- G8: ADD COLUMN på tabell MED befintliga rader - omstrukturerings-UPDATE får inte krascha
--     Detta är det exakta scenariot som loggades: QA-triggern fångade UPDATE:n och kraschade
--     när tabellen innehöll rader (INSERT INTO hist SELECT OLD.* misslyckades med felaktigt kolumnantal).
CREATE TABLE sk2_kba_test.qa_rows_test_y (
    naam text,
    geom geometry(Polygon, 3007)
);

INSERT INTO sk2_kba_test.qa_rows_test_y (naam, geom) VALUES
    ('r1', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007)),
    ('r2', ST_GeomFromText('POLYGON((2 2,3 2,3 3,2 3,2 2))', 3007)),
    ('r3', ST_GeomFromText('POLYGON((4 4,5 4,5 5,4 5,4 4))', 3007));

ALTER TABLE sk2_kba_test.qa_rows_test_y ADD COLUMN waarde numeric(10,2);

DO $$
DECLARE
    row_count    integer;
    orphan_count integer;
    col_pos      integer;
    geom_pos     integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk2_kba_test.qa_rows_test_y;

    SELECT COUNT(*) INTO orphan_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_rows_test_y', 'qa_rows_test_y_h')
      AND column_name LIKE '%_temp0001';

    SELECT ordinal_position INTO col_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_rows_test_y' AND column_name = 'waarde';

    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_rows_test_y' AND column_name = 'geom';

    IF row_count = 3 AND orphan_count = 0 AND col_pos < geom_pos THEN
        RAISE NOTICE 'TEST G8 PASSED: ADD COLUMN on table with 3 rows: data intact, no orphans, waarde (pos %) before geom (pos %)',
            col_pos, geom_pos;
    ELSE
        RAISE WARNING 'TEST G8 FAILED: rows=%, orphans=%, waarde_pos=%, geom_pos=%. Expected: rows=3, orphans=0, waarde before geom.',
            row_count, orphan_count, col_pos, geom_pos;
    END IF;
END $$;

-- G9: ext-schema - ADD COLUMN utan QA-trigger (ingen historiktabell)
--     Verifierar att fixet inte bryter tabeller som saknar QA-trigger.
--     DISABLE TRIGGER på en tabell utan den triggern hanteras med EXCEPTION -> NOTICE.
CREATE TABLE sk2_ext_test.ext_order_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_ext_test.ext_order_test_y ADD COLUMN extra text;

DO $$
DECLARE
    extra_pos    integer;
    geom_pos     integer;
    last_pos     integer;
    orphan_count integer;
BEGIN
    SELECT ordinal_position INTO extra_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y' AND column_name = 'extra';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y';
    SELECT COUNT(*) INTO orphan_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y'
      AND column_name LIKE '%_temp0001';

    IF extra_pos < geom_pos AND geom_pos = last_pos AND orphan_count = 0 THEN
        RAISE NOTICE 'TEST G9 PASSED: ext schema ADD COLUMN: extra (pos %) before geom (pos %/%), no orphans',
            extra_pos, geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G9 FAILED: ext schema. extra_pos=%, geom_pos=%, last_pos=%, orphans=%',
            extra_pos, geom_pos, last_pos, orphan_count;
    END IF;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_test CASCADE;

\echo ''
\echo 'HEX EXTENDED E, F & G COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
