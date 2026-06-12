-- ============================================================
-- TEST: Role permission grants on w_ and r_ roles
--
-- Verifies that tilldela_rollrattigheter() correctly grants:
--   r_ roles: USAGE on schema, SELECT on tables (+ default privs)
--   w_ roles: USAGE on schema, SELECT/INSERT/UPDATE/DELETE on tables,
--             USAGE+SELECT on sequences (+ default privs for both)
--
-- Schema used: sk1_kba_permtest
-- Konvention: NOTICE = PASSED, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: Role permission grants (r_ and w_ roles)'
\echo '============================================================'

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_permtest CASCADE;
DROP ROLE IF EXISTS r_sk1_kba_permtest;
DROP ROLE IF EXISTS w_sk1_kba_permtest;

-- ============================================================
-- Setup: CREATE SCHEMA triggers hantera_standardiserade_roller,
-- which calls tilldela_rollrattigheter for each role.
-- ============================================================
CREATE SCHEMA sk1_kba_permtest;

-- Let Hex add standard columns via the event trigger (no gid declared).
-- Use a sk1_kba schema + _y suffix so Hex fully processes the table.
CREATE TABLE sk1_kba_permtest.testobj_y (
    namn text,
    geom geometry(Polygon, 3007)
);

-- ============================================================
-- Verify roles were created
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_kba_permtest') THEN
        RAISE NOTICE 'SETUP: r_sk1_kba_permtest exists';
    ELSE
        RAISE WARNING 'SETUP FAILED: r_sk1_kba_permtest missing — event trigger may not have fired';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_permtest') THEN
        RAISE NOTICE 'SETUP: w_sk1_kba_permtest exists';
    ELSE
        RAISE WARNING 'SETUP FAILED: w_sk1_kba_permtest missing — event trigger may not have fired';
    END IF;
END $$;

-- ============================================================
-- R_ ROLE TESTS
-- ============================================================
\echo ''
\echo '--- r_ role (read) ---'

-- R1: USAGE on schema
DO $$
BEGIN
    IF has_schema_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest', 'USAGE') THEN
        RAISE NOTICE 'TEST R1 PASSED: r_ has USAGE on schema';
    ELSE
        RAISE WARNING 'TEST R1 FAILED: r_ missing USAGE on schema sk1_kba_permtest';
    END IF;
END $$;

-- R2: SELECT on existing table
DO $$
BEGIN
    IF has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'SELECT') THEN
        RAISE NOTICE 'TEST R2 PASSED: r_ has SELECT on existing table';
    ELSE
        RAISE WARNING 'TEST R2 FAILED: r_ missing SELECT on sk1_kba_permtest.testobj_y';
    END IF;
END $$;

-- R3: no INSERT (read-only sanity check)
DO $$
BEGIN
    IF NOT has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'INSERT') THEN
        RAISE NOTICE 'TEST R3 PASSED: r_ correctly has no INSERT on table';
    ELSE
        RAISE WARNING 'TEST R3 FAILED: r_ has INSERT — should be read-only';
    END IF;
END $$;

