/******************************************************************************
 * REGRESSION TEST SUITE FOR HEX BUG FIXES
 *
 * Tests cover:
 *   1. Geometry validation applied to _kba_ schemas
 *   2. Spatial (GiST) indexes created for geometry tables
 *   3. Swedish characters (åäö) in table/schema names
 *   4. Schema validation error messages
 *   5. Non-geometry tables (regression check)
 *   6. DROP TABLE cleans up history tables and trigger functions
 *   7. Column order is clean after CREATE TABLE (no ordinal gaps)
 *   8. Standard columns are added correctly
 *   9. DROP SCHEMA cleans up roles
 *
 * PREREQUISITES:
 *   - Hex must be installed in the target database (all functions deployed)
 *   - PostGIS extension must be available
 *   - Run as a superuser or the Hex system owner
 *
 * USAGE:
 *   psql -d your_database -f test_regression.sql
 *   Or run the statements in PgAdmin query tool.
 *
 * The test cleans up after itself using DROP SCHEMA ... CASCADE at the end.
 * The test is idempotent - safe to run multiple times.
 ******************************************************************************/

\echo '============================================================'
\echo 'HEX REGRESSION TEST SUITE'
\echo '============================================================'

------------------------------------------------------------------------
-- INITIAL CLEANUP (idempotent - safe if schemas don't exist)
------------------------------------------------------------------------
\echo ''
\echo '--- Initial cleanup of previous test runs ---'
DROP SCHEMA IF EXISTS sk1_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_rolltest CASCADE;

------------------------------------------------------------------------
-- SETUP: Create test schemas
------------------------------------------------------------------------
\echo ''
\echo '--- Creating test schemas ---'
CREATE SCHEMA sk1_kba_test;
CREATE SCHEMA sk0_ext_test;

------------------------------------------------------------------------
-- TEST 1: Geometry validation is applied to _kba_ schemas
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 1: Geometry validation on _kba_ schemas ---'

-- Create a geometry table in _kba_ schema
CREATE TABLE sk1_kba_test.test_validering_y (
    namn text,
    geom geometry(Polygon, 3007)
);

-- Verify CHECK constraint exists
DO $$
DECLARE
    constraint_count integer;
BEGIN
    SELECT COUNT(*) INTO constraint_count
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'sk1_kba_test'
    AND c.conname LIKE 'validera_geom_%'
    AND c.contype = 'c';

    IF constraint_count > 0 THEN
        RAISE NOTICE 'TEST 1a PASSED: Geometry validation constraint found on _kba_ table';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: No geometry validation constraint on _kba_ table';
    END IF;
END $$;

-- Verify invalid geometry is blocked (empty geometry)
DO $$
BEGIN
    INSERT INTO sk1_kba_test.test_validering_y (namn, geom)
    VALUES ('tom', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST 1b FAILED: Empty geometry was accepted (should be blocked)';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'TEST 1b PASSED: Empty geometry correctly blocked by CHECK constraint';
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk1_kba_test.test_validering_y;

------------------------------------------------------------------------
-- TEST 2: Spatial (GiST) indexes are created
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 2: Spatial GiST index creation ---'

CREATE TABLE sk0_ext_test.test_index_y (
    data text,
    geom geometry(Polygon, 3007)
);

-- Verify GiST index exists
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'test_index_y'
    AND indexname = 'test_index_y_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 2a PASSED: GiST index created on ext schema table';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: GiST index NOT found on ext schema table';
    END IF;
END $$;

-- Also verify GiST index on _kba_ schema table
CREATE TABLE sk1_kba_test.test_index_p (
    data text,
    geom geometry(Point, 3007)
);

DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk1_kba_test'
    AND tablename = 'test_index_p'
    AND indexname = 'test_index_p_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 2b PASSED: GiST index created on kba schema table';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: GiST index NOT found on kba schema table';
    END IF;
END $$;

-- Verify NO constraint on ext table (only _kba_ should have validation)
DO $$
DECLARE
    constraint_count integer;
BEGIN
    SELECT COUNT(*) INTO constraint_count
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'sk0_ext_test'
    AND c.conname LIKE 'validera_geom_%'
    AND c.contype = 'c';

    IF constraint_count = 0 THEN
        RAISE NOTICE 'TEST 2c PASSED: No geometry validation on ext schema (correct)';
    ELSE
        RAISE WARNING 'TEST 2c FAILED: Geometry validation unexpectedly on ext schema';
    END IF;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk0_ext_test.test_index_y;
DROP TABLE IF EXISTS sk1_kba_test.test_index_p;

------------------------------------------------------------------------
-- TEST 3: Swedish characters (åäö) in table names
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 3: Swedish character support ---'

-- Test table with Swedish characters
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.rör_l (
        diameter integer,
        geom geometry(LineString, 3007)
    );
    RAISE NOTICE 'TEST 3a PASSED: Table with Swedish chars (rör_l) created successfully';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3a FAILED: Could not create table with Swedish chars: %', SQLERRM;
END $$;

-- Verify the table was restructured (has gid column)
DO $$
DECLARE
    has_gid boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'rör_l'
        AND column_name = 'gid'
    ) INTO has_gid;

    IF has_gid THEN
        RAISE NOTICE 'TEST 3b PASSED: Swedish char table has standard gid column';
    ELSE
        RAISE WARNING 'TEST 3b FAILED: Swedish char table missing gid column';
    END IF;
END $$;

-- Verify GiST index on Swedish char table
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'rör_l'
    AND indexname = 'rör_l_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 3c PASSED: GiST index created on Swedish char table';
    ELSE
        RAISE WARNING 'TEST 3c FAILED: GiST index NOT found on Swedish char table';
    END IF;
END $$;

-- Test more Swedish character names
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.vägar_l (
        bredd numeric,
        geom geometry(LineString, 3007)
    );
    RAISE NOTICE 'TEST 3d PASSED: Table vägar_l created successfully';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3d FAILED: Could not create table vägar_l: %', SQLERRM;
END $$;

DO $$
BEGIN
    CREATE TABLE sk0_ext_test.åkrar_y (
        areal numeric,
        geom geometry(Polygon, 3007)
    );
    RAISE NOTICE 'TEST 3e PASSED: Table åkrar_y created successfully';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3e FAILED: Could not create table åkrar_y: %', SQLERRM;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk0_ext_test.rör_l;
DROP TABLE IF EXISTS sk0_ext_test.vägar_l;
DROP TABLE IF EXISTS sk0_ext_test.åkrar_y;

------------------------------------------------------------------------
-- TEST 4: Schema validation error messages
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 4: Schema validation error messages ---'

-- Test that invalid schema name is rejected with helpful message
DO $$
BEGIN
    CREATE SCHEMA invalid_schema_name;
    RAISE WARNING 'TEST 4a FAILED: Invalid schema name was accepted';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%validera_schemanamn%' AND SQLERRM LIKE '%sk[0-2]%' THEN
            RAISE NOTICE 'TEST 4a PASSED: Invalid schema rejected with helpful error';
        ELSE
            RAISE WARNING 'TEST 4a PARTIAL: Schema rejected but message unclear: %', SQLERRM;
        END IF;
END $$;

------------------------------------------------------------------------
-- TEST 5: Tables without geometry still work (no regression)
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 5: Non-geometry tables (regression check) ---'

DO $$
BEGIN
    CREATE TABLE sk0_ext_test.metadata (
        nyckel text,
        varde text
    );
    RAISE NOTICE 'TEST 5a PASSED: Non-geometry table created successfully';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 5a FAILED: Could not create non-geometry table: %', SQLERRM;
END $$;

-- Verify no GiST index on non-geometry table
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'metadata'
    AND indexdef LIKE '%GIST%';

    IF index_count = 0 THEN
        RAISE NOTICE 'TEST 5b PASSED: No GiST index on non-geometry table (correct)';
    ELSE
        RAISE WARNING 'TEST 5b FAILED: Unexpected GiST index on non-geometry table';
    END IF;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk0_ext_test.metadata;

------------------------------------------------------------------------
-- TEST 6: DROP TABLE cleans up history tables and trigger functions
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 6: DROP TABLE history cleanup ---'

-- Create a _kba_ table that will get a history table
CREATE TABLE sk1_kba_test.historiktest_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- Verify history table was created
DO $$
DECLARE
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'historiktest_y_h'
    ) INTO has_history;

    IF has_history THEN
        RAISE NOTICE 'TEST 6a PASSED: History table created for _kba_ table';
    ELSE
        RAISE WARNING 'TEST 6a FAILED: No history table created for _kba_ table';
    END IF;
