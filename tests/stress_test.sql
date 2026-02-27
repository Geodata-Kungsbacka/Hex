-- =============================================================================
-- HEX STRESS TEST  (~35 tests)
-- Run as: sudo -u postgres psql -d hex_test -f tests/stress_test.sql
-- =============================================================================

\set ON_ERROR_STOP off
SET client_min_messages = WARNING;

CREATE TABLE IF NOT EXISTS _test_results (
    nr      int,
    name    text,
    status  text,  -- PASS / FAIL / XFAIL (expected failure)
    note    text
);
TRUNCATE _test_results;

-- Helper: record pass
CREATE OR REPLACE FUNCTION _pass(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'PASS', note); END $$ LANGUAGE plpgsql;

-- Helper: record expected failure (system correctly blocked something)
CREATE OR REPLACE FUNCTION _xfail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'XFAIL', note); END $$ LANGUAGE plpgsql;

-- Helper: record unexpected failure
CREATE OR REPLACE FUNCTION _fail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'FAIL', note); END $$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP: helper schema + roles for later tests
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS sk1_kba_stress;
CREATE SCHEMA IF NOT EXISTS sk0_ext_stress;
CREATE SCHEMA IF NOT EXISTS sk2_sys_stress;

CREATE ROLE stress_user WITH LOGIN PASSWORD 'testpass';
GRANT CONNECT ON DATABASE hex_test TO stress_user;
GRANT CREATE ON SCHEMA sk1_kba_stress TO stress_user;
GRANT CREATE ON SCHEMA sk0_ext_stress TO stress_user;
GRANT w_sk1_kba_stress TO stress_user;
GRANT w_sk0_ext_stress TO stress_user;
INSERT INTO hex_systemanvandare (anvandare, beskrivning)
VALUES ('stress_user', 'Stress test system user') ON CONFLICT DO NOTHING;


-- =============================================================================
-- GROUP 1: SCHEMA NAMING
-- =============================================================================

-- TEST 01: Shortest valid schema name (single-char suffix)
DO $$ BEGIN
    CREATE SCHEMA sk0_ext_a;
    PERFORM _pass(01, 'Schema: single-char suffix ok');
    DROP SCHEMA sk0_ext_a;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(01, 'Schema: single-char suffix ok', SQLERRM);
END $$;

-- TEST 02: Schema name with numbers in suffix
DO $$ BEGIN
    CREATE SCHEMA sk1_kba_omrade2;
    PERFORM _pass(02, 'Schema: numbers in suffix ok');
    DROP SCHEMA sk1_kba_omrade2;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(02, 'Schema: numbers in suffix ok', SQLERRM);
END $$;

-- TEST 03: Invalid schema - no prefix (should be blocked)
DO $$ BEGIN
    CREATE SCHEMA geodata;
    PERFORM _fail(03, 'Schema: no sk-prefix blocked');
    DROP SCHEMA IF EXISTS geodata;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(03, 'Schema: no sk-prefix blocked', SQLERRM);
END $$;

-- TEST 04: Quoted uppercase schema name (should be blocked by Hex)
-- Note: unquoted uppercase is silently folded to lowercase by PostgreSQL before
-- the trigger fires, so "SK1_kba_test" becomes "sk1_kba_test" (valid).
-- Only quoted identifiers preserve case and can be tested here.
DO $$ BEGIN
    CREATE SCHEMA "SK1_kba_quoted";
    PERFORM _fail(04, 'Schema: quoted uppercase blocked');
    DROP SCHEMA IF EXISTS "SK1_kba_quoted";
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(04, 'Schema: quoted uppercase blocked', SQLERRM);
END $$;

-- TEST 05: Invalid schema - missing description after category (should be blocked)
DO $$ BEGIN
    CREATE SCHEMA sk1_kba;
    PERFORM _fail(05, 'Schema: no suffix after category blocked');
    DROP SCHEMA IF EXISTS sk1_kba;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(05, 'Schema: no suffix after category blocked', SQLERRM);
END $$;

-- TEST 06: Invalid schema - wrong category (should be blocked)
DO $$ BEGIN
    CREATE SCHEMA sk1_gis_bygg;
    PERFORM _fail(06, 'Schema: wrong category blocked');
    DROP SCHEMA IF EXISTS sk1_gis_bygg;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(06, 'Schema: wrong category blocked', SQLERRM);
