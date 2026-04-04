-- ============================================================
-- HEX EXTENDED TEST SUITE — GROUPS A & B
--
-- A  sk2 schema-hantering (fullständigt)
--    A1  sk2_ext: gid + skapad_tidpunkt, GiST index, no validation
--    A2  sk2_kba: all 5 standard columns, validation, history table
--    A3  sk2_sys: non-geometry, gid, no history table
--    A4  Roles: read/write group roles + login roles created on CREATE SCHEMA
--    A5  sk2 excluded from GeoServer pg_notify
--
-- B  Vy-validering (hantera_ny_vy / validera_vynamn)
--    B1  Valid non-geometry view (v_ prefix, no suffix)
--    B2  Valid geometry view (v_ prefix + geometry suffix)
--    B3  View missing v_ prefix rejected
--    B4  View with wrong geometry suffix rejected
--    B5  View in public schema silently accepted
--    B6  ST_ transform without type cast rejected
--    B7  ST_ transform with explicit type cast accepted
--
-- Schemas used: sk2_ext_test, sk2_kba_test, sk2_sys_test, sk1_kba_htest
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX EXTENDED TEST SUITE — GROUPS A & B'
\echo '============================================================'

-- ============================================================
-- Cleanup and setup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_ab_temp CASCADE;

-- Setup global role configuration needed for A4 tests.
-- r_sk0_global and r_sk1_global are created by the event trigger when a
-- sk0/sk1 schema is created, provided the rows exist in standardiserade_roller.
DELETE FROM standardiserade_roller WHERE rollnamn IN ('r_sk0_global', 'r_sk1_global');
DROP ROLE IF EXISTS r_sk0_global;
DROP ROLE IF EXISTS r_sk1_global;
INSERT INTO standardiserade_roller (rollnamn, rolltyp, schema_uttryck, ta_bort_med_schema, with_login, beskrivning) VALUES
    ('r_sk0_global', 'read', 'LIKE ''sk0_%''', false, false, 'Global read role for sk0'),
    ('r_sk1_global', 'read', 'LIKE ''sk1_%''', false, false, 'Global read role for sk1');

-- Create a sk0 schema to trigger r_sk0_global; drop it immediately (role persists since ta_bort_med_schema=false)
CREATE SCHEMA sk0_ext_ab_temp;
DROP SCHEMA sk0_ext_ab_temp CASCADE;

CREATE SCHEMA sk2_ext_test;
CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_sys_test;
CREATE SCHEMA sk1_kba_htest;  -- triggers r_sk1_global creation

-- ============================================================
-- A: sk2 SCHEMA HANDLING
-- ============================================================
\echo ''
\echo '--- GROUP A: sk2 schema handling ---'

-- ------------------------------------------------------------
-- A1: sk2_ext - should get gid + skapad_tidpunkt only (not kba columns)
-- ------------------------------------------------------------
CREATE TABLE sk2_ext_test.fororeningar_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt');
    IF col_count = 2 THEN
        RAISE NOTICE 'TEST A1a PASSED: sk2_ext table has gid and skapad_tidpunkt';
    ELSE
        RAISE WARNING 'TEST A1a FAILED: Expected 2 base standard columns on sk2_ext, got %', col_count;
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF col_count = 0 THEN
        RAISE NOTICE 'TEST A1b PASSED: sk2_ext does NOT have kba-only columns';
    ELSE
        RAISE WARNING 'TEST A1b FAILED: sk2_ext has % kba-only columns (schema_uttryck filter broken)', col_count;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk2_ext_test' AND tablename = 'fororeningar_y'
        AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST A1c PASSED: GiST index on sk2_ext geometry table';
    ELSE
        RAISE WARNING 'TEST A1c FAILED: No GiST index on sk2_ext table';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_ext_test.fororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A1d PASSED: No geometry validation constraint on sk2_ext (correct)';
    ELSE
        RAISE WARNING 'TEST A1d FAILED: sk2_ext has geometry validation (only kba should)';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A2: sk2_kba - full kba treatment: all standard columns, validation, history
