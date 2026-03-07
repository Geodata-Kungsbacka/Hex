-- ============================================================
-- HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE
--
-- Testar:
--   1  hex_dummy_geometrier tabell (struktur och rättigheter)
--   2  hex_avvikande_srid tabell (struktur och rättigheter)
--   3  lagg_till_dummy_geometri() (dummy-insättning och registrering)
--   4  ta_bort_dummy_rad() (automatisk dummy-borttagning vid INSERT)
--   5  hex_avvikande_srid registrering vid SRID ≠ 3007
--   6  Rensning vid DROP TABLE (hantera_borttagen_tabell)
--
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_dummy_test CASCADE;

CREATE SCHEMA sk0_ext_dummy_test;

-- ============================================================
-- 1: hex_dummy_geometrier tabell
-- ============================================================
\echo ''
\echo '--- GROUP 1: hex_dummy_geometrier table structure ---'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'hex_dummy_geometrier') THEN
        RAISE NOTICE 'TEST 1a PASSED: hex_dummy_geometrier table exists';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: hex_dummy_geometrier table missing';
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'hex_dummy_geometrier'
      AND column_name IN ('schema_namn', 'tabell_namn', 'gid', 'registrerad');
    IF col_count = 4 THEN
        RAISE NOTICE 'TEST 1b PASSED: hex_dummy_geometrier has all 4 expected columns';
    ELSE
        RAISE WARNING 'TEST 1b FAILED: Expected 4 columns, found %', col_count;
    END IF;
END $$;

-- Check PRIMARY KEY exists (schema_namn, tabell_namn, gid)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'public' AND c.conrelid = 'public.hex_dummy_geometrier'::regclass
          AND c.contype = 'p'
    ) THEN
        RAISE NOTICE 'TEST 1c PASSED: hex_dummy_geometrier has a PRIMARY KEY';
    ELSE
        RAISE WARNING 'TEST 1c FAILED: hex_dummy_geometrier missing PRIMARY KEY';
    END IF;
END $$;

-- ============================================================
-- 2: hex_avvikande_srid tabell
-- ============================================================
\echo ''
\echo '--- GROUP 2: hex_avvikande_srid table structure ---'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'hex_avvikande_srid') THEN
        RAISE NOTICE 'TEST 2a PASSED: hex_avvikande_srid table exists';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: hex_avvikande_srid table missing';
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'hex_avvikande_srid'
      AND column_name IN ('schema_namn', 'tabell_namn', 'srid', 'registrerad', 'registrerad_av');
    IF col_count = 5 THEN
        RAISE NOTICE 'TEST 2b PASSED: hex_avvikande_srid has all 5 expected columns';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: Expected 5 columns, found %', col_count;
    END IF;
END $$;

-- Check PRIMARY KEY is (schema_namn, tabell_namn)
DO $$
DECLARE pk_cols text;
BEGIN
    SELECT string_agg(a.attname, ', ' ORDER BY k.n)
    INTO pk_cols
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, n) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE n.nspname = 'public'
      AND c.conrelid = 'public.hex_avvikande_srid'::regclass
      AND c.contype = 'p';

    IF pk_cols = 'schema_namn, tabell_namn' THEN
        RAISE NOTICE 'TEST 2c PASSED: hex_avvikande_srid PRIMARY KEY is (schema_namn, tabell_namn)';
    ELSE
        RAISE WARNING 'TEST 2c FAILED: Expected PK (schema_namn, tabell_namn), got: %', pk_cols;
    END IF;
END $$;

-- ============================================================
-- 3: lagg_till_dummy_geometri — dummy inserted on CREATE TABLE
-- ============================================================
\echo ''
\echo '--- GROUP 3: lagg_till_dummy_geometri() ---'

CREATE TABLE sk0_ext_dummy_test.punker_p (
    beskrivning text,
    geom geometry(Point, 3007)
);

-- 3a: hex_dummy_geometrier contains a row for the new table
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 3a PASSED: dummy row registered in hex_dummy_geometrier for punker_p';
    ELSE
        RAISE WARNING 'TEST 3a FAILED: No entry in hex_dummy_geometrier for punker_p';
    END IF;
END $$;

-- 3b: The actual table contains exactly 1 row (the dummy)
DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 1 THEN
        RAISE NOTICE 'TEST 3b PASSED: punker_p contains exactly 1 dummy row';
    ELSE
        RAISE WARNING 'TEST 3b FAILED: Expected 1 dummy row, found %', row_count;
    END IF;
END $$;

