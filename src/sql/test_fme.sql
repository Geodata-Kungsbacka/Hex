/******************************************************************************
 * TEST SUITE: FME TWO-STEP TABLE CREATION
 *
 * Tests the deferred geometry path for system users (e.g. FME) that create
 * tables in two steps:
 *   Step A) CREATE TABLE ... (data columns, NO geometry column)
 *   Step B) ALTER TABLE ... ADD COLUMN geom geometry(...)
 *
 * Objects under test:
 *   public.hex_systemanvandare     — system user registry
 *   public.hex_afvaktande_geometri — pending geometry registry
 *   hantera_ny_tabell              — deferred validation logic
 *   hantera_kolumntillagg          — pending completion + suffix validation
 *
 * Groups:
 *   F1  Infrastructure (tables exist, fme seeded)
 *   F2  Happy path – _ext_ schema two-step
 *   F3  Happy path – _kba_ schema two-step (geometry constraint deferred)
 *   F4  Suffix mismatch caught at ALTER TABLE ADD COLUMN geom
 *   F5  Non-system user still blocked (regression guard)
 *   F6  FME with geometry in CREATE TABLE (normal path, no deferral)
 *   F7  Custom system user registered in hex_systemanvandare
 *   F8  Multiple pending tables simultaneously
 *   F9  FME non-geometry table without suffix (no deferral expected)
 *   F10 Partial application_name does not trigger deferred path
 *   F11 DROP TABLE on pending table cleans hex_afvaktande_geometri
 *
 * Convention: NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED
 *
 * PREREQUISITES:
 *   Hex installed (all functions + tables deployed, including hex_systemanvandare
 *   and hex_afvaktande_geometri from this release).
 *   Run as superuser or Hex system owner.
 ******************************************************************************/

\echo ''
\echo '============================================================'
\echo 'HEX FME TWO-STEP TEST SUITE'
\echo '============================================================'

------------------------------------------------------------------------
-- INITIAL CLEANUP
------------------------------------------------------------------------
\echo ''
\echo '--- Initial cleanup ---'

DROP SCHEMA IF EXISTS sk0_ext_fmetest     CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_fmetest CASCADE;

-- Clean any stale pending entries left by previous test runs
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');

------------------------------------------------------------------------
-- SETUP
------------------------------------------------------------------------
\echo ''
\echo '--- Creating test schemas ---'

CREATE SCHEMA sk0_ext_fmetest;
CREATE SCHEMA sk1_kba_fmetest;

RESET application_name;

------------------------------------------------------------------------
-- F1: INFRASTRUCTURE
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F1: Infrastructure ---'

-- F1a: hex_systemanvandare table exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'hex_systemanvandare'
    ) THEN
        RAISE NOTICE 'TEST F1a PASSED: public.hex_systemanvandare table exists';
    ELSE
        RAISE WARNING 'TEST F1a FAILED: public.hex_systemanvandare table missing – install incomplete';
    END IF;
END $$;

-- F1b: 'fme' is seeded in hex_systemanvandare
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_systemanvandare WHERE anvandare = 'fme'
    ) THEN
        RAISE NOTICE 'TEST F1b PASSED: fme entry seeded in hex_systemanvandare';
    ELSE
        RAISE WARNING 'TEST F1b FAILED: fme not found in hex_systemanvandare – seed missing or install incomplete';
    END IF;
END $$;

-- F1c: hex_afvaktande_geometri table exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'hex_afvaktande_geometri'
    ) THEN
        RAISE NOTICE 'TEST F1c PASSED: public.hex_afvaktande_geometri table exists';
    ELSE
        RAISE WARNING 'TEST F1c FAILED: public.hex_afvaktande_geometri table missing – install incomplete';
    END IF;
END $$;

-- F1d: hex_afvaktande_geometri starts empty for our test schemas
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');
    IF cnt = 0 THEN
        RAISE NOTICE 'TEST F1d PASSED: No stale pending entries for test schemas';
    ELSE
        RAISE WARNING 'TEST F1d FAILED: % stale pending entries exist for test schemas (cleanup failed)', cnt;
    END IF;
END $$;

------------------------------------------------------------------------
-- F2: HAPPY PATH – _ext_ SCHEMA TWO-STEP
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F2: Happy path – ext schema two-step ---'