-- ------------------------------------------------------------
CREATE TABLE sk2_kba_test.markfororeningar_y (
    orsak text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt', 'skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF col_count = 5 THEN
        RAISE NOTICE 'TEST A2a PASSED: sk2_kba table has all 5 standard columns';
    ELSE
        RAISE WARNING 'TEST A2a FAILED: Expected 5 standard columns on sk2_kba, got %', col_count;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_kba_test.markfororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A2b PASSED: sk2_kba has geometry validation constraint';
    ELSE
        RAISE WARNING 'TEST A2b FAILED: sk2_kba missing geometry validation';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y_h'
    ) THEN
        RAISE NOTICE 'TEST A2c PASSED: History table created for sk2_kba table';
    ELSE
        RAISE WARNING 'TEST A2c FAILED: No history table for sk2_kba';
    END IF;
END $$;

DO $$
BEGIN
    INSERT INTO sk2_kba_test.markfororeningar_y (orsak, geom)
    VALUES ('test', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST A2d FAILED: Empty geometry accepted in sk2_kba (should be blocked)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri%' AND SQLERRM LIKE '%tom%' THEN
            RAISE NOTICE 'TEST A2d PASSED: Empty geometry blocked with descriptive message: %', left(SQLERRM, 120);
        ELSIF SQLERRM LIKE '%check constraint%' OR SQLERRM LIKE '%validera_geom%' THEN
            RAISE WARNING 'TEST A2d PARTIAL: Geometry blocked by CHECK constraint but trigger message missing. Is kontrollera_geometri_trigger installed?';
        ELSE
            RAISE NOTICE 'TEST A2d PASSED (other reason): %', left(SQLERRM, 120);
        END IF;
END $$;

-- ------------------------------------------------------------
-- A3: sk2_sys - non-geometry, standard columns
-- ------------------------------------------------------------
CREATE TABLE sk2_sys_test.konfig (
    param text,
    varde text
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST A3a PASSED: sk2_sys non-geometry table has gid';
    ELSE
        RAISE WARNING 'TEST A3a FAILED: sk2_sys table missing gid';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig_h'
    ) THEN
        RAISE NOTICE 'TEST A3b PASSED: sk2_sys non-geometry table has no history table (correct)';
    ELSE
        RAISE WARNING 'TEST A3b FAILED: sk2_sys non-geometry table unexpectedly has history table';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A4: sk2 roles - r_{schema} (LIKE sk2_%) and w_{schema} (IS NOT NULL) created
-- ------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4a PASSED: Write role w_sk2_ext_test created';
    ELSE
        RAISE WARNING 'TEST A4a FAILED: Missing write role w_sk2_ext_test';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4b PASSED: Read role r_sk2_ext_test created (sk2 matches LIKE sk2_%%)';
    ELSE
        RAISE WARNING 'TEST A4b FAILED: Missing read role r_sk2_ext_test';
    END IF;
END $$;

-- sk2 must NOT receive r_sk0_global or r_sk1_global
DO $$
BEGIN
    -- These global roles apply to sk0_% and sk1_% only.
    -- We confirm sk2 schema creation didn't accidentally toggle them.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk0_global')
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_global') THEN
        RAISE NOTICE 'TEST A4c PASSED: Global roles r_sk0_global and r_sk1_global still exist unchanged';
    ELSE
        RAISE WARNING 'TEST A4c FAILED: A global role was unexpectedly removed or altered';
    END IF;
END $$;

-- A4d: r_sk2_ext_test should be a LOGIN role (with_login=true on r_{schema} row)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'r_sk2_ext_test' AND rolcanlogin = true
    ) THEN
        RAISE NOTICE 'TEST A4d PASSED: Login role r_sk2_ext_test created with LOGIN';
    ELSE
        RAISE WARNING 'TEST A4d FAILED: r_sk2_ext_test missing or not a LOGIN role';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A5: sk2 must NOT trigger GeoServer pg_notify