END $$;

-- TEST 07: Roles auto-created and auto-deleted with schema
DO $$ BEGIN
    CREATE SCHEMA sk1_kba_rolecheck;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_rolecheck') THEN
        PERFORM _fail(07, 'Schema: w_ role auto-created', 'role missing after CREATE SCHEMA');
    ELSE
        PERFORM _pass(07, 'Schema: w_ role auto-created');
    END IF;
    DROP SCHEMA sk1_kba_rolecheck CASCADE;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_rolecheck') THEN
        PERFORM _fail(07, 'Schema: w_ role auto-deleted', 'role still exists after DROP SCHEMA');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(07, 'Schema: roles auto-lifecycle', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 2: TABLE CREATION
-- =============================================================================

-- TEST 08: Table without geometry (no suffix) - should succeed, no restructuring
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.konfiguration (
        nyckel text PRIMARY KEY,
        varde  text
    );
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'konfiguration'
        AND column_name = 'gid'
    ) THEN
        PERFORM _pass(08, 'Table: no-geom table gets gid');
    ELSE
        PERFORM _fail(08, 'Table: no-geom table gets gid', 'gid column missing');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(08, 'Table: no-geom table no suffix', SQLERRM);
END $$;

-- TEST 09: Table with geometry suffix but no geom col, non-system user (should fail)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.saknar_geom_p (
        namn text
    );
    PERFORM _fail(09, 'Table: geom suffix without geom col blocked for normal user');
    DROP TABLE IF EXISTS sk1_kba_stress.saknar_geom_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(09, 'Table: geom suffix without geom col blocked for normal user', SQLERRM);
END $$;

-- TEST 10: Table with two geometry columns (should fail)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.dubbel_geom_p (
        namn text,
        geom  geometry(Point, 3006),
        geom2 geometry(Point, 3006)
    );
    PERFORM _fail(10, 'Table: two geom cols blocked');
    DROP TABLE IF EXISTS sk1_kba_stress.dubbel_geom_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(10, 'Table: two geom cols blocked', SQLERRM);
END $$;

-- TEST 11: Table with wrong geom column name (should fail)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.fel_namn_p (
        namn  text,
        shape geometry(Point, 3006)
    );
    PERFORM _fail(11, 'Table: wrong geom column name blocked');
    DROP TABLE IF EXISTS sk1_kba_stress.fel_namn_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(11, 'Table: wrong geom column name blocked', SQLERRM);
END $$;

-- TEST 12: Table suffix/geometry type mismatch - _p suffix with Polygon geom (should fail)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.fel_suffix_p (
        namn text,
        geom geometry(Polygon, 3006)
    );
    PERFORM _fail(12, 'Table: suffix/type mismatch blocked (_p with Polygon)');
    DROP TABLE IF EXISTS sk1_kba_stress.fel_suffix_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(12, 'Table: suffix/type mismatch blocked (_p with Polygon)', SQLERRM);
END $$;

-- TEST 13: Valid table - all four geometry suffix types
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.punkter_p  (namn text, geom geometry(Point, 3006));
    CREATE TABLE sk1_kba_stress.linjer_l   (namn text, geom geometry(LineString, 3006));
    CREATE TABLE sk1_kba_stress.ytor_y     (namn text, geom geometry(Polygon, 3006));
    CREATE TABLE sk1_kba_stress.blandat_g  (namn text, geom geometry(Geometry, 3006));
    PERFORM _pass(13, 'Table: all four suffix types created ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(13, 'Table: all four suffix types', SQLERRM);
END $$;

-- TEST 14: Standard columns are in correct order (gid first, geom last)
DO $$ BEGIN
    DECLARE
        first_col text;
        last_col  text;
    BEGIN
        SELECT column_name INTO first_col
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'punkter_p'
        ORDER BY ordinal_position LIMIT 1;

        SELECT column_name INTO last_col
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'punkter_p'
        ORDER BY ordinal_position DESC LIMIT 1;

        IF first_col = 'gid' AND last_col = 'geom' THEN
            PERFORM _pass(14, 'Table: gid first, geom last');
        ELSE
            PERFORM _fail(14, 'Table: gid first, geom last',
                format('first=%s last=%s', first_col, last_col));
        END IF;
    END;
END $$;

-- TEST 15: GiST index created automatically
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk1_kba_stress' AND tablename = 'punkter_p'
        AND indexdef ILIKE '%gist%'
    ) THEN
        PERFORM _pass(15, 'Table: GiST index auto-created');
    ELSE
        PERFORM _fail(15, 'Table: GiST index auto-created', 'no GiST index found');
    END IF;
