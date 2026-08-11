-- =============================================================================
-- TEST SUITE: underhall_hex()
-- Covers trigger repair paths (sections 1–4) and ownership repair (sections 8–9).
-- Run as: sudo -u postgres psql -d hex_test -f tests/test_underhall_hex.sql
-- =============================================================================

\set ON_ERROR_STOP off
SET client_min_messages = WARNING;

CREATE TABLE IF NOT EXISTS _test_results (
    nr      int,
    name    text,
    status  text,
    note    text
);
TRUNCATE _test_results;

CREATE OR REPLACE FUNCTION _pass(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'PASS', note); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _xfail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'XFAIL', note); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _fail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'FAIL', note); END $$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP
-- Schemas are created here; event triggers auto-create the four roles per schema.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS sk0_ext_underhall;
CREATE SCHEMA IF NOT EXISTS sk0_kba_underhall;

-- =============================================================================
-- GROUP 1: TRIGGER REPAIR  (underhall_hex sections 1–4)
-- =============================================================================

-- TEST 01: hex_tvinga_gid – trigger recreated after manual drop
DO $$ DECLARE
    trig_exists boolean;
BEGIN
    CREATE TABLE sk0_ext_underhall.gid_repair_test (namn text);

    -- Drop the trigger to simulate a pre-Hex or partially-migrated table
    DROP TRIGGER IF EXISTS hex_tvinga_gid ON sk0_ext_underhall.gid_repair_test;

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_underhall'
          AND c.relname = 'gid_repair_test'
          AND t.tgname  = 'hex_tvinga_gid'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _fail(01, 'hex_tvinga_gid: trigger gone after manual drop', 'trigger still present');
        RETURN;
    END IF;

    PERFORM public.underhall_hex();

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_underhall'
          AND c.relname = 'gid_repair_test'
          AND t.tgname  = 'hex_tvinga_gid'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _pass(01, 'hex_tvinga_gid: trigger recreated by underhall_hex');
    ELSE
        PERFORM _fail(01, 'hex_tvinga_gid: trigger recreated by underhall_hex',
            'trigger still missing after repair');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(01, 'hex_tvinga_gid trigger repair', SQLERRM);
END $$;

-- TEST 02: hex_tvinga_gid – repaired trigger correctly overrides client-supplied gid
DO $$ DECLARE
    inserted_gid integer;
BEGIN
    -- Insert with OVERRIDING SYSTEM VALUE (QGIS-style client supplying its own gid)
    INSERT INTO sk0_ext_underhall.gid_repair_test (gid, namn)
        OVERRIDING SYSTEM VALUE VALUES (999, 'repair_test');

    SELECT gid INTO inserted_gid
    FROM sk0_ext_underhall.gid_repair_test
    WHERE namn = 'repair_test';

    IF inserted_gid IS DISTINCT FROM 999 THEN
        PERFORM _pass(02, 'hex_tvinga_gid: repaired trigger overrides client-supplied gid',
            format('sequence value %s used, not 999', inserted_gid));
    ELSE
        PERFORM _fail(02, 'hex_tvinga_gid: repaired trigger overrides client-supplied gid',
            'gid 999 was accepted – trigger did not fire');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(02, 'hex_tvinga_gid repaired trigger behaviour', SQLERRM);
END $$;

-- TEST 03: hex_kontrollera_geom – trigger recreated after manual drop
DO $$ DECLARE
    trig_exists boolean;
BEGIN
    -- kba category has validera_geometri = true → trigger should be created on geometry tables
    CREATE TABLE sk0_kba_underhall.geom_repair_p (
        namn text,
        geom geometry(Point, 3006)
    );

    DROP TRIGGER IF EXISTS hex_kontrollera_geom ON sk0_kba_underhall.geom_repair_p;

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_kba_underhall'
          AND c.relname = 'geom_repair_p'
          AND t.tgname  = 'hex_kontrollera_geom'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _fail(03, 'hex_kontrollera_geom: trigger gone after drop', 'still present');
        RETURN;
    END IF;

    PERFORM public.underhall_hex();

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_kba_underhall'
          AND c.relname = 'geom_repair_p'
          AND t.tgname  = 'hex_kontrollera_geom'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _pass(03, 'hex_kontrollera_geom: trigger recreated by underhall_hex');
    ELSE
        PERFORM _fail(03, 'hex_kontrollera_geom: trigger recreated by underhall_hex',
            'still missing after repair');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(03, 'hex_kontrollera_geom trigger repair', SQLERRM);
END $$;

-- TEST 04: hex_ta_bort_dummy – trigger recreated when hex_dummy_geometrier entry survives
DO $$ DECLARE
    trig_exists  boolean;
    dummy_exists boolean;