-- Step A: FME creates table with geometry suffix but no geometry column.
-- Expect: WARNING (not EXCEPTION), table created, standard columns added,
--         row inserted into hex_afvaktande_geometri.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.trafikdata_l (
        objectid   integer,
        vagnamn    text,
        hastighet  integer
    );
    RAISE NOTICE 'TEST F2a PASSED: Step A succeeded – FME created _l table without geom (no exception)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F2a FAILED: Step A raised exception: %', SQLERRM;
END $$;

RESET application_name;

-- F2b: Row registered in hex_afvaktande_geometri
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2b PASSED: Table registered in hex_afvaktande_geometri after step A';
    ELSE
        RAISE WARNING 'TEST F2b FAILED: Table NOT in hex_afvaktande_geometri – deferred path did not fire';
    END IF;
END $$;

-- F2c: Standard column gid added in step A (geometry columns are deferred, standard cols are not)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F2c PASSED: Standard column gid added during step A (non-geometry columns not deferred)';
    ELSE
        RAISE WARNING 'TEST F2c FAILED: gid missing – hantera_ny_tabell did not restructure table during step A';
    END IF;
END $$;

-- F2d: No GiST index yet (step 8 was deferred because geometriinfo = NULL)
DO $$
DECLARE idx_count integer;
BEGIN
    SELECT COUNT(*) INTO idx_count FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'trafikdata_l'
    AND indexdef LIKE '%USING gist%';
    IF idx_count = 0 THEN
        RAISE NOTICE 'TEST F2d PASSED: No GiST index yet after step A (correctly deferred)';
    ELSE
        RAISE WARNING 'TEST F2d FAILED: GiST index exists after step A – deferred path not taken';
    END IF;
END $$;

-- F2e: No geometry column yet
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = 'sk0_ext_fmetest' AND f_table_name = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2e PASSED: No geometry column on table after step A (as expected)';
    ELSE
        RAISE WARNING 'TEST F2e FAILED: Geometry column found after step A – unexpected';
    END IF;
END $$;

-- Step B: FME issues ALTER TABLE ADD COLUMN geom
ALTER TABLE sk0_ext_fmetest.trafikdata_l ADD COLUMN geom geometry(LineString, 3007);

-- F2f: Pending entry removed
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2f PASSED: Pending entry removed from hex_afvaktande_geometri after step B';
    ELSE
        RAISE WARNING 'TEST F2f FAILED: Pending entry still in hex_afvaktande_geometri after step B';
    END IF;
END $$;

-- F2g: GiST index created during step B (deferred step 5b.2)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'trafikdata_l'
        AND indexname = 'trafikdata_l_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F2g PASSED: GiST index trafikdata_l_geom_gidx created during step B';
    ELSE
        RAISE WARNING 'TEST F2g FAILED: GiST index not created during step B';
    END IF;
END $$;

-- F2h: geom column exists and is the last column
DO $$
DECLARE
    geom_pos integer;
    max_pos  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l';

    IF geom_pos IS NOT NULL AND geom_pos = max_pos THEN
        RAISE NOTICE 'TEST F2h PASSED: geom column exists and is last (position %/%)', geom_pos, max_pos;
    ELSIF geom_pos IS NULL THEN
        RAISE WARNING 'TEST F2h FAILED: geom column missing after step B';
    ELSE
        RAISE WARNING 'TEST F2h FAILED: geom not last (position % of %)', geom_pos, max_pos;
    END IF;
END $$;

-- F2i: No geometry validation constraint on _ext_ schema (only _kba_ gets this)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_fmetest.trafikdata_l'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST F2i PASSED: No geometry validation constraint on _ext_ table (correct)';
    ELSE
        RAISE WARNING 'TEST F2i FAILED: Geometry validation constraint added to _ext_ table (should only be on _kba_)';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.trafikdata_l;

------------------------------------------------------------------------
-- F3: HAPPY PATH – _kba_ SCHEMA TWO-STEP
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F3: Happy path – kba schema two-step ---'

-- Step A: pending table in _kba_ schema
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk1_kba_fmetest.fastigheter_y (
        fastighetsid  text,
        areal         numeric
    );
    RAISE NOTICE 'TEST F3a PASSED: Step A – kba pending table created without exception';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F3a FAILED: Step A raised exception: %', SQLERRM;
END $$;

RESET application_name;

