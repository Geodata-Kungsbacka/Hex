-- =============================================================================
-- HEX RESERVED WORDS TEST  (~24 tests)
--
-- Verifies that tables and QA triggers work correctly when column names are
-- PostgreSQL reserved words or built-in function names (e.g. left, right,
-- select, where, order).  This guards against a class of bug where column
-- lists are assembled with unquoted identifiers, causing syntax errors in
-- the generated trigger function body.
--
-- Covers two code paths:
--   1. skapa_historik_qa      – trigger creation at CREATE TABLE time
--   2. hantera_kolumntillagg  – trigger regeneration at ALTER TABLE time
--
-- Run as: sudo -u postgres psql -d hex_test -f tests/reserved_words_test.sql
-- =============================================================================

\set ON_ERROR_STOP off
SET client_min_messages = WARNING;

CREATE TABLE IF NOT EXISTS _test_results (
    nr      int,
    name    text,
    status  text,   -- PASS / FAIL / XFAIL
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
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS sk1_kba_reswords;
CREATE SCHEMA IF NOT EXISTS sk0_ext_reswords;


-- =============================================================================
-- GROUP 1: TABLE CREATION  (skapa_historik_qa code path)
-- A _kba_ schema table with reserved-word columns must:
--   (a) create successfully
--   (b) produce a working _h history table
--   (c) log UPDATE and DELETE rows via the QA trigger
-- =============================================================================

-- TEST 01: 'left' – built-in function name; the column that broke the FME run
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_left (
        "left" int
    );
    PERFORM _pass(01, 'Reserved word: table with "left" column created');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(01, 'Reserved word: table with "left" column created', SQLERRM);
END $$;

-- TEST 02: history table exists for 'left' table
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'sk1_kba_reswords' AND tablename = 'hex_left_h'
    ) THEN
        PERFORM _pass(02, 'Reserved word: _h table created for "left" table');
    ELSE
        PERFORM _fail(02, 'Reserved word: _h table created for "left" table', '_h table missing');
    END IF;
END $$;