BEGIN
    -- geom_repair_p (created in T03) should have a dummy-row entry in hex_dummy_geometrier
    SELECT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_kba_underhall'
          AND tabell_namn = 'geom_repair_p'
    ) INTO dummy_exists;

    IF NOT dummy_exists THEN
        PERFORM _fail(04, 'hex_ta_bort_dummy: dummy entry present (precondition)',
            'no row in hex_dummy_geometrier – cannot test repair path');
        RETURN;
    END IF;

    DROP TRIGGER IF EXISTS hex_ta_bort_dummy ON sk0_kba_underhall.geom_repair_p;

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_kba_underhall'
          AND c.relname = 'geom_repair_p'
          AND t.tgname  = 'hex_ta_bort_dummy'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _fail(04, 'hex_ta_bort_dummy: trigger gone after drop', 'still present');
        RETURN;
    END IF;

    PERFORM public.underhall_hex();

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_kba_underhall'
          AND c.relname = 'geom_repair_p'
          AND t.tgname  = 'hex_ta_bort_dummy'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _pass(04, 'hex_ta_bort_dummy: trigger recreated by underhall_hex');
    ELSE
        PERFORM _fail(04, 'hex_ta_bort_dummy: trigger recreated by underhall_hex',
            'still missing after repair');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(04, 'hex_ta_bort_dummy trigger repair', SQLERRM);
END $$;

-- TEST 05: trg_*_qa – trigger recreated from surviving trigger function
-- underhall_hex section 4 uses trg_fn_<table>_qa functions as the source of truth;
-- they survive uninstall/reinstall, making them reliable even when hex_metadata is empty.
DO $$ DECLARE
    trig_exists boolean;
BEGIN
    CREATE TABLE sk0_ext_underhall.qa_repair_test (namn text);

    -- Create the trigger function that would normally be created by skapa_historik_qa().
    -- The function name encodes the parent table; underhall_hex() derives the table
    -- name via: substring(proname FROM '^trg_fn_(.+)_qa$')
    CREATE OR REPLACE FUNCTION sk0_ext_underhall.trg_fn_qa_repair_test_qa()
        RETURNS trigger LANGUAGE plpgsql AS $fn$
        BEGIN RETURN COALESCE(NEW, OLD); END $fn$;

    -- No trigger exists yet – simulates a state after Hex reinstall or data migration
    DROP TRIGGER IF EXISTS trg_qa_repair_test_qa ON sk0_ext_underhall.qa_repair_test;

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_underhall'
          AND c.relname = 'qa_repair_test'
          AND t.tgname  = 'trg_qa_repair_test_qa'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _fail(05, 'trg_*_qa: trigger absent before repair (precondition)',
            'trigger already present');
        RETURN;
    END IF;

    PERFORM public.underhall_hex();

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class     c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_underhall'
          AND c.relname = 'qa_repair_test'
          AND t.tgname  = 'trg_qa_repair_test_qa'
    ) INTO trig_exists;

    IF trig_exists THEN
        PERFORM _pass(05, 'trg_*_qa: trigger recreated from surviving trigger function');
    ELSE
        PERFORM _fail(05, 'trg_*_qa: trigger recreated from surviving trigger function',
            'trigger still missing after repair');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(05, 'trg_*_qa trigger repair', SQLERRM);
END $$;

-- =============================================================================
-- GROUP 2: OWNERSHIP REPAIR  (underhall_hex sections 8–9)
-- =============================================================================

-- TEST 06: ägarskap_schema – schema owned by wrong role corrected
DO $$ DECLARE
    current_owner text;