END $$;

-- Verify trigger function was created
DO $$
DECLARE
    has_trigger_fn boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'sk1_kba_test'
        AND p.proname = 'trg_fn_historiktest_y_qa'
    ) INTO has_trigger_fn;

    IF has_trigger_fn THEN
        RAISE NOTICE 'TEST 6b PASSED: QA trigger function created for _kba_ table';
    ELSE
        RAISE WARNING 'TEST 6b FAILED: No QA trigger function created for _kba_ table';
    END IF;
END $$;

-- Now DROP the main table - this should cascade to history + trigger function
DROP TABLE sk1_kba_test.historiktest_y;

-- Verify history table was removed
DO $$
DECLARE
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'historiktest_y_h'
    ) INTO has_history;

    IF NOT has_history THEN
        RAISE NOTICE 'TEST 6c PASSED: History table removed when main table dropped';
    ELSE
        RAISE WARNING 'TEST 6c FAILED: History table still exists after main table dropped';
    END IF;
END $$;

-- Verify trigger function was removed
DO $$
DECLARE
    has_trigger_fn boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'sk1_kba_test'
        AND p.proname = 'trg_fn_historiktest_y_qa'
    ) INTO has_trigger_fn;

    IF NOT has_trigger_fn THEN
        RAISE NOTICE 'TEST 6d PASSED: QA trigger function removed when main table dropped';
    ELSE
        RAISE WARNING 'TEST 6d FAILED: QA trigger function still exists after main table dropped';
    END IF;