-- R4: no USAGE on sequence (read roles don't need to call nextval)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST R4 SKIPPED: no sequence found in sk1_kba_permtest';
        RETURN;
    END IF;

    IF NOT has_sequence_privilege('r_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST R4 PASSED: r_ has no USAGE on sequence (correct for read-only)';
    ELSE
        RAISE WARNING 'TEST R4 NOTE: r_ has USAGE on sequence (unexpected but not blocking)';
    END IF;
END $$;

-- R5: DEFAULT PRIVILEGES — create a second table AFTER role setup, verify SELECT propagates
CREATE TABLE sk1_kba_permtest.testobjb_p (
    kod text,
    geom geometry(Point, 3007)
);

DO $$
BEGIN
    IF has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobjb_p', 'SELECT') THEN
        RAISE NOTICE 'TEST R5 PASSED: r_ has SELECT on table created after role setup (DEFAULT PRIVILEGES work)';
    ELSE
        RAISE WARNING 'TEST R5 FAILED: r_ missing SELECT on testobjb_p — DEFAULT PRIVILEGES not working';
    END IF;
END $$;

-- ============================================================
-- W_ ROLE TESTS
-- ============================================================
\echo ''
\echo '--- w_ role (write) ---'

-- W1: USAGE on schema
DO $$
BEGIN
    IF has_schema_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest', 'USAGE') THEN
        RAISE NOTICE 'TEST W1 PASSED: w_ has USAGE on schema';
    ELSE
        RAISE WARNING 'TEST W1 FAILED: w_ missing USAGE on schema sk1_kba_permtest';
    END IF;
END $$;

-- W2: SELECT, INSERT, UPDATE, DELETE on existing table
DO $$
DECLARE missing text := '';
BEGIN
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'SELECT') THEN missing := missing || 'SELECT '; END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'INSERT') THEN missing := missing || 'INSERT '; END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'UPDATE') THEN missing := missing || 'UPDATE '; END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'DELETE') THEN missing := missing || 'DELETE '; END IF;

    IF missing = '' THEN
        RAISE NOTICE 'TEST W2 PASSED: w_ has SELECT/INSERT/UPDATE/DELETE on existing table';
    ELSE
        RAISE WARNING 'TEST W2 FAILED: w_ missing [%] on testobj_y', missing;
    END IF;
END $$;

-- W3: USAGE on sequence — the core fix (INSERT with identity column requires this)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    ORDER BY s.relname LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE WARNING 'TEST W3 SKIPPED: no sequence found in sk1_kba_permtest';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST W3 PASSED: w_ has USAGE on sequence % (INSERT on identity columns will work)', seq_name;
    ELSE
        RAISE WARNING 'TEST W3 FAILED: w_ missing USAGE on sequence % — INSERT will fail', seq_name;
    END IF;
END $$;

-- W4: SELECT on sequence
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    ORDER BY s.relname LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST W4 SKIPPED: no sequence found';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'SELECT') THEN
        RAISE NOTICE 'TEST W4 PASSED: w_ has SELECT on sequence %', seq_name;
    ELSE
        RAISE WARNING 'TEST W4 FAILED: w_ missing SELECT on sequence %', seq_name;
    END IF;
END $$;

-- W5: DEFAULT PRIVILEGES on tables — INSERT on table created after role setup
DO $$
BEGIN
    IF has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobjb_p', 'INSERT') THEN
        RAISE NOTICE 'TEST W5 PASSED: w_ has INSERT on table created after role setup (DEFAULT PRIVILEGES on tables work)';
    ELSE
        RAISE WARNING 'TEST W5 FAILED: w_ missing INSERT on testobjb_p — DEFAULT PRIVILEGES on tables not working';
    END IF;
END $$;

-- W6: DEFAULT PRIVILEGES on sequences — USAGE on sequence from testobjb_p (created after role setup)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a', 'i')
    JOIN pg_class t ON t.oid = d.refobjid
    WHERE n.nspname = 'sk1_kba_permtest'
      AND s.relkind = 'S'
      AND t.relname = 'testobjb_p'
    LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST W6 SKIPPED: no sequence linked to testobjb_p found';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST W6 PASSED: w_ has USAGE on sequence % of table created after role setup (DEFAULT PRIVILEGES on sequences work)', seq_name;
    ELSE
        RAISE WARNING 'TEST W6 FAILED: w_ missing USAGE on sequence % — DEFAULT PRIVILEGES on sequences not working', seq_name;
    END IF;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
\echo ''
\echo '--- Cleanup ---'
DROP SCHEMA sk1_kba_permtest CASCADE;

\echo ''
\echo '============================================================'
\echo 'Role permission tests complete.'
\echo '============================================================'