-- F3b: Pending entry registered
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk1_kba_fmetest' AND ag.tabell_namn = 'fastigheter_y'
    ) THEN
        RAISE NOTICE 'TEST F3b PASSED: kba table registered as pending';
    ELSE
        RAISE WARNING 'TEST F3b FAILED: kba table NOT registered as pending';
    END IF;
END $$;

-- Step B
ALTER TABLE sk1_kba_fmetest.fastigheter_y ADD COLUMN geom geometry(Polygon, 3007);

-- F3c: Geometry validation constraint added for _kba_ (deferred step 5b.3)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk1_kba_fmetest.fastigheter_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST F3c PASSED: Geometry validation constraint added to kba table during step B';
    ELSE
        RAISE WARNING 'TEST F3c FAILED: Geometry validation constraint missing from kba table after step B';
    END IF;
END $$;

-- F3d: GiST index created
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk1_kba_fmetest' AND tablename = 'fastigheter_y'
        AND indexname = 'fastigheter_y_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F3d PASSED: GiST index created on kba table during step B';
    ELSE
        RAISE WARNING 'TEST F3d FAILED: GiST index missing from kba table after step B';
    END IF;
END $$;

-- F3e: Pending entry removed
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk1_kba_fmetest' AND ag.tabell_namn = 'fastigheter_y'
    ) THEN
        RAISE NOTICE 'TEST F3e PASSED: kba pending entry correctly removed after step B';
    ELSE
        RAISE WARNING 'TEST F3e FAILED: kba pending entry still present after step B';
    END IF;
END $$;

-- F3f: Geometry validation blocks invalid geometry (constraint is active)
DO $$
BEGIN
    INSERT INTO sk1_kba_fmetest.fastigheter_y (fastighetsid, geom)
    VALUES ('test', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST F3f FAILED: Empty geometry accepted – constraint not enforced';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'TEST F3f PASSED: Empty geometry blocked by deferred geometry constraint';
END $$;

-- F3g: Document known gap – no history table for FME kba deferred table
--      skapa_historik_qa runs in step 10 of hantera_ny_tabell with geometriinfo=NULL.
--      If it requires geometry to create history, the history table is never made.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_fmetest' AND table_name = 'fastigheter_y_h'
    ) THEN
        RAISE NOTICE 'TEST F3g INFO: History table WAS created for kba deferred table (skapa_historik_qa runs schema-based, not geometry-based)';
    ELSE
        RAISE NOTICE 'TEST F3g INFO: No history table for FME deferred kba table. skapa_historik_qa requires geometry at step A time. History tables for FME-loaded kba data must be created manually.';
    END IF;
END $$;

DROP TABLE IF EXISTS sk1_kba_fmetest.fastigheter_y;

------------------------------------------------------------------------
-- F4: SUFFIX MISMATCH CAUGHT AT ALTER TABLE
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F4: Suffix mismatch validation ---'

-- Create a pending table named _l (expects LineString geometry)
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.bantyp_l (
        typkod  varchar(10),
        beskr   text
    );
    RAISE NOTICE 'TEST F4a PASSED: Pending bantyp_l created (expects LineString via _l suffix)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F4a FAILED: %', SQLERRM;
END $$;

RESET application_name;

-- F4b: Attempt to add POLYGON geometry to a table named _l → exception
DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.bantyp_l ADD COLUMN geom geometry(Polygon, 3007);
    RAISE WARNING 'TEST F4b FAILED: Suffix mismatch (Polygon on _l table) was NOT caught';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Suffixkollision%' OR SQLERRM LIKE '%suffix%' OR SQLERRM LIKE '%_l%' THEN
            RAISE NOTICE 'TEST F4b PASSED: Suffix mismatch caught – Polygon rejected on _l table: %',
                left(SQLERRM, 120);
        ELSE
            RAISE NOTICE 'TEST F4b PASSED (other exception): %', left(SQLERRM, 120);
        END IF;
END $$;

-- F4c: ALTER TABLE was rolled back – geom column should NOT exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = 'sk0_ext_fmetest' AND f_table_name = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4c PASSED: geom column not present after rolled-back ALTER TABLE';
    ELSE
        RAISE WARNING 'TEST F4c FAILED: geom column exists despite suffix mismatch exception (rollback failed)';
    END IF;
END $$;

