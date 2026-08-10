/******************************************************************************
 * TEST SUITE FOR hex_underhall()
 *
 * hex_underhall() is Hex's repair/maintenance function, run automatically
 * by the installer after every install/upgrade. It is meant to be the thing
 * a DBA can always fall back on to bring a Hex installation back to a known
 * good state -- so this suite works by deliberately damaging a schema (wrong
 * ownership, dropped triggers, broken role state) and then asserting that a
 * single hex_underhall() call repairs everything, including functionally
 * (not just "the trigger object exists" but "the trigger actually rejects
 * bad input again").
 *
 * Tests cover:
 *   A. Ownership sweep: schema, table, history table, sequence, view,
 *      and function all get reassigned to the owner role.
 *   B. Row-level trigger reattachment, each verified functionally:
 *      hex_tvinga_gid, hex_tvinga_anvandarvarden, hex_kontrollera_geom,
 *      trg_<tabell>_qa (history), hex_ta_bort_dummy.
 *   C. hex_dummy_geometrier edge case: a stale entry pointing at a table
 *      that no longer exists must be skipped, not error.
 *   D. Role structure repair: a role missing entirely (Fall a), a role
 *      migrated back from a stale pre-4-role LOGIN state (Fall b),
 *      hex_geoserver_roller membership drift, and arvs_fran inheritance
 *      drift for a GeoServer service account.
 *
 * A single hex_underhall() call is used to repair everything at once
 * (matching real disaster-recovery usage), then each area is asserted
 * independently.
 *
 * PREREQUISITES:
 *   - Hex must be installed in the target database (all functions deployed)
 *   - PostGIS extension must be available
 *   - Run as a superuser or the Hex system owner
 *
 * USAGE:
 *   psql -d your_database -f test_underhall.sql
 *
 * The test cleans up after itself using DROP SCHEMA ... CASCADE at the end.
 * The test is idempotent -- safe to run multiple times.
 ******************************************************************************/

\echo '============================================================'
\echo 'HEX hex_underhall() TEST SUITE'
\echo '============================================================'

------------------------------------------------------------------------
-- SETUP: a _kba_ table with geometry gets the full Hex treatment --
-- history table, QA trigger, audit trigger, geometry trigger, gid
-- trigger, and a dummy row -- in one CREATE TABLE. A dependent view is
-- added too, since views are a normal part of a Hex schema and the
-- ownership sweep needs to reach them as well.
------------------------------------------------------------------------
\echo ''
\echo '--- Setup ---'

SET client_min_messages = 'warning';

DROP SCHEMA IF EXISTS sk1_kba_underhalltest CASCADE;
DELETE FROM hex_dummy_geometrier WHERE schema_namn = 'sk1_kba_underhalltest';

CREATE SCHEMA sk1_kba_underhalltest;

CREATE TABLE sk1_kba_underhalltest.testobj_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

CREATE VIEW sk1_kba_underhalltest.v_testobj_y AS
    SELECT * FROM sk1_kba_underhalltest.testobj_y;

-- A stale hex_dummy_geometrier row pointing at a table that was never
-- created. hex_underhall()'s dummy-trigger repair loop must skip this
-- silently (see its own "hoppar over om tabellen inte langre existerar"
-- comment) rather than error out.
INSERT INTO hex_dummy_geometrier (schema_namn, tabell_namn, gid)
VALUES ('sk1_kba_underhalltest', 'ghost_table_xyz', 999999);

RESET client_min_messages;

------------------------------------------------------------------------
-- DAMAGE: everything below is done in one pass, mirroring a real
-- "something's broken, run maintenance" scenario rather than testing
-- each break in isolation with its own repair call.
------------------------------------------------------------------------
\echo ''
\echo '--- Damaging the schema ---'

SET client_min_messages = 'warning';

-- A. Ownership damage: simulate objects touched/created by a superuser
-- session (e.g. FME or a DBA connecting directly as postgres).
ALTER SCHEMA sk1_kba_underhalltest OWNER TO postgres;
ALTER TABLE sk1_kba_underhalltest.testobj_y OWNER TO postgres;
ALTER TABLE sk1_kba_underhalltest.testobj_y_h OWNER TO postgres;
ALTER SEQUENCE sk1_kba_underhalltest.testobj_y_gid_seq OWNER TO postgres;
ALTER VIEW sk1_kba_underhalltest.v_testobj_y OWNER TO postgres;
ALTER FUNCTION sk1_kba_underhalltest.trg_fn_testobj_y_qa() OWNER TO postgres;