-- 3c: The dummy row has a valid, non-empty Point geometry
DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk0_ext_dummy_test.punker_p
    WHERE ST_GeometryType(geom) = 'ST_Point' AND NOT ST_IsEmpty(geom);
    IF geom_count = 1 THEN
        RAISE NOTICE 'TEST 3c PASSED: Dummy row has valid non-empty Point geometry';
    ELSE
        RAISE WARNING 'TEST 3c FAILED: Expected 1 valid Point geometry, found %', geom_count;
    END IF;
END $$;

-- 3d: hex_ta_bort_dummy trigger exists on the table
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_dummy_test'
          AND c.relname = 'punker_p'
          AND t.tgname = 'hex_ta_bort_dummy'
    ) THEN
        RAISE NOTICE 'TEST 3d PASSED: hex_ta_bort_dummy trigger installed on punker_p';
    ELSE
        RAISE WARNING 'TEST 3d FAILED: hex_ta_bort_dummy trigger missing on punker_p';
    END IF;
END $$;

-- 3e: Polygon table also gets correct geometry type in dummy
CREATE TABLE sk0_ext_dummy_test.omraden_y (
    namn text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk0_ext_dummy_test.omraden_y
    WHERE ST_GeometryType(geom) = 'ST_Polygon' AND NOT ST_IsEmpty(geom);
    IF geom_count = 1 THEN
        RAISE NOTICE 'TEST 3e PASSED: Polygon table omraden_y has valid Polygon dummy row';
    ELSE
        RAISE WARNING 'TEST 3e FAILED: Expected 1 Polygon dummy, found %', geom_count;
    END IF;
END $$;

-- ============================================================
-- 4: ta_bort_dummy_rad — dummy auto-removed on first real INSERT
-- ============================================================
\echo ''
\echo '--- GROUP 4: ta_bort_dummy_rad() ---'

-- 4a: Before real insert, dummy still present
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 4a PASSED: Dummy tracking row still present before first real INSERT';
    ELSE
        RAISE WARNING 'TEST 4a FAILED: Dummy tracking row disappeared too early';
    END IF;
END $$;

-- Insert first real row
INSERT INTO sk0_ext_dummy_test.punker_p (beskrivning, geom)
VALUES ('riktig punkt', ST_GeomFromText('POINT(319000 6400000)', 3007));

-- 4b: After real insert, dummy row removed from the table
DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 1 THEN
        RAISE NOTICE 'TEST 4b PASSED: Only 1 row remains after first real INSERT (dummy removed)';
    ELSE
        RAISE WARNING 'TEST 4b FAILED: Expected 1 row (real only), found % (dummy may not have been removed)', row_count;
    END IF;
END $$;

-- 4c: The remaining row is the real one (has our known beschreibung value)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM sk0_ext_dummy_test.punker_p
        WHERE beskrivning = 'riktig punkt'
    ) THEN
        RAISE NOTICE 'TEST 4c PASSED: Remaining row is the real data row';
    ELSE
        RAISE WARNING 'TEST 4c FAILED: Real data row not found after dummy removal';
    END IF;
END $$;

-- 4d: hex_dummy_geometrier entry cleaned up
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 4d PASSED: hex_dummy_geometrier entry cleaned up after real INSERT';
    ELSE
        RAISE WARNING 'TEST 4d FAILED: hex_dummy_geometrier still has entry for punker_p after real INSERT';
    END IF;
END $$;

-- 4e: hex_ta_bort_dummy trigger is still present (harmless after dummy removed)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_dummy_test'
          AND c.relname = 'punker_p'
          AND t.tgname = 'hex_ta_bort_dummy'
    ) THEN
        RAISE NOTICE 'TEST 4e PASSED: hex_ta_bort_dummy trigger still present (harmless - early-exit guard active)';
    ELSE
        RAISE WARNING 'TEST 4e INFO: hex_ta_bort_dummy trigger was removed after dummy cleanup';
    END IF;
END $$;

-- 4f: Subsequent inserts work fine (trigger becomes a no-op)
INSERT INTO sk0_ext_dummy_test.punker_p (beskrivning, geom)
VALUES ('andra riktiga punkten', ST_GeomFromText('POINT(319001 6400001)', 3007));

DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 2 THEN
        RAISE NOTICE 'TEST 4f PASSED: Second INSERT works fine, trigger is harmless no-op (2 rows total)';
    ELSE
        RAISE WARNING 'TEST 4f FAILED: Expected 2 rows after second INSERT, found %', row_count;
    END IF;
END $$;