-- TEST 03: UPDATE is logged for 'left' table (trigger function generated correctly)
DO $$ BEGIN
    INSERT INTO sk1_kba_reswords.hex_left ("left") VALUES (1);
    UPDATE sk1_kba_reswords.hex_left SET "left" = 2 WHERE "left" = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_left_h WHERE h_typ = 'U') THEN
        PERFORM _pass(03, 'Reserved word: UPDATE logged for "left" table');
    ELSE
        PERFORM _fail(03, 'Reserved word: UPDATE logged for "left" table', 'no U row in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(03, 'Reserved word: UPDATE on "left" table', SQLERRM);
END $$;

-- TEST 04: DELETE is logged for 'left' table
DO $$ BEGIN
    DELETE FROM sk1_kba_reswords.hex_left WHERE "left" = 2;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_left_h WHERE h_typ = 'D') THEN
        PERFORM _pass(04, 'Reserved word: DELETE logged for "left" table');
    ELSE
        PERFORM _fail(04, 'Reserved word: DELETE logged for "left" table', 'no D row in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(04, 'Reserved word: DELETE on "left" table', SQLERRM);
END $$;

-- TEST 05: 'right' – built-in function name, also present in the FME shapefile
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_right (
        "right" int
    );
    INSERT INTO sk1_kba_reswords.hex_right ("right") VALUES (10);
    UPDATE sk1_kba_reswords.hex_right SET "right" = 20 WHERE "right" = 10;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_right_h WHERE h_typ = 'U') THEN
        PERFORM _pass(05, 'Reserved word: "right" column – table + trigger ok');
    ELSE
        PERFORM _fail(05, 'Reserved word: "right" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(05, 'Reserved word: "right" column', SQLERRM);
END $$;

-- TEST 06: 'select' – hardest case, fully reserved SQL keyword
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_select (
        "select" text
    );
    INSERT INTO sk1_kba_reswords.hex_select ("select") VALUES ('foo');
    UPDATE sk1_kba_reswords.hex_select SET "select" = 'bar' WHERE "select" = 'foo';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_select_h WHERE h_typ = 'U') THEN
        PERFORM _pass(06, 'Reserved word: "select" column – table + trigger ok');
    ELSE
        PERFORM _fail(06, 'Reserved word: "select" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(06, 'Reserved word: "select" column', SQLERRM);
END $$;

-- TEST 07: 'where'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_where (
        "where" text
    );
    INSERT INTO sk1_kba_reswords.hex_where ("where") VALUES ('here');
    UPDATE sk1_kba_reswords.hex_where SET "where" = 'there' WHERE "where" = 'here';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_where_h WHERE h_typ = 'U') THEN
        PERFORM _pass(07, 'Reserved word: "where" column – table + trigger ok');
    ELSE
        PERFORM _fail(07, 'Reserved word: "where" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(07, 'Reserved word: "where" column', SQLERRM);
END $$;

-- TEST 08: 'order' – common in tabular/grid data
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_order (
        "order" int
    );
    INSERT INTO sk1_kba_reswords.hex_order ("order") VALUES (1);
    UPDATE sk1_kba_reswords.hex_order SET "order" = 2 WHERE "order" = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_order_h WHERE h_typ = 'U') THEN
        PERFORM _pass(08, 'Reserved word: "order" column – table + trigger ok');
    ELSE
        PERFORM _fail(08, 'Reserved word: "order" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(08, 'Reserved word: "order" column', SQLERRM);
END $$;

-- TEST 09: 'group'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_group (
        "group" text
    );
    INSERT INTO sk1_kba_reswords.hex_group ("group") VALUES ('A');
    UPDATE sk1_kba_reswords.hex_group SET "group" = 'B' WHERE "group" = 'A';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_group_h WHERE h_typ = 'U') THEN
        PERFORM _pass(09, 'Reserved word: "group" column – table + trigger ok');
    ELSE
        PERFORM _fail(09, 'Reserved word: "group" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(09, 'Reserved word: "group" column', SQLERRM);
END $$;

-- TEST 10: 'check'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_check (
        "check" boolean
    );
    INSERT INTO sk1_kba_reswords.hex_check ("check") VALUES (true);
    UPDATE sk1_kba_reswords.hex_check SET "check" = false WHERE "check" = true;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_check_h WHERE h_typ = 'U') THEN
        PERFORM _pass(10, 'Reserved word: "check" column – table + trigger ok');
    ELSE
        PERFORM _fail(10, 'Reserved word: "check" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(10, 'Reserved word: "check" column', SQLERRM);
END $$;

-- TEST 11: 'end'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_end (
        "end" date
    );
    INSERT INTO sk1_kba_reswords.hex_end ("end") VALUES ('2026-01-01');
    UPDATE sk1_kba_reswords.hex_end SET "end" = '2026-12-31' WHERE "end" = '2026-01-01';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_end_h WHERE h_typ = 'U') THEN
        PERFORM _pass(11, 'Reserved word: "end" column – table + trigger ok');
    ELSE
        PERFORM _fail(11, 'Reserved word: "end" column – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(11, 'Reserved word: "end" column', SQLERRM);
END $$;

-- TEST 12: Multiple reserved words together – mirrors the actual FME hex.shp structure
--          (id, left, top, right, bottom, row_index, col_index)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_fme_replica (
        id        int,
        "left"    int,
        "top"     int,
        "right"   int,
        bottom    float,
        row_index float,
        col_index float
    );
    INSERT INTO sk1_kba_reswords.hex_fme_replica
        (id, "left", "top", "right", bottom, row_index, col_index)
    VALUES (1, 100, 200, 300, 0.5, 1.0, 2.0);
    UPDATE sk1_kba_reswords.hex_fme_replica SET bottom = 1.5 WHERE id = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_fme_replica_h WHERE h_typ = 'U') THEN
        PERFORM _pass(12, 'Reserved word: FME hex replica (left+top+right) – trigger ok');
    ELSE
        PERFORM _fail(12, 'Reserved word: FME hex replica – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(12, 'Reserved word: FME hex replica (left+top+right)', SQLERRM);
END $$;

-- TEST 13: Reserved-word columns on a geometry table (_y polygon suffix)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_geom_y (
        "order" int,
        "group" text,
        geom    geometry(Polygon, 3006)
    );
    INSERT INTO sk1_kba_reswords.hex_geom_y ("order", "group", geom)
    VALUES (
        1, 'A',
        ST_SetSRID(
            ST_MakePolygon(ST_GeomFromText(
                'LINESTRING(319000 6400000, 319100 6400000, 319100 6400100, 319000 6400100, 319000 6400000)'
            )),
            3006
        )
    );
    UPDATE sk1_kba_reswords.hex_geom_y SET "order" = 2 WHERE "order" = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_geom_y_h WHERE h_typ = 'U') THEN
        PERFORM _pass(13, 'Reserved word: geometry table with "order"+"group" cols – trigger ok');
    ELSE
        PERFORM _fail(13, 'Reserved word: geometry table – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(13, 'Reserved word: geometry table with reserved-word cols', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 2: ALTER TABLE  (hantera_kolumntillagg trigger-regeneration code path)
-- Adding a reserved-word column to an existing history-tracked table must
-- regenerate the QA trigger function without syntax errors.
-- =============================================================================

-- TEST 14: ADD COLUMN 'left' to existing table – trigger must be regenerated
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.alter_base (
        namn text
    );
    ALTER TABLE sk1_kba_reswords.alter_base ADD COLUMN "left" int;
    INSERT INTO sk1_kba_reswords.alter_base (namn, "left") VALUES ('test', 42);
    UPDATE sk1_kba_reswords.alter_base SET "left" = 99 WHERE namn = 'test';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.alter_base_h WHERE h_typ = 'U') THEN
        PERFORM _pass(14, 'ALTER TABLE: ADD "left" column – trigger regenerated ok');
    ELSE
        PERFORM _fail(14, 'ALTER TABLE: ADD "left" column – not logging after regen', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(14, 'ALTER TABLE: ADD reserved-word column "left"', SQLERRM);
END $$;

-- TEST 15: ADD COLUMN 'select' – hardest reserved word via ALTER TABLE
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.alter_select (
        namn text
    );
    ALTER TABLE sk1_kba_reswords.alter_select ADD COLUMN "select" text;
    INSERT INTO sk1_kba_reswords.alter_select (namn, "select") VALUES ('x', 'query');
    UPDATE sk1_kba_reswords.alter_select SET "select" = 'statement' WHERE namn = 'x';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.alter_select_h WHERE h_typ = 'U') THEN
        PERFORM _pass(15, 'ALTER TABLE: ADD "select" column – trigger regenerated ok');
    ELSE
        PERFORM _fail(15, 'ALTER TABLE: ADD "select" column – not logging after regen', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(15, 'ALTER TABLE: ADD reserved-word column "select"', SQLERRM);
END $$;

-- TEST 16: ADD multiple reserved-word columns in a single ALTER TABLE statement
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.alter_multi (
        namn text
    );
    ALTER TABLE sk1_kba_reswords.alter_multi
        ADD COLUMN "left"  int,
        ADD COLUMN "right" int,
        ADD COLUMN "order" int;
    INSERT INTO sk1_kba_reswords.alter_multi (namn, "left", "right", "order")
    VALUES ('row1', 1, 2, 3);
    UPDATE sk1_kba_reswords.alter_multi SET "left" = 10, "right" = 20 WHERE namn = 'row1';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.alter_multi_h WHERE h_typ = 'U') THEN
        PERFORM _pass(16, 'ALTER TABLE: ADD multiple reserved-word cols – trigger ok');
    ELSE
        PERFORM _fail(16, 'ALTER TABLE: ADD multiple reserved-word cols – not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(16, 'ALTER TABLE: ADD multiple reserved-word columns', SQLERRM);
END $$;

-- TEST 17: _h table contains the reserved-word columns after ALTER TABLE
DO $$ BEGIN
    DECLARE h_cols text;
    BEGIN
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        INTO h_cols
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_reswords' AND table_name = 'alter_multi_h';

        IF h_cols LIKE '%left%' AND h_cols LIKE '%right%' AND h_cols LIKE '%order%' THEN
            PERFORM _pass(17, 'ALTER TABLE: reserved-word cols present in _h table');
        ELSE
            PERFORM _fail(17, 'ALTER TABLE: reserved-word cols in _h table',
                format('_h columns: %s', h_cols));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(17, 'ALTER TABLE: check _h columns', SQLERRM);
END $$;


-- =============================================================================
-- GROUP 3: EDGE CASES – more reserved / built-in words
-- =============================================================================

-- TEST 18: 'desc' and 'asc' (ORDER BY modifiers)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_desc_asc (
        "desc" text,
        "asc"  int
    );
    INSERT INTO sk1_kba_reswords.hex_desc_asc ("desc", "asc") VALUES ('descending', 1);
    UPDATE sk1_kba_reswords.hex_desc_asc SET "asc" = 2 WHERE "desc" = 'descending';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_desc_asc_h WHERE h_typ = 'U') THEN
        PERFORM _pass(18, 'Reserved word: "desc"/"asc" columns – trigger ok');
    ELSE
        PERFORM _fail(18, 'Reserved word: "desc"/"asc" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(18, 'Reserved word: "desc"/"asc" columns', SQLERRM);
END $$;

-- TEST 19: 'from' and 'to' (range / interval column names common in GIS data)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_from_to (
        "from" date,
        "to"   date
    );
    INSERT INTO sk1_kba_reswords.hex_from_to ("from", "to") VALUES ('2026-01-01', '2026-12-31');
    UPDATE sk1_kba_reswords.hex_from_to SET "to" = '2027-01-01' WHERE "from" = '2026-01-01';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_from_to_h WHERE h_typ = 'U') THEN
        PERFORM _pass(19, 'Reserved word: "from"/"to" columns – trigger ok');
    ELSE
        PERFORM _fail(19, 'Reserved word: "from"/"to" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(19, 'Reserved word: "from"/"to" columns', SQLERRM);
END $$;

-- TEST 20: 'do' and 'in'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_do_in (
        "do" text,
        "in" text
    );
    INSERT INTO sk1_kba_reswords.hex_do_in ("do", "in") VALUES ('action', 'place');
    UPDATE sk1_kba_reswords.hex_do_in SET "do" = 'done' WHERE "in" = 'place';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_do_in_h WHERE h_typ = 'U') THEN
        PERFORM _pass(20, 'Reserved word: "do"/"in" columns – trigger ok');
    ELSE
        PERFORM _fail(20, 'Reserved word: "do"/"in" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(20, 'Reserved word: "do"/"in" columns', SQLERRM);
END $$;

-- TEST 21: 'null' and 'not'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_null_not (
        "null" text,
        "not"  boolean
    );
    INSERT INTO sk1_kba_reswords.hex_null_not ("null", "not") VALUES ('value', false);
    UPDATE sk1_kba_reswords.hex_null_not SET "not" = true WHERE "null" = 'value';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_null_not_h WHERE h_typ = 'U') THEN
        PERFORM _pass(21, 'Reserved word: "null"/"not" columns – trigger ok');
    ELSE
        PERFORM _fail(21, 'Reserved word: "null"/"not" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(21, 'Reserved word: "null"/"not" columns', SQLERRM);
END $$;

-- TEST 22: 'column' and 'table'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_col_tbl (
        "column" text,
        "table"  text
    );
    INSERT INTO sk1_kba_reswords.hex_col_tbl ("column", "table") VALUES ('col1', 'tbl1');
    UPDATE sk1_kba_reswords.hex_col_tbl SET "column" = 'col2' WHERE "table" = 'tbl1';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_col_tbl_h WHERE h_typ = 'U') THEN
        PERFORM _pass(22, 'Reserved word: "column"/"table" columns – trigger ok');
    ELSE
        PERFORM _fail(22, 'Reserved word: "column"/"table" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(22, 'Reserved word: "column"/"table" columns', SQLERRM);
END $$;

-- TEST 23: 'like' and 'is'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_like_is (
        "like" text,
        "is"   text
    );
    INSERT INTO sk1_kba_reswords.hex_like_is ("like", "is") VALUES ('pattern', 'state');
    UPDATE sk1_kba_reswords.hex_like_is SET "is" = 'active' WHERE "like" = 'pattern';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_like_is_h WHERE h_typ = 'U') THEN
        PERFORM _pass(23, 'Reserved word: "like"/"is" columns – trigger ok');
    ELSE
        PERFORM _fail(23, 'Reserved word: "like"/"is" columns – trigger not logging', 'no U in _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(23, 'Reserved word: "like"/"is" columns', SQLERRM);
END $$;

-- TEST 24: _ext_ schema (no QA trigger) with reserved-word columns – table still usable
-- _ext_ schemas don't get andrad_tidpunkt/andrad_av so no trigger is created;
-- this test confirms the table itself can be created and queried without errors.
DO $$ BEGIN
    CREATE TABLE sk0_ext_reswords.ext_reserved (
        "left"  int,
        "right" int,
        "order" text
    );
    INSERT INTO sk0_ext_reswords.ext_reserved ("left", "right", "order")
    VALUES (1, 2, 'first');
    IF EXISTS (
        SELECT 1 FROM sk0_ext_reswords.ext_reserved WHERE "left" = 1
    ) THEN
        PERFORM _pass(24, 'Reserved word: _ext_ table with reserved-word cols created and queryable');
    ELSE
        PERFORM _fail(24, 'Reserved word: _ext_ table – row not found after insert');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(24, 'Reserved word: _ext_ schema with reserved-word cols', SQLERRM);
END $$;


-- =============================================================================
-- CLEANUP
-- =============================================================================
DROP SCHEMA IF EXISTS sk1_kba_reswords CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_reswords CASCADE;
DROP FUNCTION IF EXISTS _pass(int, text, text);
DROP FUNCTION IF EXISTS _xfail(int, text, text);
DROP FUNCTION IF EXISTS _fail(int, text, text);


-- =============================================================================
-- FINAL REPORT
-- =============================================================================
\echo ''
\echo '============================================================'
\echo 'RESERVED WORDS TEST RESULTS'
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