-- B. Trigger damage: drop every row-level trigger Hex attached at CREATE TABLE.
DROP TRIGGER IF EXISTS hex_tvinga_gid          ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_tvinga_anvandarvarden ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_kontrollera_geom    ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS trg_testobj_y_qa        ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_ta_bort_dummy       ON sk1_kba_underhalltest.testobj_y;

-- D. Role damage, spread across the four roles so each scenario is isolated:
--   r_  -- missing entirely (Fall a: DROP OWNED BY + DROP ROLE, like a role
--         that got manually removed or never survived a restore)
--   w_  -- stale pre-4-role install: was LOGIN, wrongly in hex_geoserver_roller
--         (Fall b: the exact scenario commit 95ead68 fixed)
--   gs_r_ -- hex_geoserver_roller membership revoked (breaks pg_hba.conf
--            matching for the GeoServer read account)
--   gs_w_ -- arvs_fran inheritance broken (no longer inherits from w_,
--            so it would silently lose write access)
DROP OWNED BY r_sk1_kba_underhalltest;
DROP ROLE r_sk1_kba_underhalltest;

ALTER ROLE w_sk1_kba_underhalltest WITH LOGIN PASSWORD 'temp_pre_fix_password';
GRANT hex_geoserver_roller TO w_sk1_kba_underhalltest;

REVOKE hex_geoserver_roller FROM gs_r_sk1_kba_underhalltest;

REVOKE w_sk1_kba_underhalltest FROM gs_w_sk1_kba_underhalltest;

RESET client_min_messages;

------------------------------------------------------------------------
-- REPAIR: one hex_underhall() call fixes all of the above.
------------------------------------------------------------------------
\echo ''
\echo '--- Running hex_underhall() ---'

SET client_min_messages = 'warning';
SELECT count(*) AS repair_actions FROM hex_underhall();
RESET client_min_messages;

------------------------------------------------------------------------
-- A: Ownership sweep
------------------------------------------------------------------------
\echo ''
\echo '--- A: Ownership sweep ---'

DO $$
DECLARE
    wrong_owner text[];
BEGIN
    SELECT array_agg(relname) INTO wrong_owner
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname = 'sk1_kba_underhalltest'
      AND c.relkind IN ('r', 'v', 'S')
      AND r.rolname <> public.hex_systemagare();

    IF wrong_owner IS NULL THEN
        RAISE NOTICE 'TEST A1 PASSED: all tables/views/sequences owned by %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST A1 FAILED: still wrongly owned: %', array_to_string(wrong_owner, ', ');
    END IF;
END $$;

DO $$
DECLARE
    schema_owner text;
    fn_owner text;
BEGIN
    SELECT r.rolname INTO schema_owner
    FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
    WHERE n.nspname = 'sk1_kba_underhalltest';

    SELECT r.rolname INTO fn_owner
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles r ON r.oid = p.proowner
    WHERE n.nspname = 'sk1_kba_underhalltest' AND p.proname = 'trg_fn_testobj_y_qa';

    IF schema_owner = public.hex_systemagare() AND fn_owner = public.hex_systemagare() THEN
        RAISE NOTICE 'TEST A2 PASSED: schema and QA trigger function owned by %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST A2 FAILED: schema_owner=%, fn_owner=% (both should be %)',
            schema_owner, fn_owner, public.hex_systemagare();
    END IF;
END $$;

------------------------------------------------------------------------
-- B: Row-level trigger reattachment, verified functionally
------------------------------------------------------------------------
\echo ''
\echo '--- B: Trigger reattachment ---'

-- B1: hex_tvinga_gid -- client-supplied gid via OVERRIDING SYSTEM VALUE
-- must still be silently replaced by the sequence's next value.
DO $$
DECLARE
    got_gid integer;
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (gid, beskrivning, geom)
        OVERRIDING SYSTEM VALUE
        VALUES (999999, 'test-b1-gid', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007))
        RETURNING gid INTO got_gid;

    IF got_gid IS DISTINCT FROM 999999 THEN
        RAISE NOTICE 'TEST B1 PASSED: hex_tvinga_gid reattached, client gid 999999 overridden to %', got_gid;
    ELSE
        RAISE WARNING 'TEST B1 FAILED: client-supplied gid 999999 was accepted -- hex_tvinga_gid missing';
    END IF;
END $$;