END $$;

-- Test that table restructuring still works (DROP TABLE during byt_ut_tabell
-- should NOT cascade to history because of the recursion guard)
CREATE TABLE sk1_kba_test.omstrukt_test_y (
    data text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE
    has_gid boolean;
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'omstrukt_test_y'
        AND column_name = 'gid'
    ) INTO has_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'omstrukt_test_y_h'
    ) INTO has_history;

    IF has_gid AND has_history THEN
        RAISE NOTICE 'TEST 6e PASSED: Table restructuring still works with DROP TABLE trigger active';
    ELSIF NOT has_gid THEN
        RAISE WARNING 'TEST 6e FAILED: Table not restructured (missing gid)';
    ELSE
        RAISE WARNING 'TEST 6e FAILED: History table not created during restructuring';
    END IF;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk1_kba_test.omstrukt_test_y;

------------------------------------------------------------------------
-- TEST 7: Column order is clean (no ordinal position gaps)
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 7: Column order after CREATE TABLE ---'

CREATE TABLE sk1_kba_test.kolumnordning_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- If hantera_kolumntillagg fires during CREATE TABLE, columns get dropped
-- and re-added, causing gaps in ordinal_position (e.g. 1,2,13,14,15,16,17).
-- With the fix, max(ordinal_position) should equal count(*).
DO $$
DECLARE
    col_count integer;
    max_pos integer;
BEGIN
    SELECT COUNT(*), MAX(ordinal_position)
    INTO col_count, max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk1_kba_test'
    AND table_name = 'kolumnordning_y';

    IF col_count = max_pos THEN
        RAISE NOTICE 'TEST 7a PASSED: Column positions are sequential (% columns, max position %)', col_count, max_pos;
    ELSE
        RAISE WARNING 'TEST 7a FAILED: Column position gaps detected (% columns but max position %)', col_count, max_pos;
    END IF;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk1_kba_test.kolumnordning_y;

------------------------------------------------------------------------
-- TEST 8: Standard columns are added correctly
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 8: Standard columns ---'

CREATE TABLE sk0_ext_test.standardkol_y (
    data text,
    geom geometry(Polygon, 3007)
);

-- Verify all expected standard columns exist
DO $$
DECLARE
    missing text[];