BEGIN
    -- Force wrong ownership (simulate superuser bypassing event trigger)
    ALTER SCHEMA sk0_ext_underhall OWNER TO postgres;

    SELECT ro.rolname INTO current_owner
    FROM   pg_namespace n
    JOIN   pg_roles     ro ON ro.oid = n.nspowner
    WHERE  n.nspname = 'sk0_ext_underhall';

    IF current_owner != 'postgres' THEN
        PERFORM _fail(06, 'ägarskap_schema: ownership corrected',
            format('could not set up wrong ownership; owner is %s', current_owner));
        RETURN;
    END IF;

    PERFORM public.underhall_hex();

    SELECT ro.rolname INTO current_owner
    FROM   pg_namespace n
    JOIN   pg_roles     ro ON ro.oid = n.nspowner
    WHERE  n.nspname = 'sk0_ext_underhall';

    IF current_owner = public.system_owner() THEN
        PERFORM _pass(06, 'ägarskap_schema: schema ownership corrected to system_owner()');
    ELSE
        PERFORM _fail(06, 'ägarskap_schema: schema ownership corrected to system_owner()',
            format('owner is %s, expected %s', current_owner, public.system_owner()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(06, 'ägarskap_schema ownership repair', SQLERRM);
END $$;

-- TEST 07: ägarskap_objekt – table owned by wrong role corrected
DO $$ DECLARE
    current_owner text;
BEGIN
    CREATE TABLE IF NOT EXISTS sk0_ext_underhall.owner_repair_test (namn text);

    ALTER TABLE sk0_ext_underhall.owner_repair_test OWNER TO postgres;

    PERFORM public.underhall_hex();

    SELECT ro.rolname INTO current_owner
    FROM   pg_class     c
    JOIN   pg_namespace n  ON n.oid = c.relnamespace
    JOIN   pg_roles     ro ON ro.oid = c.relowner
    WHERE  n.nspname = 'sk0_ext_underhall'
      AND  c.relname = 'owner_repair_test'
      AND  c.relkind = 'r';

    IF current_owner = public.system_owner() THEN
        PERFORM _pass(07, 'ägarskap_objekt: table ownership corrected to system_owner()');
    ELSE
        PERFORM _fail(07, 'ägarskap_objekt: table ownership corrected to system_owner()',
            format('owner is %s, expected %s', current_owner, public.system_owner()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(07, 'ägarskap_objekt table ownership repair', SQLERRM);
END $$;

-- TEST 08: ägarskap_objekt – identity sequence owner follows table owner after repair
-- Identity sequences (GENERATED ALWAYS AS IDENTITY) cannot have their owner changed
-- independently; PostgreSQL cascades the owner automatically when the table owner
-- changes.  underhall_hex() fixes the table owner (relkind 'r') and skips the
-- identity sequence directly — the cascade does the work.
DO $$ DECLARE
    seq_name      text;
    current_owner text;
BEGIN
    -- Locate the IDENTITY sequence backing the gid column
    SELECT c2.relname INTO seq_name
    FROM   pg_class     c
    JOIN   pg_namespace n  ON n.oid = c.relnamespace
    JOIN   pg_attribute a  ON a.attrelid = c.oid AND a.attname = 'gid'
    JOIN   pg_depend    d  ON d.refobjid = c.oid AND d.refobjsubid = a.attnum
                          AND d.deptype = 'i'
    JOIN   pg_class     c2 ON c2.oid = d.objid AND c2.relkind = 'S'
    WHERE  n.nspname = 'sk0_ext_underhall'
      AND  c.relname = 'owner_repair_test';

    IF seq_name IS NULL THEN
        PERFORM _fail(08, 'ägarskap_objekt: identity sequence follows table owner repair',
            'no IDENTITY sequence found for owner_repair_test.gid');
        RETURN;
    END IF;

    -- Set table to wrong owner – identity sequence owner cascades automatically
    ALTER TABLE sk0_ext_underhall.owner_repair_test OWNER TO postgres;

    -- Repair: fixes table owner; identity sequence cascades
    PERFORM public.underhall_hex();

    SELECT ro.rolname INTO current_owner
    FROM   pg_class     c
    JOIN   pg_namespace n  ON n.oid = c.relnamespace
    JOIN   pg_roles     ro ON ro.oid = c.relowner
    WHERE  n.nspname = 'sk0_ext_underhall'
      AND  c.relname = seq_name
      AND  c.relkind = 'S';

    IF current_owner = public.system_owner() THEN
        PERFORM _pass(08, 'ägarskap_objekt: identity sequence follows table owner repair');
    ELSE
        PERFORM _fail(08, 'ägarskap_objekt: identity sequence follows table owner repair',
            format('owner is %s, expected %s', current_owner, public.system_owner()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(08, 'ägarskap_objekt sequence ownership repair', SQLERRM);
END $$;

-- TEST 09: ägarskap_objekt – view owned by wrong role corrected
DO $$ DECLARE
    current_owner text;
BEGIN
    CREATE OR REPLACE VIEW sk0_ext_underhall.v_owner_repair_test AS
        SELECT namn FROM sk0_ext_underhall.owner_repair_test;

    ALTER VIEW sk0_ext_underhall.v_owner_repair_test OWNER TO postgres;

    PERFORM public.underhall_hex();

    SELECT ro.rolname INTO current_owner
    FROM   pg_class     c
    JOIN   pg_namespace n  ON n.oid = c.relnamespace
    JOIN   pg_roles     ro ON ro.oid = c.relowner
    WHERE  n.nspname = 'sk0_ext_underhall'
      AND  c.relname = 'v_owner_repair_test'
      AND  c.relkind = 'v';

    IF current_owner = public.system_owner() THEN
        PERFORM _pass(09, 'ägarskap_objekt: view ownership corrected to system_owner()');
    ELSE
        PERFORM _fail(09, 'ägarskap_objekt: view ownership corrected to system_owner()',
            format('owner is %s, expected %s', current_owner, public.system_owner()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(09, 'ägarskap_objekt view ownership repair', SQLERRM);
END $$;

-- TEST 10: ägarskap_objekt – function owned by wrong role corrected
DO $$ DECLARE
    current_owner text;
BEGIN
    CREATE OR REPLACE FUNCTION sk0_ext_underhall.owner_repair_fn()
        RETURNS text LANGUAGE sql AS $fn$ SELECT 'ok' $fn$;

    ALTER FUNCTION sk0_ext_underhall.owner_repair_fn() OWNER TO postgres;

    PERFORM public.underhall_hex();

    SELECT ro.rolname INTO current_owner
    FROM   pg_proc      p
    JOIN   pg_namespace n  ON n.oid = p.pronamespace
    JOIN   pg_roles     ro ON ro.oid = p.proowner
    WHERE  n.nspname = 'sk0_ext_underhall'
      AND  p.proname = 'owner_repair_fn';

    IF current_owner = public.system_owner() THEN
        PERFORM _pass(10, 'ägarskap_objekt: function ownership corrected to system_owner()');
    ELSE
        PERFORM _fail(10, 'ägarskap_objekt: function ownership corrected to system_owner()',
            format('owner is %s, expected %s', current_owner, public.system_owner()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(10, 'ägarskap_objekt function ownership repair', SQLERRM);
END $$;

-- TEST 11: underhall_hex() return value – repair rows emitted for ownership corrections
DO $$ DECLARE
    repair_count int;
BEGIN
    -- Reset to known wrong state so repair rows are guaranteed
    ALTER SCHEMA sk0_ext_underhall OWNER TO postgres;
    ALTER TABLE  sk0_ext_underhall.owner_repair_test OWNER TO postgres;

    SELECT count(*) INTO repair_count
    FROM public.underhall_hex()
    WHERE trigger_namn IN ('ägarskap_schema', 'ägarskap_objekt')
      AND atgard LIKE 'ägare korrigerad:%';

    IF repair_count >= 2 THEN
        PERFORM _pass(11, 'underhall_hex: repair rows emitted for ownership corrections',
            format('%s rows', repair_count));
    ELSE
        PERFORM _fail(11, 'underhall_hex: repair rows emitted for ownership corrections',
            format('got %s rows, expected >= 2', repair_count));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(11, 'underhall_hex ownership repair rows', SQLERRM);
END $$;

-- TEST 12: underhall_hex() is idempotent – no ownership repair rows when state is correct
DO $$ DECLARE
    repair_count int;
BEGIN
    -- Previous test left everything in the correct state; a second call should produce zero
    SELECT count(*) INTO repair_count
    FROM public.underhall_hex()
    WHERE trigger_namn IN ('ägarskap_schema', 'ägarskap_objekt')
      AND atgard LIKE 'ägare korrigerad:%';

    IF repair_count = 0 THEN
        PERFORM _pass(12, 'underhall_hex: idempotent – no spurious ownership repairs on clean state');
    ELSE
        PERFORM _fail(12, 'underhall_hex: idempotent – no spurious ownership repairs on clean state',
            format('%s unexpected repair rows', repair_count));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(12, 'underhall_hex idempotency', SQLERRM);
END $$;

-- =============================================================================
-- TEARDOWN
-- =============================================================================

DROP SCHEMA IF EXISTS sk0_ext_underhall CASCADE;
DROP SCHEMA IF EXISTS sk0_kba_underhall CASCADE;

-- Explicit role cleanup in case ta_bort_schemaroller_trigger didn't fire
DROP ROLE IF EXISTS r_sk0_ext_underhall;
DROP ROLE IF EXISTS w_sk0_ext_underhall;
DROP ROLE IF EXISTS gs_r_sk0_ext_underhall;
DROP ROLE IF EXISTS gs_w_sk0_ext_underhall;
DROP ROLE IF EXISTS r_sk0_kba_underhall;
DROP ROLE IF EXISTS w_sk0_kba_underhall;
DROP ROLE IF EXISTS gs_r_sk0_kba_underhall;
DROP ROLE IF EXISTS gs_w_sk0_kba_underhall;

-- =============================================================================
-- RESULTS
-- =============================================================================

SELECT
    nr,
    name,
    status,
    CASE WHEN note != '' THEN note ELSE '-' END AS note
FROM _test_results
ORDER BY nr;

SELECT
    count(*) FILTER (WHERE status = 'PASS')  AS passed,
    count(*) FILTER (WHERE status = 'FAIL')  AS failed,
    count(*) FILTER (WHERE status = 'XFAIL') AS xfailed
FROM _test_results;