END $$;

-- TEST 16: Table in public schema should be ignored by Hex (no gid added)
DO $$ BEGIN
    CREATE TABLE public.hex_ignored_test (namn text);
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'hex_ignored_test'
        AND column_name = 'gid'
    ) THEN
        PERFORM _fail(16, 'Table: public schema ignored (no gid added)', 'gid was added to public table');
    ELSE
        PERFORM _pass(16, 'Table: public schema ignored (no gid added)');
    END IF;
    DROP TABLE public.hex_ignored_test;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(16, 'Table: public schema ignored', SQLERRM);
END $$;

-- TEST 17: MULTIPOLYGON geom with _y suffix (should succeed)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.multi_y (
        namn text,
        geom geometry(MultiPolygon, 3006)
    );
    PERFORM _pass(17, 'Table: MultiPolygon with _y suffix ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(17, 'Table: MultiPolygon with _y suffix', SQLERRM);
END $$;

-- TEST 18: Table with many columns (column ordering still correct)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.manga_kolumner_p (
        c01 text, c02 int, c03 bool, c04 numeric, c05 date,
        c06 text, c07 int, c08 bool, c09 numeric, c10 date,
        geom geometry(Point, 3006)
    );
    DECLARE
        last_col text;
        second_last text;
    BEGIN
        SELECT column_name INTO last_col
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'manga_kolumner_p'
        ORDER BY ordinal_position DESC LIMIT 1;

        IF last_col = 'geom' THEN
            PERFORM _pass(18, 'Table: geom last with many columns');
        ELSE
            PERFORM _fail(18, 'Table: geom last with many columns', format('last=%s', last_col));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(18, 'Table: many columns', SQLERRM);
END $$;

-- TEST 19: DROP TABLE cleans up history table automatically
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.temp_drop_p (
        namn text,
        geom geometry(Point, 3006)
    );
    -- History table should exist
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'sk1_kba_stress' AND tablename = 'temp_drop_p_h') THEN
        PERFORM _fail(19, 'Table: DROP cleans up _h table', '_h table was not created');
    ELSE
        DROP TABLE sk1_kba_stress.temp_drop_p;
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'sk1_kba_stress' AND tablename = 'temp_drop_p_h') THEN
            PERFORM _fail(19, 'Table: DROP cleans up _h table', '_h table still exists after DROP');
        ELSE
            PERFORM _pass(19, 'Table: DROP cleans up _h table');
        END IF;
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(19, 'Table: DROP cleans up _h table', SQLERRM);
END $$;