-- F4d: Table still pending (DELETE in step 5b.4 was rolled back with the exception)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4d PASSED: bantyp_l still pending after suffix mismatch exception (correctly rolled back)';
    ELSE
        RAISE WARNING 'TEST F4d FAILED: bantyp_l removed from pending despite exception – partial state';
    END IF;
END $$;

-- F4e: Now add the CORRECT geometry type (LineString for _l) → should succeed
DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.bantyp_l ADD COLUMN geom geometry(LineString, 3007);
    RAISE NOTICE 'TEST F4e PASSED: Correct geometry type (LineString for _l) accepted after previous failure';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F4e FAILED: Correct geometry type rejected: %', SQLERRM;
END $$;

-- F4f: Pending entry removed after correct ALTER TABLE
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4f PASSED: bantyp_l removed from pending after correct step B';
    ELSE
        RAISE WARNING 'TEST F4f FAILED: bantyp_l still pending after correct step B';
    END IF;
END $$;

-- F4g: GiST index created after recovery
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'bantyp_l'
        AND indexname = 'bantyp_l_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F4g PASSED: GiST index created after correct step B';
    ELSE
        RAISE WARNING 'TEST F4g FAILED: GiST index missing after correct step B';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.bantyp_l;

------------------------------------------------------------------------
-- F5: NON-SYSTEM USER STILL BLOCKED (REGRESSION GUARD)
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F5: Non-system user regression guard ---'

-- A regular user (no special application_name) must still get EXCEPTION
-- when trying to create a table with a geometry suffix but no geometry.
-- This ensures the deferred path is NOT an accidental bypass for everyone.
RESET application_name;

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.trick_l (
        data text
    );
    RAISE WARNING 'TEST F5a FAILED: Non-system user created a geometry-suffix table without geometry (bypass!)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%suffix%' OR SQLERRM LIKE '%geometri%' OR SQLERRM LIKE '%reserverade%' THEN
            RAISE NOTICE 'TEST F5a PASSED: Non-system user correctly blocked from geometry-suffix table without geom';
        ELSE
            RAISE NOTICE 'TEST F5a PASSED (different reason): %', left(SQLERRM, 80);
        END IF;
END $$;

-- F5b: Verify the table was NOT created (exception rolled back creation)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trick_l'
    ) THEN
        RAISE NOTICE 'TEST F5b PASSED: trick_l table does not exist (creation was rolled back)';
    ELSE
        RAISE WARNING 'TEST F5b FAILED: trick_l table exists despite exception';
    END IF;
END $$;

-- F5c: No stale pending entry created for the blocked table
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trick_l'
    ) THEN
        RAISE NOTICE 'TEST F5c PASSED: No pending entry for blocked table';
    ELSE
        RAISE WARNING 'TEST F5c FAILED: Stale pending entry created for blocked table';
    END IF;
END $$;

------------------------------------------------------------------------
-- F6: FME WITH GEOMETRY IN CREATE TABLE (NORMAL PATH, NO DEFERRAL)
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F6: FME normal path (geometry in CREATE TABLE) ---'

-- When FME includes geometry in CREATE TABLE, the deferred path must NOT fire.
-- The table goes through validera_tabell normally.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.komplett_import_p (
        objektid integer,
        namn     text,
        geom     geometry(Point, 3007)
    );
    RAISE NOTICE 'TEST F6a PASSED: FME table with geometry in CREATE TABLE accepted normally';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F6a FAILED: FME table with geometry rejected: %', SQLERRM;
END $$;

RESET application_name;

-- F6b: NOT in hex_afvaktande_geometri (deferred path must not have fired)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'komplett_import_p'
    ) THEN
        RAISE NOTICE 'TEST F6b PASSED: Table with geometry not registered as pending (correct)';
    ELSE
        RAISE WARNING 'TEST F6b FAILED: Table with geometry incorrectly registered as pending';
    END IF;
END $$;

-- F6c: GiST index created immediately (during CREATE TABLE, not deferred)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'komplett_import_p'
        AND indexname = 'komplett_import_p_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F6c PASSED: GiST index created immediately (normal path)';
    ELSE
        RAISE WARNING 'TEST F6c FAILED: GiST index missing after FME normal-path CREATE TABLE';
    END IF;
END $$;