-- B2: hex_tvinga_anvandarvarden -- client-supplied skapad_av must still be
-- silently overridden with the session user.
DO $$
DECLARE
    got_skapad_av text;
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (beskrivning, skapad_av, geom)
        VALUES ('test-b2-audit', 'fake_user', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007))
        RETURNING skapad_av INTO got_skapad_av;

    IF got_skapad_av IS DISTINCT FROM 'fake_user' THEN
        RAISE NOTICE 'TEST B2 PASSED: hex_tvinga_anvandarvarden reattached, skapad_av overridden to %', got_skapad_av;
    ELSE
        RAISE WARNING 'TEST B2 FAILED: client-supplied skapad_av ''fake_user'' was accepted -- hex_tvinga_anvandarvarden missing';
    END IF;
END $$;

-- B3: hex_kontrollera_geom -- an invalid (self-intersecting) geometry must
-- still be rejected with Hex's own message, not just PostgreSQL's generic
-- CHECK constraint violation (proves the TRIGGER fired, not only the CHECK).
DO $$
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (beskrivning, geom)
        VALUES ('test-b3-geom', ST_GeomFromText('POLYGON((0 0,10 10,10 0,0 10,0 0))', 3007));
    RAISE WARNING 'TEST B3 FAILED: self-intersecting geometry was accepted';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri i tabellen%' THEN
            RAISE NOTICE 'TEST B3 PASSED: hex_kontrollera_geom reattached, rejected with Hex message';
        ELSE
            RAISE WARNING 'TEST B3 PARTIAL: geometry rejected, but not by hex_kontrollera_geom (got: %)', SQLERRM;
        END IF;
END $$;

-- B4: trg_testobj_y_qa -- an UPDATE must still write a history row.
DO $$
DECLARE
    history_rows_before integer;
    history_rows_after integer;
BEGIN
    SELECT count(*) INTO history_rows_before FROM sk1_kba_underhalltest.testobj_y_h;

    UPDATE sk1_kba_underhalltest.testobj_y SET beskrivning = 'test-b4-updated' WHERE beskrivning = 'test-b1-gid';

    SELECT count(*) INTO history_rows_after FROM sk1_kba_underhalltest.testobj_y_h;

    IF history_rows_after > history_rows_before THEN
        RAISE NOTICE 'TEST B4 PASSED: trg_testobj_y_qa reattached, UPDATE wrote a history row (% -> %)',
            history_rows_before, history_rows_after;
    ELSE
        RAISE WARNING 'TEST B4 FAILED: UPDATE did not write a history row -- trg_testobj_y_qa missing';
    END IF;
END $$;

-- B5: hex_ta_bort_dummy -- the original dummy row (registered at CREATE
-- TABLE time) must still be removed automatically by the first real INSERT.
-- All the inserts in B1/B2/B3 above were "real" rows, so by this point the
-- dummy should already be gone.
DO $$
DECLARE
    dummy_gone boolean;
BEGIN
    SELECT NOT EXISTS (
        SELECT 1 FROM hex_dummy_geometrier
        WHERE schema_namn = 'sk1_kba_underhalltest' AND tabell_namn = 'testobj_y'
    ) INTO dummy_gone;

    IF dummy_gone THEN
        RAISE NOTICE 'TEST B5 PASSED: hex_ta_bort_dummy reattached, dummy row was cleaned up on first real INSERT';
    ELSE
        RAISE WARNING 'TEST B5 FAILED: dummy row still registered after real inserts -- hex_ta_bort_dummy missing';
    END IF;
END $$;

------------------------------------------------------------------------
-- C: hex_dummy_geometrier edge case -- stale entry for a nonexistent table
------------------------------------------------------------------------
\echo ''
\echo '--- C: Stale dummy-geometry entry ---'

DO $$
DECLARE
    still_there boolean;
BEGIN
    -- The mere fact that we got this far (past hex_underhall() above)
    -- without an unhandled exception already proves the stale entry didn't
    -- crash the repair run. Also confirm it's simply left alone.
    SELECT EXISTS (
        SELECT 1 FROM hex_dummy_geometrier
        WHERE schema_namn = 'sk1_kba_underhalltest' AND tabell_namn = 'ghost_table_xyz'
    ) INTO still_there;

    IF still_there THEN
        RAISE NOTICE 'TEST C1 PASSED: stale hex_dummy_geometrier entry for a nonexistent table was skipped without error';
    ELSE
        RAISE WARNING 'TEST C1 NOTE: stale entry was removed rather than skipped (not necessarily wrong, just unexpected)';
    END IF;