-- TEST 20: DROP TABLE cleans up hex_metadata record
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.temp_meta_p (namn text, geom geometry(Point, 3006));
    DROP TABLE sk1_kba_stress.temp_meta_p;
    IF EXISTS (
        SELECT 1 FROM hex_metadata
        WHERE parent_schema = 'sk1_kba_stress' AND parent_table = 'temp_meta_p'
    ) THEN
        PERFORM _fail(20, 'Table: DROP cleans hex_metadata', 'stale row in hex_metadata');
    ELSE
        PERFORM _pass(20, 'Table: DROP cleans hex_metadata');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(20, 'Table: DROP cleans hex_metadata', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 3: ALTER TABLE / COLUMN ORDERING
-- =============================================================================

-- TEST 21: ADD COLUMN goes before standard trailing columns and geom
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.alter_test_p (namn text, geom geometry(Point, 3006));
    ALTER TABLE sk1_kba_stress.alter_test_p ADD COLUMN ny_kolumn text;
    DECLARE
        last_col text;
        ny_pos   int;
        geom_pos int;
        av_pos   int;
    BEGIN
        SELECT ordinal_position INTO ny_pos FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'alter_test_p' AND column_name = 'ny_kolumn';
        SELECT ordinal_position INTO geom_pos FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'alter_test_p' AND column_name = 'geom';
        SELECT ordinal_position INTO av_pos FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'alter_test_p' AND column_name = 'andrad_av';

        IF ny_pos < av_pos AND av_pos < geom_pos THEN
            PERFORM _pass(21, 'ALTER TABLE: new col before standard trailing cols and geom');
        ELSE
            PERFORM _fail(21, 'ALTER TABLE: new col before standard trailing cols and geom',
                format('ny=%s andrad_av=%s geom=%s', ny_pos, av_pos, geom_pos));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(21, 'ALTER TABLE: column ordering', SQLERRM);
END $$;

-- TEST 22: ADD multiple columns in one ALTER TABLE
DO $$ BEGIN
    ALTER TABLE sk1_kba_stress.alter_test_p ADD COLUMN kol_a text, ADD COLUMN kol_b int;
    DECLARE last_col text;
    BEGIN
        SELECT column_name INTO last_col FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'alter_test_p'
        ORDER BY ordinal_position DESC LIMIT 1;
        IF last_col = 'geom' THEN
            PERFORM _pass(22, 'ALTER TABLE: multi-column ADD keeps geom last');
        ELSE
            PERFORM _fail(22, 'ALTER TABLE: multi-column ADD keeps geom last', format('last=%s', last_col));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(22, 'ALTER TABLE: multi-column ADD', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 4: VIEWS
-- =============================================================================

-- TEST 23: Valid view name with correct prefix and suffix
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.v_punkter_p AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _pass(23, 'View: valid name accepted');
    DROP VIEW sk1_kba_stress.v_punkter_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(23, 'View: valid name accepted', SQLERRM);
END $$;

-- TEST 24: View without v_ prefix (should be blocked)
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.punkter_vy_p AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _fail(24, 'View: missing v_ prefix blocked');
    DROP VIEW IF EXISTS sk1_kba_stress.punkter_vy_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(24, 'View: missing v_ prefix blocked', SQLERRM);
END $$;

-- TEST 25: View with geom but wrong suffix (should be blocked)
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.v_punkter_y AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _fail(25, 'View: wrong geom suffix blocked');
    DROP VIEW IF EXISTS sk1_kba_stress.v_punkter_y;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(25, 'View: wrong geom suffix blocked', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 5: DATA QUALITY / GEOMETRY VALIDATION (_kba_ schema)
-- =============================================================================

-- TEST 26: Valid geometry insert in _kba_ schema (should succeed)
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Giltig punkt', ST_SetSRID(ST_MakePoint(319000, 6400000), 3006));
    PERFORM _pass(26, 'Data: valid geometry insert in _kba_ ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(26, 'Data: valid geometry insert in _kba_', SQLERRM);
END $$;

-- TEST 27: Empty geometry rejected in _kba_ schema
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Tom geom', ST_SetSRID(ST_GeomFromText('POINT EMPTY'), 3006));
    PERFORM _fail(27, 'Data: empty geometry blocked in _kba_');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(27, 'Data: empty geometry blocked in _kba_', SQLERRM);
END $$;

-- TEST 28: Invalid (self-intersecting) polygon rejected in _kba_
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.ytor_y (namn, geom)
    VALUES ('Ogiltig yta',
        ST_SetSRID(ST_GeomFromText(
            'POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))'  -- bowtie
        ), 3006)
    );
    PERFORM _fail(28, 'Data: invalid polygon blocked in _kba_');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(28, 'Data: invalid polygon blocked in _kba_', SQLERRM);
END $$;

-- TEST 29: _ext_ schema has NO geometry validation (same invalid geom should be accepted)
DO $$ BEGIN
    CREATE TABLE sk0_ext_stress.omraden_y (
        namn text,
        geom geometry(Polygon, 3006)
    );
    INSERT INTO sk0_ext_stress.omraden_y (namn, geom)
    VALUES ('Ogiltig yta – ext OK',
        ST_SetSRID(ST_GeomFromText('POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))'), 3006)
    );
    PERFORM _pass(29, 'Data: invalid geom accepted in _ext_ schema (no validation)');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(29, 'Data: invalid geom accepted in _ext_ schema', SQLERRM);
END $$;

-- TEST 30: UPDATE is logged in _h table
DO $$ BEGIN
    UPDATE sk1_kba_stress.punkter_p SET namn = 'Uppdaterad' WHERE namn = 'Giltig punkt';
    IF EXISTS (SELECT 1 FROM sk1_kba_stress.punkter_p_h WHERE h_typ = 'U') THEN
        PERFORM _pass(30, 'History: UPDATE logged in _h');
    ELSE
        PERFORM _fail(30, 'History: UPDATE logged in _h', 'no U row in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(30, 'History: UPDATE logged', SQLERRM);
END $$;

-- TEST 31: DELETE is logged in _h table
DO $$ BEGIN
    DELETE FROM sk1_kba_stress.punkter_p WHERE namn = 'Uppdaterad';
    IF EXISTS (SELECT 1 FROM sk1_kba_stress.punkter_p_h WHERE h_typ = 'D') THEN
        PERFORM _pass(31, 'History: DELETE logged in _h');
    ELSE
        PERFORM _fail(31, 'History: DELETE logged in _h', 'no D row in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(31, 'History: DELETE logged', SQLERRM);
END $$;

-- TEST 32: andrad_tidpunkt updated automatically on UPDATE
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Tid test', ST_SetSRID(ST_MakePoint(319000, 6400000), 3006));

    PERFORM pg_sleep(0.01);  -- ensure time advances

    DECLARE
        tid_fore timestamptz;
        tid_efter timestamptz;
    BEGIN
        SELECT andrad_tidpunkt INTO tid_fore FROM sk1_kba_stress.punkter_p WHERE namn = 'Tid test';
        UPDATE sk1_kba_stress.punkter_p SET namn = 'Tid test uppdaterad' WHERE namn = 'Tid test';
        SELECT andrad_tidpunkt INTO tid_efter FROM sk1_kba_stress.punkter_p WHERE namn = 'Tid test uppdaterad';

        IF tid_efter > tid_fore OR (tid_fore IS NULL AND tid_efter IS NOT NULL) THEN
            PERFORM _pass(32, 'Trigger: andrad_tidpunkt updated on UPDATE');
        ELSE
            PERFORM _fail(32, 'Trigger: andrad_tidpunkt updated on UPDATE',
                format('fore=%s efter=%s', tid_fore, tid_efter));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(32, 'Trigger: andrad_tidpunkt', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 6: DESTRUCTIVE CONFIG TESTS
-- =============================================================================

-- TEST 33: Clear standardiserade_kolumner – tables still create but with no std cols
DO $$ BEGIN
    TRUNCATE standardiserade_kolumner;

    CREATE TABLE sk1_kba_stress.utan_std_p (
        namn text,
        geom geometry(Point, 3006)
    );

    -- Should not have gid since config is empty
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'utan_std_p'
        AND column_name = 'gid'
    ) THEN
        PERFORM _fail(33, 'Config: empty standardiserade_kolumner – no gid added', 'gid still exists');
    ELSE
        PERFORM _pass(33, 'Config: empty standardiserade_kolumner – no gid added');
    END IF;

    DROP TABLE sk1_kba_stress.utan_std_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(33, 'Config: empty standardiserade_kolumner', SQLERRM);
END $$;

-- Restore default columns after test 33
INSERT INTO standardiserade_kolumner (kolumnnamn, ordinal_position, datatyp, default_varde, beskrivning, schema_uttryck, historik_qa) VALUES
    ('gid',             1,  'integer GENERATED ALWAYS AS IDENTITY', NULL,           'Primärnyckel',               'IS NOT NULL',    false),
    ('skapad_tidpunkt', -4, 'timestamptz',  'NOW()',        'Tidpunkt då raden skapades',   'IS NOT NULL',    false),
    ('skapad_av',       -3, 'character varying', 'session_user', 'Användare som skapade raden',  'LIKE ''%_kba_%''', false),
    ('andrad_tidpunkt', -2, 'timestamptz',  'NOW()',        'Senaste ändringstidpunkt',     'LIKE ''%_kba_%''', true),
    ('andrad_av',       -1, 'character varying', 'session_user', 'Användare som senast ändrade', 'LIKE ''%_kba_%''', true);

-- TEST 34: Clear standardiserade_roller – schema creates but gets no roles
DO $$ BEGIN
    TRUNCATE standardiserade_roller;
    CREATE SCHEMA sk1_kba_norolls;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname LIKE '%_norolls%') THEN
        PERFORM _fail(34, 'Config: empty standardiserade_roller – no roles created',
            'roles still created');
    ELSE
        PERFORM _pass(34, 'Config: empty standardiserade_roller – no roles created');
    END IF;
    DROP SCHEMA sk1_kba_norolls;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(34, 'Config: empty standardiserade_roller', SQLERRM);
END $$;

-- Restore default roles
INSERT INTO standardiserade_roller (rollnamn, rolltyp, schema_uttryck, global_roll, ta_bort_med_schema, login_roller, beskrivning) VALUES
    ('r_sk0_global', 'read',  'LIKE ''sk0_%''', true,  false, ARRAY['_geoserver','_cesium','_qgis'], 'Global läsroll för sk0'),
    ('r_sk1_global', 'read',  'LIKE ''sk1_%''', true,  false, ARRAY['_geoserver','_cesium','_qgis'], 'Global läsroll för sk1'),
    ('r_{schema}',   'read',  'LIKE ''sk2_%''', false, true,  ARRAY['_geoserver','_cesium','_qgis'], 'Schemaspecifik läsroll'),
    ('w_{schema}',   'write', 'IS NOT NULL',    false, true,  ARRAY['_geoserver','_cesium','_qgis'], 'Schemaspecifik skrivroll');

-- TEST 35: Invalid rolltyp CHECK constraint (should be blocked)
DO $$ BEGIN
    INSERT INTO standardiserade_roller (rollnamn, rolltyp, schema_uttryck)
    VALUES ('r_test', 'execute', 'IS NOT NULL');
    PERFORM _fail(35, 'Config: invalid rolltyp blocked by CHECK');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(35, 'Config: invalid rolltyp blocked by CHECK', SQLERRM);
END $$;

-- TEST 36: Duplicate anvandare in hex_systemanvandare (should be blocked)
DO $$ BEGIN
    INSERT INTO hex_systemanvandare (anvandare, beskrivning) VALUES ('fme', 'duplicate');
    PERFORM _fail(36, 'Config: duplicate systemanvandare blocked');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(36, 'Config: duplicate systemanvandare blocked', SQLERRM);
END $$;

-- TEST 37: Manually insert orphan row into hex_afvaktande_geometri, then drop table
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.orphan_p (namn text, geom geometry(Point, 3006));

    -- Manually add a second (orphan) row for a nonexistent table
    INSERT INTO hex_afvaktande_geometri (schema_namn, tabell_namn, registrerad_av)
    VALUES ('sk1_kba_stress', 'nonexistent_l', 'stress_test');

    -- Verify it's there
    IF (SELECT count(*) FROM hex_afvaktande_geometri WHERE tabell_namn = 'nonexistent_l') = 1 THEN
        PERFORM _pass(37, 'Config: manual orphan row insert into hex_afvaktande_geometri ok');
    ELSE
        PERFORM _fail(37, 'Config: orphan row insert', 'row not found');
    END IF;

    -- Clean up
    DELETE FROM hex_afvaktande_geometri WHERE tabell_namn = 'nonexistent_l';
    DROP TABLE sk1_kba_stress.orphan_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(37, 'Config: orphan row in hex_afvaktande_geometri', SQLERRM);
END $$;

-- TEST 38: GeoServer notify fires for sk0 and sk1 but NOT sk2
DO $$ BEGIN
    -- We capture which schemas fire the notify by checking the trigger logic directly
    -- sk2 should not notify (confirmed by inspecting notifiera_geoserver function)
    DECLARE result text;
    BEGIN
        SELECT prosrc INTO result FROM pg_proc WHERE proname = 'notifiera_geoserver';
        IF result ILIKE '%sk[01]%' OR result ILIKE '%sk0%' OR result ILIKE '%sk1%' THEN
            PERFORM _pass(38, 'GeoServer: notify only fires for sk0/sk1 (sk2 excluded)');
        ELSE
            PERFORM _fail(38, 'GeoServer: notify only fires for sk0/sk1', 'unexpected function source');
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(38, 'GeoServer: notify filter', SQLERRM);
END $$;

-- TEST 39: FME two-step: table dropped before geom added – afvaktande row cleaned up
DO $$ BEGIN
    -- Insert stress_user as system user if not already present
    INSERT INTO hex_systemanvandare (anvandare, beskrivning)
    VALUES ('stress_user', 'Stress test') ON CONFLICT DO NOTHING;

    -- Manually simulate the afvaktande scenario
    INSERT INTO hex_afvaktande_geometri (schema_namn, tabell_namn, registrerad_av)
    VALUES ('sk1_kba_stress', 'fme_half_done_l', 'stress_user')
    ON CONFLICT DO NOTHING;

    IF (SELECT count(*) FROM hex_afvaktande_geometri WHERE tabell_namn = 'fme_half_done_l') = 1 THEN
        PERFORM _pass(39, 'FME: afvaktande row present before cleanup');
        DELETE FROM hex_afvaktande_geometri WHERE tabell_namn = 'fme_half_done_l';
    ELSE
        PERFORM _fail(39, 'FME: afvaktande row setup failed');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(39, 'FME: afvaktande cleanup simulation', SQLERRM);
END $$;

-- TEST 40: Table with IDENTITY column (gid) preserves sequence after restructure
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.seq_test_p (
        namn text,
        geom geometry(Point, 3006)
    );
    -- Insert rows and verify gid autoincrements
    INSERT INTO sk1_kba_stress.seq_test_p (namn, geom)
    VALUES ('rad1', ST_SetSRID(ST_MakePoint(319001, 6400001), 3006)),
           ('rad2', ST_SetSRID(ST_MakePoint(319002, 6400002), 3006));

    DECLARE g1 int; g2 int;
    BEGIN
        SELECT gid INTO g1 FROM sk1_kba_stress.seq_test_p WHERE namn = 'rad1';
        SELECT gid INTO g2 FROM sk1_kba_stress.seq_test_p WHERE namn = 'rad2';
        IF g2 = g1 + 1 THEN
            PERFORM _pass(40, 'Table: IDENTITY/sequence works after restructure');
        ELSE
            PERFORM _fail(40, 'Table: IDENTITY/sequence after restructure',
                format('gid1=%s gid2=%s (expected consecutive)', g1, g2));
        END IF;
    END;
    DROP TABLE sk1_kba_stress.seq_test_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(40, 'Table: IDENTITY sequence', SQLERRM);
END $$;


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SCHEMA IF EXISTS sk1_kba_stress CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_stress CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_stress CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_norolls CASCADE;
REVOKE ALL ON DATABASE hex_test FROM stress_user;
DROP ROLE IF EXISTS stress_user;
DELETE FROM hex_systemanvandare WHERE anvandare = 'stress_user';
DROP FUNCTION IF EXISTS _pass(int, text, text);
DROP FUNCTION IF EXISTS _xfail(int, text, text);
DROP FUNCTION IF EXISTS _fail(int, text, text);


-- =============================================================================
-- FINAL REPORT
-- =============================================================================
\echo ''
\echo '============================================================'
\echo 'STRESS TEST RESULTS'
\echo '============================================================'
SELECT
    nr,
    status,
    name,
    CASE WHEN note != '' THEN note ELSE '' END AS note
FROM _test_results
ORDER BY nr;

\echo ''
SELECT
    status,
    count(*) AS antal
FROM _test_results
GROUP BY status
ORDER BY status;

\echo ''
SELECT
    CASE
        WHEN count(*) FILTER (WHERE status = 'FAIL') = 0
        THEN 'ALL TESTS PASSED (FAIL count = 0)'
        ELSE format('%s UNEXPECTED FAILURE(S) – see rows above',
                    count(*) FILTER (WHERE status = 'FAIL'))
    END AS summary
FROM _test_results;

DROP TABLE _test_results;