-- F6d: gid present
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'komplett_import_p'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F6d PASSED: gid column present on FME normal-path table';
    ELSE
        RAISE WARNING 'TEST F6d FAILED: gid missing from FME normal-path table';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.komplett_import_p;

------------------------------------------------------------------------
-- F7: CUSTOM SYSTEM USER IN hex_systemanvandare
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F7: Custom system user ---'

-- Add a fictional system user to the registry
INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)
VALUES ('test_etl_tool', 'Testverktyg för FME-testsvitens F7-test')
ON CONFLICT DO NOTHING;

SET application_name = 'test_etl_tool';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.etl_import_l (
        rad_id integer,
        kalla  text
    );
    RAISE NOTICE 'TEST F7a PASSED: Custom system user got deferred treatment (table created without exception)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F7a FAILED: Custom system user not recognized or raised exception: %', SQLERRM;
END $$;

RESET application_name;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'etl_import_l'
    ) THEN
        RAISE NOTICE 'TEST F7b PASSED: Custom system user table registered as pending';
    ELSE
        RAISE WARNING 'TEST F7b FAILED: Custom system user table not registered as pending';
    END IF;
END $$;

-- Cleanup: complete the pending table, then remove the custom user
ALTER TABLE sk0_ext_fmetest.etl_import_l ADD COLUMN geom geometry(LineString, 3007);

DELETE FROM public.hex_systemanvandare WHERE anvandare = 'test_etl_tool';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hex_systemanvandare WHERE anvandare = 'test_etl_tool') THEN
        RAISE NOTICE 'TEST F7c PASSED: Custom system user removed from hex_systemanvandare';
    ELSE
        RAISE WARNING 'TEST F7c FAILED: Custom system user still present after deletion';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.etl_import_l;

------------------------------------------------------------------------
-- F8: MULTIPLE PENDING TABLES SIMULTANEOUSLY
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F8: Multiple pending tables simultaneously ---'

SET application_name = 'fme';

CREATE TABLE sk0_ext_fmetest.batch_a_p (id integer, naam text);
CREATE TABLE sk0_ext_fmetest.batch_b_y (id integer, info text);
CREATE TABLE sk0_ext_fmetest.batch_c_l (id integer, data text);

RESET application_name;

-- F8a: All three are pending
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn = 'sk0_ext_fmetest'
    AND ag.tabell_namn IN ('batch_a_p', 'batch_b_y', 'batch_c_l');
    IF cnt = 3 THEN
        RAISE NOTICE 'TEST F8a PASSED: All 3 batch tables registered as pending simultaneously';
    ELSE
        RAISE WARNING 'TEST F8a FAILED: Expected 3 pending entries, found %', cnt;
    END IF;
END $$;

-- F8b: Complete batch_a_p only → only batch_a_p removed from pending
ALTER TABLE sk0_ext_fmetest.batch_a_p ADD COLUMN geom geometry(Point, 3007);

DO $$
DECLARE
    a_pending boolean;
    b_pending boolean;
    c_pending boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_a_p') INTO a_pending;
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_b_y') INTO b_pending;
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_c_l') INTO c_pending;

    IF NOT a_pending AND b_pending AND c_pending THEN
        RAISE NOTICE 'TEST F8b PASSED: Only batch_a_p removed from pending; batch_b_y and batch_c_l still pending';
    ELSE
        RAISE WARNING 'TEST F8b FAILED: Pending state: a_p=% b_y=% c_l=% (expected false/true/true)',
            a_pending, b_pending, c_pending;
    END IF;
END $$;

-- F8c: Complete batch_b_y and batch_c_l
ALTER TABLE sk0_ext_fmetest.batch_b_y ADD COLUMN geom geometry(Polygon, 3007);
ALTER TABLE sk0_ext_fmetest.batch_c_l ADD COLUMN geom geometry(LineString, 3007);

DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn = 'sk0_ext_fmetest'
    AND ag.tabell_namn IN ('batch_a_p', 'batch_b_y', 'batch_c_l');
    IF cnt = 0 THEN
        RAISE NOTICE 'TEST F8c PASSED: All 3 batch tables removed from pending after step B';
    ELSE
        RAISE WARNING 'TEST F8c FAILED: % pending entries remain after completing all 3 tables', cnt;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.batch_a_p;
DROP TABLE IF EXISTS sk0_ext_fmetest.batch_b_y;
DROP TABLE IF EXISTS sk0_ext_fmetest.batch_c_l;