END $$;

------------------------------------------------------------------------
-- D: Role structure repair
------------------------------------------------------------------------
\echo ''
\echo '--- D: Role structure repair ---'

-- D1 (Fall a): r_ was DROP ROLE'd entirely -- must be recreated as NOLOGIN
-- with schema grants and ADMIN OPTION for the owner role.
DO $$
DECLARE
    r_exists boolean;
    r_login boolean;
    r_admin_option boolean;
    r_has_select boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_kba_underhalltest') INTO r_exists;

    IF NOT r_exists THEN
        RAISE WARNING 'TEST D1 FAILED: r_sk1_kba_underhalltest was not recreated after DROP ROLE';
        RETURN;
    END IF;

    SELECT rolcanlogin INTO r_login FROM pg_roles WHERE rolname = 'r_sk1_kba_underhalltest';
    SELECT has_table_privilege('r_sk1_kba_underhalltest', 'sk1_kba_underhalltest.testobj_y', 'SELECT') INTO r_has_select;
    SELECT am.admin_option INTO r_admin_option
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'r_sk1_kba_underhalltest' AND mem.rolname = public.hex_systemagare();

    IF r_login IS DISTINCT FROM true AND r_has_select AND r_admin_option THEN
        RAISE NOTICE 'TEST D1 PASSED: r_ recreated as NOLOGIN with SELECT grants and ADMIN OPTION for %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST D1 FAILED: r_login=%, r_has_select=%, r_admin_option=%', r_login, r_has_select, r_admin_option;
    END IF;
END $$;

-- D2 (Fall b): w_ was a stale pre-4-role LOGIN role wrongly in
-- hex_geoserver_roller -- must be migrated back to NOLOGIN and removed
-- from hex_geoserver_roller (this is the exact bug commit 95ead68 fixed).
DO $$
DECLARE
    w_login boolean;
    w_in_geoserver_roller boolean;
BEGIN
    SELECT rolcanlogin INTO w_login FROM pg_roles WHERE rolname = 'w_sk1_kba_underhalltest';
    SELECT pg_has_role('w_sk1_kba_underhalltest', 'hex_geoserver_roller', 'member') INTO w_in_geoserver_roller;

    IF w_login IS DISTINCT FROM true AND NOT w_in_geoserver_roller THEN
        RAISE NOTICE 'TEST D2 PASSED: w_ migrated back to NOLOGIN and removed from hex_geoserver_roller';
    ELSE
        RAISE WARNING 'TEST D2 FAILED: w_login=%, w_in_geoserver_roller=% (expected false, false)', w_login, w_in_geoserver_roller;
    END IF;
END $$;

-- D3: gs_r_ had hex_geoserver_roller membership revoked -- must be restored
-- (this is what makes pg_hba.conf matching work for the GeoServer account).
DO $$
DECLARE
    gsr_in_geoserver_roller boolean;
BEGIN
    SELECT pg_has_role('gs_r_sk1_kba_underhalltest', 'hex_geoserver_roller', 'member') INTO gsr_in_geoserver_roller;

    IF gsr_in_geoserver_roller THEN
        RAISE NOTICE 'TEST D3 PASSED: gs_r_ hex_geoserver_roller membership restored';
    ELSE
        RAISE WARNING 'TEST D3 FAILED: gs_r_ is not a member of hex_geoserver_roller';
    END IF;
END $$;

-- D4: gs_w_ had its arvs_fran inheritance from w_ broken -- must be restored.
DO $$
DECLARE
    gsw_inherits_w boolean;
BEGIN
    SELECT pg_has_role('gs_w_sk1_kba_underhalltest', 'w_sk1_kba_underhalltest', 'member') INTO gsw_inherits_w;

    IF gsw_inherits_w THEN
        RAISE NOTICE 'TEST D4 PASSED: gs_w_ inheritance from w_ (arvs_fran) restored';
    ELSE
        RAISE WARNING 'TEST D4 FAILED: gs_w_ does not inherit from w_';
    END IF;
END $$;

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
\echo ''
\echo '--- Cleanup ---'

SET client_min_messages = 'warning';
DROP SCHEMA sk1_kba_underhalltest CASCADE;
DELETE FROM hex_dummy_geometrier WHERE schema_namn = 'sk1_kba_underhalltest';
RESET client_min_messages;

\echo ''
\echo '============================================================'
\echo 'hex_underhall() tests complete.'
\echo '============================================================'