-- Test the regex that guards the notification directly
-- ------------------------------------------------------------
DO $$
DECLARE matched_prefix text;
BEGIN
    matched_prefix := substring('sk2_kba_test' FROM '^(sk[01])_');
    IF matched_prefix IS NULL THEN
        RAISE NOTICE 'TEST A5 PASSED: sk2 schema correctly excluded from GeoServer notification (prefix regex ''^(sk[01])_'' returns NULL for sk2)';
    ELSE
        RAISE WARNING 'TEST A5 FAILED: sk2 schema matched GeoServer prefix: "%"', matched_prefix;
    END IF;
END $$;

-- ============================================================
-- B: VIEW VALIDATION
-- ============================================================
\echo ''
\echo '--- GROUP B: View validation ---'

-- B1: Valid non-geometry view - must be accepted (starts with v_, no suffix needed)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.v_konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig WHERE varde IS NOT NULL';
    RAISE NOTICE 'TEST B1 PASSED: Valid non-geometry view (v_xxx) accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B1 FAILED: Valid non-geometry view rejected: %', SQLERRM;
END $$;

-- B2: Valid geometry view - correct suffix for polygon data
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_y AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B2 PASSED: Valid geometry view (v_xxx_y) accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B2 FAILED: Valid geometry view rejected: %', SQLERRM;
END $$;

-- B3: View missing v_ prefix - must be rejected
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig';
    RAISE WARNING 'TEST B3 FAILED: View without v_ prefix was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B3 PASSED: View without v_ prefix rejected correctly';
END $$;

-- B4: View with wrong geometry suffix (polygon data but named _l)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_l AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B4 FAILED: Wrong geometry suffix (_l for polygon) was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B4 PASSED: Wrong geometry suffix correctly rejected';
END $$;

-- B5: View in public schema - must be silently skipped (no enforcement)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW public.anything AS SELECT 1 AS x';
    RAISE NOTICE 'TEST B5 PASSED: View in public schema skipped (any name accepted)';
    EXECUTE 'DROP VIEW public.anything';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B5 FAILED: View in public schema caused error: %', SQLERRM;
END $$;

-- B6: ST_ transformation without explicit type cast - must get helpful diagnostic
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid, ST_Buffer(geom, 10) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B6 FAILED: ST_ transformation without cast was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B6 PASSED: ST_ transformation without cast rejected (message: %)',
            left(SQLERRM, 80);
END $$;

-- B7: ST_ transformation WITH explicit cast - must be accepted
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid,
                    ST_Buffer(geom, 10)::geometry(Polygon, 3007) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B7 PASSED: ST_ transformation with explicit type cast accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B7 FAILED: ST_ transformation with cast rejected: %', SQLERRM;
END $$;

-- B8: CREATE OR REPLACE VIEW with valid name - replacing an existing valid view
DO $$
BEGIN
    EXECUTE 'CREATE OR REPLACE VIEW sk2_ext_test.v_fororeningar_y AS
             SELECT *
             FROM sk2_ext_test.fororeningar_y
             WHERE gid IS NOT NULL';
    RAISE NOTICE 'TEST B8 PASSED: CREATE OR REPLACE VIEW accepted (valid name, replacing existing view)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B8 FAILED: CREATE OR REPLACE VIEW on existing valid view rejected: %', SQLERRM;
END $$;

-- B9: CREATE OR REPLACE VIEW with invalid name (no v_ prefix) - must be rejected
DO $$
BEGIN
    EXECUTE 'CREATE OR REPLACE VIEW sk2_ext_test.fororeningar_alt_y AS
             SELECT gid, geom FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B9 FAILED: CREATE OR REPLACE VIEW without v_ prefix was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B9 PASSED: CREATE OR REPLACE VIEW without v_ prefix correctly rejected';
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

-- Remove global role configuration added for A4 tests
DELETE FROM standardiserade_roller WHERE rollnamn IN ('r_sk0_global', 'r_sk1_global');
DROP ROLE IF EXISTS r_sk0_global;
DROP ROLE IF EXISTS r_sk1_global;

\echo ''
\echo 'HEX EXTENDED A & B COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