------------------------------------------------------------------------
-- F9: FME NON-GEOMETRY TABLE WITHOUT GEOMETRY SUFFIX
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F9: FME non-geometry table (no suffix, no deferral) ---'

-- FME can also write non-geometry tables. These have no geometry suffix so the
-- deferred path must NOT fire – they go through validera_tabell normally.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.referensdata (
        kod  text,
        namn text,
        typ  integer
    );
    RAISE NOTICE 'TEST F9a PASSED: FME non-geometry table (no suffix) created normally';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F9a FAILED: FME non-geometry table rejected: %', SQLERRM;
END $$;

RESET application_name;

-- F9b: NOT in hex_afvaktande_geometri (no suffix → no deferral)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'referensdata'
    ) THEN
        RAISE NOTICE 'TEST F9b PASSED: Non-geometry FME table not registered as pending (correct)';
    ELSE
        RAISE WARNING 'TEST F9b FAILED: Non-geometry FME table incorrectly registered as pending';
    END IF;
END $$;

-- F9c: gid added normally (table was restructured by normal path)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'referensdata'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F9c PASSED: FME non-geometry table restructured normally (gid present)';
    ELSE
        RAISE WARNING 'TEST F9c FAILED: FME non-geometry table not restructured (gid missing)';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.referensdata;

------------------------------------------------------------------------
-- F10: PARTIAL application_name DOES NOT TRIGGER DEFERRED PATH
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F10: Partial application_name not triggered ---'

-- application_name = 'FME Desktop 2024.0.0.0' does NOT match 'fme' in
-- hex_systemanvandare (exact lowercase match required). Such connections
-- get normal validation – no deferral bypass.
SET application_name = 'FME Desktop 2024.0.0.0';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.partial_match_l (data text);
    RAISE WARNING 'TEST F10a FAILED: Partial application_name triggered deferred bypass (unexpected)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST F10a PASSED: Partial application_name (''FME Desktop...'') correctly blocked – exact match required';
END $$;

RESET application_name;

-- F10b: No pending entry (deferred path was not triggered)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'partial_match_l'
    ) THEN
        RAISE NOTICE 'TEST F10b PASSED: No pending entry for partial-match connection (table blocked, not deferred)';
    ELSE
        RAISE WARNING 'TEST F10b FAILED: Pending entry created for partial-match connection';
    END IF;
END $$;

------------------------------------------------------------------------
-- F11: DROP TABLE ON PENDING TABLE
------------------------------------------------------------------------
\echo ''
\echo '--- GROUP F11: DROP TABLE on pending table ---'

SET application_name = 'fme';
CREATE TABLE sk0_ext_fmetest.abandoned_l (data text);
RESET application_name;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l'
    ) THEN
        RAISE NOTICE 'TEST F11 setup: abandoned_l registered as pending';
    ELSE
        RAISE WARNING 'TEST F11 setup FAILED: abandoned_l not pending – cannot run gap test';
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.abandoned_l;

-- After DROP TABLE the pending entry should be cleaned up by hantera_borttagen_tabell.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l'
    ) THEN
        RAISE WARNING 'TEST F11 GAP CONFIRMED: Pending entry for abandoned_l survives DROP TABLE. '
            'hantera_borttagen_tabell does not clean hex_afvaktande_geometri. '
            'Stale entries must be removed manually: '
            'DELETE FROM public.hex_afvaktande_geometri WHERE schema_namn = ''sk0_ext_fmetest'' AND tabell_namn = ''abandoned_l'';';
    ELSE
        RAISE NOTICE 'TEST F11 PASSED: Pending entry removed on DROP TABLE '
            '(hantera_borttagen_tabell cleans hex_afvaktande_geometri – gap resolved)';
    END IF;
END $$;

-- Manual cleanup for the gap case
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l';

------------------------------------------------------------------------
-- FINAL CLEANUP
------------------------------------------------------------------------
\echo ''
\echo '--- Final cleanup ---'

RESET application_name;

DROP SCHEMA IF EXISTS sk0_ext_fmetest     CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_fmetest CASCADE;

-- Defensive: remove any test pending entries that survived cleanup
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');

\echo ''
\echo '============================================================'
\echo 'HEX FME TWO-STEP TEST SUITE COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
\echo '============================================================'
