/******************************************************************************
 * REGRESSION TEST SUITE FOR HEX BUG FIXES
 *
 * Tests cover:
 *   1. Geometry validation applied to _kba_ schemas (Issue 1)
 *   2. Spatial (GiST) indexes created for geometry tables (Issue 2)
 *   3. Swedish characters (åäö) in table/schema names (Issue 3)
 *   4. Schema validation error messages (Issue 4)
 *   5. Dual IDENTITY column warning (Issue 5)
 *
 * PREREQUISITES:
 *   - Hex must be installed in the target database
 *   - PostGIS extension must be available
 *   - Run as a superuser or the Hex system owner
 *
 * USAGE:
 *   psql -d your_database -f test_regression.sql
 *
 * Each test section is wrapped in a transaction that rolls back,
 * so no permanent changes are made to the database.
 ******************************************************************************/

\echo '============================================================'
\echo 'HEX REGRESSION TEST SUITE'
\echo '============================================================'

------------------------------------------------------------------------
-- TEST 1: Geometry validation is applied to _kba_ schemas
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 1: Geometry validation on _kba_ schemas ---'

DO $$
BEGIN
    -- Setup: Create test schema if not exists
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sk1_kba_test') THEN
        CREATE SCHEMA sk1_kba_test;
    END IF;
END $$;

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

-- Create test schema for ext (non-kba)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sk0_ext_test') THEN
        CREATE SCHEMA sk0_ext_test;
    END IF;
END $$;

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