BEGIN
    SELECT array_agg(expected) INTO missing
    FROM unnest(ARRAY['gid', 'skapad_tidpunkt', 'skapad_av', 'andrad_tidpunkt', 'andrad_av']) AS expected
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'standardkol_y'
        AND column_name = expected
    );

    IF missing IS NULL THEN
        RAISE NOTICE 'TEST 8a PASSED: All standard columns present';
    ELSE
        RAISE WARNING 'TEST 8a FAILED: Missing standard columns: %', array_to_string(missing, ', ');
    END IF;
END $$;

-- Verify gid is first column
DO $$
DECLARE
    gid_pos integer;
BEGIN
    SELECT ordinal_position INTO gid_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y'
    AND column_name = 'gid';

    IF gid_pos = 1 THEN
        RAISE NOTICE 'TEST 8b PASSED: gid is first column (position 1)';
    ELSE
        RAISE WARNING 'TEST 8b FAILED: gid at position % (expected 1)', gid_pos;
    END IF;
END $$;

-- Verify geom is last column
DO $$
DECLARE
    geom_pos integer;
    max_pos integer;
BEGIN
    SELECT ordinal_position INTO geom_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y';

    IF geom_pos = max_pos THEN
        RAISE NOTICE 'TEST 8c PASSED: geom is last column (position %)', geom_pos;
    ELSE
        RAISE WARNING 'TEST 8c FAILED: geom at position % but max is %', geom_pos, max_pos;
    END IF;
END $$;

-- Cleanup
DROP TABLE IF EXISTS sk0_ext_test.standardkol_y;

------------------------------------------------------------------------
-- TEST 9: DROP SCHEMA cleans up roles
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 9: DROP SCHEMA role cleanup ---'

-- Use sk2_ext schema to test both w_{schema} and r_{schema} role creation
DROP SCHEMA IF EXISTS sk2_ext_rolltest CASCADE;
CREATE SCHEMA sk2_ext_rolltest;

-- Verify write role was created (w_{schema} matches all schemas)
DO $$
DECLARE
    has_role boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'w_sk2_ext_rolltest') INTO has_role;

    IF has_role THEN
        RAISE NOTICE 'TEST 9a PASSED: Write role w_sk2_ext_rolltest created on schema creation';
    ELSE
        RAISE WARNING 'TEST 9a FAILED: Write role w_sk2_ext_rolltest not created';
    END IF;
END $$;

-- Verify read role was created (r_{schema} matches sk2_%)
DO $$
DECLARE
    has_role boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_rolltest') INTO has_role;

    IF has_role THEN
        RAISE NOTICE 'TEST 9b PASSED: Read role r_sk2_ext_rolltest created on schema creation';
    ELSE
        RAISE WARNING 'TEST 9b FAILED: Read role r_sk2_ext_rolltest not created';
    END IF;
END $$;

-- Drop the schema - roles should be cleaned up
DROP SCHEMA sk2_ext_rolltest CASCADE;

-- Verify write role was removed
DO $$
DECLARE
    has_role boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'w_sk2_ext_rolltest') INTO has_role;

    IF NOT has_role THEN
        RAISE NOTICE 'TEST 9c PASSED: Write role removed on DROP SCHEMA';
    ELSE
        RAISE WARNING 'TEST 9c FAILED: Write role w_sk2_ext_rolltest still exists after DROP SCHEMA';
    END IF;
END $$;

-- Verify read role was removed
DO $$
DECLARE
    has_role boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_rolltest') INTO has_role;

    IF NOT has_role THEN
        RAISE NOTICE 'TEST 9d PASSED: Read role removed on DROP SCHEMA';
    ELSE
        RAISE WARNING 'TEST 9d FAILED: Read role r_sk2_ext_rolltest still exists after DROP SCHEMA';
    END IF;
END $$;

------------------------------------------------------------------------
-- FINAL CLEANUP
------------------------------------------------------------------------
\echo ''
\echo '--- Cleaning up test schemas ---'
DROP SCHEMA IF EXISTS sk1_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_test CASCADE;

\echo ''
\echo '============================================================'
\echo 'REGRESSION TEST SUITE COMPLETE'
\echo 'Review NOTICE/WARNING messages above for results.'
\echo 'NOTICE = PASSED, WARNING = FAILED'
\echo '============================================================'