-- ============================================================
-- 5: hex_avvikande_srid — registered on SRID ≠ 3007
-- ============================================================
\echo ''
\echo '--- GROUP 5: hex_avvikande_srid registration ---'

-- 5a: Table with correct SRID (3007) must NOT appear in hex_avvikande_srid
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 5a PASSED: Table with SRID 3007 not registered in hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5a FAILED: Table with SRID 3007 incorrectly registered as avvikande';
    END IF;
END $$;

-- Create a table with SRID 3006 (incorrect — should be flagged)
CREATE TABLE sk0_ext_dummy_test.fel_srid_y (
    namn text,
    geom geometry(Polygon, 3006)
);

-- 5b: Table with SRID 3006 must appear in hex_avvikande_srid
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y'
    ) THEN
        RAISE NOTICE 'TEST 5b PASSED: Table with SRID 3006 registered in hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5b FAILED: Table with SRID 3006 not registered in hex_avvikande_srid';
    END IF;
END $$;

-- 5c: The stored SRID value is correct (3006)
DO $$
DECLARE stored_srid integer;
BEGIN
    SELECT srid INTO stored_srid
    FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y';
    IF stored_srid = 3006 THEN
        RAISE NOTICE 'TEST 5c PASSED: Stored SRID is 3006 (correctly recorded)';
    ELSE
        RAISE WARNING 'TEST 5c FAILED: Expected stored SRID 3006, got %', stored_srid;
    END IF;
END $$;

-- 5d: Table with correct SRID — ADD COLUMN (user column, not geom) must NOT trigger avvikande
ALTER TABLE sk0_ext_dummy_test.punker_p ADD COLUMN kategori text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 5d PASSED: ADD COLUMN (non-geom) on SRID-3007 table does not create avvikande entry';
    ELSE
        RAISE WARNING 'TEST 5d FAILED: Unexpected avvikande entry for SRID-3007 table after ADD COLUMN';
    END IF;
END $$;

-- 5e: Two tables with different wrong SRIDs — both appear in hex_avvikande_srid
CREATE TABLE sk0_ext_dummy_test.annan_srid_y (
    namn text,
    geom geometry(Polygon, 4326)
);

DO $$
DECLARE srid_val integer;
BEGIN
    SELECT srid INTO srid_val
    FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'annan_srid_y';
    IF srid_val = 4326 THEN
        RAISE NOTICE 'TEST 5e PASSED: Table with SRID 4326 registered with correct SRID in hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5e FAILED: Expected SRID 4326 for annan_srid_y, got %', srid_val;
    END IF;
END $$;

-- ============================================================
-- 6: Cleanup — hex_dummy_geometrier and hex_avvikande_srid
--    cleared when tables are dropped
-- ============================================================
\echo ''
\echo '--- GROUP 6: Cleanup on DROP TABLE ---'

-- Check current state: both avvikande tables registered
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test';
    IF cnt >= 1 THEN
        RAISE NOTICE 'TEST 6a PASSED: At least 1 avvikande SRID entry before DROP (count=%)', cnt;
    ELSE
        RAISE WARNING 'TEST 6a INFO: Expected at least 1 avvikande SRID entry, found %', cnt;
    END IF;
END $$;

DROP TABLE sk0_ext_dummy_test.fel_srid_y;

-- 6b: After dropping the avvikande table, its entry is removed
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y'
    ) THEN
        RAISE NOTICE 'TEST 6b PASSED: hex_avvikande_srid entry removed after DROP TABLE';
    ELSE
        RAISE WARNING 'TEST 6b FAILED: hex_avvikande_srid entry not cleaned up after DROP TABLE';
    END IF;
END $$;

-- 6c: Dropping a table that has a dummy (omraden_y still has dummy since no real rows were inserted)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'omraden_y'
    ) THEN
        RAISE NOTICE 'TEST 6c PASSED: omraden_y dummy still tracked before DROP';
    ELSE
        RAISE WARNING 'TEST 6c INFO: omraden_y dummy tracking entry already gone before DROP';
    END IF;
END $$;

DROP TABLE sk0_ext_dummy_test.omraden_y;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'omraden_y'
    ) THEN
        RAISE NOTICE 'TEST 6d PASSED: hex_dummy_geometrier entry removed after DROP TABLE omraden_y';
    ELSE
        RAISE WARNING 'TEST 6d FAILED: hex_dummy_geometrier entry not cleaned up after DROP TABLE';
    END IF;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_dummy_test CASCADE;

\echo ''
\echo 'HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED'
