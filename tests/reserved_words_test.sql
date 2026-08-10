-- =============================================================================
-- HEX TEST FÖR RESERVERADE ORD  (~24 tester)
--
-- Verifierar att tabeller och QA-triggers fungerar korrekt när kolumnnamn är
-- reserverade ord i PostgreSQL eller inbyggda funktionsnamn (t.ex. left, right,
-- select, where, order). Detta skyddar mot en klass av bugg där kolumnlistor
-- byggs med ociterade identifierare, vilket orsakar syntaxfel i den
-- genererade triggerfunktionskroppen.
--
-- Täcker två kodvägar:
--   1. hex_skapa_historik_qa – triggerskapande vid CREATE TABLE
--   2. hex_hantera_ny_kolumn – triggerregenerering vid ALTER TABLE
--
-- Kör som: sudo -u postgres psql -d hex_test -f tests/reserved_words_test.sql
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
-- FÖRBEREDELSE
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS sk1_kba_reswords;
CREATE SCHEMA IF NOT EXISTS sk0_ext_reswords;


-- =============================================================================
-- GRUPP 1: TABELLSKAPANDE  (kodvägen hex_skapa_historik_qa)
-- En _kba_-schematabell med kolumner som är reserverade ord måste:
--   (a) skapas utan fel
--   (b) ge en fungerande _h-historiktabell
--   (c) logga UPDATE- och DELETE-rader via QA-triggern
-- =============================================================================

-- TEST 01: 'left' – inbyggt funktionsnamn; kolumnen som fick FME-körningen att haverera
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_left (
        "left" int
    );
    PERFORM _pass(01, 'Reserverat ord: tabell med kolumnen "left" skapad');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(01, 'Reserverat ord: tabell med kolumnen "left" skapad', SQLERRM);
END $$;

-- TEST 02: historiktabell finns för 'left'-tabellen
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'sk1_kba_reswords' AND tablename = 'hex_left_h'
    ) THEN
        PERFORM _pass(02, 'Reserverat ord: _h-tabell skapad för "left"-tabellen');
    ELSE
        PERFORM _fail(02, 'Reserverat ord: _h-tabell skapad för "left"-tabellen', '_h-tabell saknas');
    END IF;
END $$;

-- TEST 03: UPDATE loggas för 'left'-tabellen (triggerfunktionen genererades korrekt)
DO $$ BEGIN
    INSERT INTO sk1_kba_reswords.hex_left ("left") VALUES (1);
    UPDATE sk1_kba_reswords.hex_left SET "left" = 2 WHERE "left" = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_left_h WHERE h_typ = 'U') THEN
        PERFORM _pass(03, 'Reserverat ord: UPDATE loggad för "left"-tabellen');
    ELSE
        PERFORM _fail(03, 'Reserverat ord: UPDATE loggad för "left"-tabellen', 'ingen U-rad i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(03, 'Reserverat ord: UPDATE på "left"-tabellen', SQLERRM);
END $$;

-- TEST 04: DELETE loggas för 'left'-tabellen
DO $$ BEGIN
    DELETE FROM sk1_kba_reswords.hex_left WHERE "left" = 2;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_left_h WHERE h_typ = 'D') THEN
        PERFORM _pass(04, 'Reserverat ord: DELETE loggad för "left"-tabellen');
    ELSE
        PERFORM _fail(04, 'Reserverat ord: DELETE loggad för "left"-tabellen', 'ingen D-rad i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(04, 'Reserverat ord: DELETE på "left"-tabellen', SQLERRM);
END $$;

-- TEST 05: 'right' – inbyggt funktionsnamn, finns även i FME-shapefilen
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_right (
        "right" int
    );
    INSERT INTO sk1_kba_reswords.hex_right ("right") VALUES (10);
    UPDATE sk1_kba_reswords.hex_right SET "right" = 20 WHERE "right" = 10;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_right_h WHERE h_typ = 'U') THEN
        PERFORM _pass(05, 'Reserverat ord: kolumnen "right" – tabell + trigger ok');
    ELSE
        PERFORM _fail(05, 'Reserverat ord: kolumnen "right" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(05, 'Reserverat ord: kolumnen "right"', SQLERRM);
END $$;

-- TEST 06: 'select' – svåraste fallet, fullt reserverat SQL-nyckelord
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_select (
        "select" text
    );
    INSERT INTO sk1_kba_reswords.hex_select ("select") VALUES ('foo');
    UPDATE sk1_kba_reswords.hex_select SET "select" = 'bar' WHERE "select" = 'foo';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_select_h WHERE h_typ = 'U') THEN
        PERFORM _pass(06, 'Reserverat ord: kolumnen "select" – tabell + trigger ok');
    ELSE
        PERFORM _fail(06, 'Reserverat ord: kolumnen "select" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(06, 'Reserverat ord: kolumnen "select"', SQLERRM);
END $$;

-- TEST 07: 'where'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_where (
        "where" text
    );
    INSERT INTO sk1_kba_reswords.hex_where ("where") VALUES ('here');
    UPDATE sk1_kba_reswords.hex_where SET "where" = 'there' WHERE "where" = 'here';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_where_h WHERE h_typ = 'U') THEN
        PERFORM _pass(07, 'Reserverat ord: kolumnen "where" – tabell + trigger ok');
    ELSE
        PERFORM _fail(07, 'Reserverat ord: kolumnen "where" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(07, 'Reserverat ord: kolumnen "where"', SQLERRM);
END $$;

-- TEST 08: 'order' – vanligt i tabell-/rutnätsdata
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_order (
        "order" int
    );
    INSERT INTO sk1_kba_reswords.hex_order ("order") VALUES (1);
    UPDATE sk1_kba_reswords.hex_order SET "order" = 2 WHERE "order" = 1;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_order_h WHERE h_typ = 'U') THEN
        PERFORM _pass(08, 'Reserverat ord: kolumnen "order" – tabell + trigger ok');
    ELSE
        PERFORM _fail(08, 'Reserverat ord: kolumnen "order" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(08, 'Reserverat ord: kolumnen "order"', SQLERRM);
END $$;

-- TEST 09: 'group'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_group (
        "group" text
    );
    INSERT INTO sk1_kba_reswords.hex_group ("group") VALUES ('A');
    UPDATE sk1_kba_reswords.hex_group SET "group" = 'B' WHERE "group" = 'A';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_group_h WHERE h_typ = 'U') THEN
        PERFORM _pass(09, 'Reserverat ord: kolumnen "group" – tabell + trigger ok');
    ELSE
        PERFORM _fail(09, 'Reserverat ord: kolumnen "group" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(09, 'Reserverat ord: kolumnen "group"', SQLERRM);
END $$;

-- TEST 10: 'check'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_check (
        "check" boolean
    );
    INSERT INTO sk1_kba_reswords.hex_check ("check") VALUES (true);
    UPDATE sk1_kba_reswords.hex_check SET "check" = false WHERE "check" = true;
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_check_h WHERE h_typ = 'U') THEN
        PERFORM _pass(10, 'Reserverat ord: kolumnen "check" – tabell + trigger ok');
    ELSE
        PERFORM _fail(10, 'Reserverat ord: kolumnen "check" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(10, 'Reserverat ord: kolumnen "check"', SQLERRM);
END $$;

-- TEST 11: 'end'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_end (
        "end" date
    );
    INSERT INTO sk1_kba_reswords.hex_end ("end") VALUES ('2026-01-01');
    UPDATE sk1_kba_reswords.hex_end SET "end" = '2026-12-31' WHERE "end" = '2026-01-01';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_end_h WHERE h_typ = 'U') THEN
        PERFORM _pass(11, 'Reserverat ord: kolumnen "end" – tabell + trigger ok');
    ELSE
        PERFORM _fail(11, 'Reserverat ord: kolumnen "end" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(11, 'Reserverat ord: kolumnen "end"', SQLERRM);
END $$;

-- TEST 12: Flera reserverade ord tillsammans – speglar den faktiska FME hex.shp-strukturen
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
        PERFORM _pass(12, 'Reserverat ord: FME hex-replika (left+top+right) – trigger ok');
    ELSE
        PERFORM _fail(12, 'Reserverat ord: FME hex-replika – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(12, 'Reserverat ord: FME hex-replika (left+top+right)', SQLERRM);
END $$;

-- TEST 13: Kolumner med reserverade ord på en geometritabell (_y polygonsuffix)
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
        PERFORM _pass(13, 'Reserverat ord: geometritabell med kolumnerna "order"+"group" – trigger ok');
    ELSE
        PERFORM _fail(13, 'Reserverat ord: geometritabell – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(13, 'Reserverat ord: geometritabell med kolumner som är reserverade ord', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 2: ALTER TABLE  (kodvägen för triggerregenerering i hex_hantera_ny_kolumn)
-- Att lägga till en kolumn med ett reserverat ord i en befintlig
-- historikspårad tabell måste regenerera QA-triggerfunktionen utan syntaxfel.
-- =============================================================================

-- TEST 14: ADD COLUMN 'left' till befintlig tabell – triggern måste regenereras
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.alter_base (
        namn text
    );
    ALTER TABLE sk1_kba_reswords.alter_base ADD COLUMN "left" int;
    INSERT INTO sk1_kba_reswords.alter_base (namn, "left") VALUES ('test', 42);
    UPDATE sk1_kba_reswords.alter_base SET "left" = 99 WHERE namn = 'test';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.alter_base_h WHERE h_typ = 'U') THEN
        PERFORM _pass(14, 'ALTER TABLE: ADD kolumnen "left" – triggern regenererad ok');
    ELSE
        PERFORM _fail(14, 'ALTER TABLE: ADD kolumnen "left" – loggar inte efter regenerering', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(14, 'ALTER TABLE: ADD kolumn med reserverat ord "left"', SQLERRM);
END $$;

-- TEST 15: ADD COLUMN 'select' – svåraste reserverade ordet via ALTER TABLE
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.alter_select (
        namn text
    );
    ALTER TABLE sk1_kba_reswords.alter_select ADD COLUMN "select" text;
    INSERT INTO sk1_kba_reswords.alter_select (namn, "select") VALUES ('x', 'query');
    UPDATE sk1_kba_reswords.alter_select SET "select" = 'statement' WHERE namn = 'x';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.alter_select_h WHERE h_typ = 'U') THEN
        PERFORM _pass(15, 'ALTER TABLE: ADD kolumnen "select" – triggern regenererad ok');
    ELSE
        PERFORM _fail(15, 'ALTER TABLE: ADD kolumnen "select" – loggar inte efter regenerering', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(15, 'ALTER TABLE: ADD kolumn med reserverat ord "select"', SQLERRM);
END $$;

-- TEST 16: ADD flera kolumner med reserverade ord i en enda ALTER TABLE-sats
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
        PERFORM _pass(16, 'ALTER TABLE: ADD flera kolumner med reserverade ord – trigger ok');
    ELSE
        PERFORM _fail(16, 'ALTER TABLE: ADD flera kolumner med reserverade ord – loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(16, 'ALTER TABLE: ADD flera kolumner med reserverade ord', SQLERRM);
END $$;

-- TEST 17: _h-tabellen innehåller kolumnerna med reserverade ord efter ALTER TABLE
DO $$ BEGIN
    DECLARE h_kolumner text;
    BEGIN
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        INTO h_kolumner
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_reswords' AND table_name = 'alter_multi_h';

        IF h_kolumner LIKE '%left%' AND h_kolumner LIKE '%right%' AND h_kolumner LIKE '%order%' THEN
            PERFORM _pass(17, 'ALTER TABLE: kolumner med reserverade ord finns i _h-tabellen');
        ELSE
            PERFORM _fail(17, 'ALTER TABLE: kolumner med reserverade ord i _h-tabellen',
                format('_h-kolumner: %s', h_kolumner));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(17, 'ALTER TABLE: kontrollera _h-kolumner', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 3: SPECIALFALL – fler reserverade/inbyggda ord
-- =============================================================================

-- TEST 18: 'desc' och 'asc' (ORDER BY-modifierare)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_desc_asc (
        "desc" text,
        "asc"  int
    );
    INSERT INTO sk1_kba_reswords.hex_desc_asc ("desc", "asc") VALUES ('descending', 1);
    UPDATE sk1_kba_reswords.hex_desc_asc SET "asc" = 2 WHERE "desc" = 'descending';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_desc_asc_h WHERE h_typ = 'U') THEN
        PERFORM _pass(18, 'Reserverat ord: kolumnerna "desc"/"asc" – trigger ok');
    ELSE
        PERFORM _fail(18, 'Reserverat ord: kolumnerna "desc"/"asc" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(18, 'Reserverat ord: kolumnerna "desc"/"asc"', SQLERRM);
END $$;

-- TEST 19: 'from' och 'to' (vanliga kolumnnamn för intervall i GIS-data)
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_from_to (
        "from" date,
        "to"   date
    );
    INSERT INTO sk1_kba_reswords.hex_from_to ("from", "to") VALUES ('2026-01-01', '2026-12-31');
    UPDATE sk1_kba_reswords.hex_from_to SET "to" = '2027-01-01' WHERE "from" = '2026-01-01';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_from_to_h WHERE h_typ = 'U') THEN
        PERFORM _pass(19, 'Reserverat ord: kolumnerna "from"/"to" – trigger ok');
    ELSE
        PERFORM _fail(19, 'Reserverat ord: kolumnerna "from"/"to" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(19, 'Reserverat ord: kolumnerna "from"/"to"', SQLERRM);
END $$;

-- TEST 20: 'do' och 'in'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_do_in (
        "do" text,
        "in" text
    );
    INSERT INTO sk1_kba_reswords.hex_do_in ("do", "in") VALUES ('action', 'place');
    UPDATE sk1_kba_reswords.hex_do_in SET "do" = 'done' WHERE "in" = 'place';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_do_in_h WHERE h_typ = 'U') THEN
        PERFORM _pass(20, 'Reserverat ord: kolumnerna "do"/"in" – trigger ok');
    ELSE
        PERFORM _fail(20, 'Reserverat ord: kolumnerna "do"/"in" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(20, 'Reserverat ord: kolumnerna "do"/"in"', SQLERRM);
END $$;

-- TEST 21: 'null' och 'not'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_null_not (
        "null" text,
        "not"  boolean
    );
    INSERT INTO sk1_kba_reswords.hex_null_not ("null", "not") VALUES ('value', false);
    UPDATE sk1_kba_reswords.hex_null_not SET "not" = true WHERE "null" = 'value';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_null_not_h WHERE h_typ = 'U') THEN
        PERFORM _pass(21, 'Reserverat ord: kolumnerna "null"/"not" – trigger ok');
    ELSE
        PERFORM _fail(21, 'Reserverat ord: kolumnerna "null"/"not" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(21, 'Reserverat ord: kolumnerna "null"/"not"', SQLERRM);
END $$;

-- TEST 22: 'column' och 'table'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_col_tbl (
        "column" text,
        "table"  text
    );
    INSERT INTO sk1_kba_reswords.hex_col_tbl ("column", "table") VALUES ('col1', 'tbl1');
    UPDATE sk1_kba_reswords.hex_col_tbl SET "column" = 'col2' WHERE "table" = 'tbl1';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_col_tbl_h WHERE h_typ = 'U') THEN
        PERFORM _pass(22, 'Reserverat ord: kolumnerna "column"/"table" – trigger ok');
    ELSE
        PERFORM _fail(22, 'Reserverat ord: kolumnerna "column"/"table" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(22, 'Reserverat ord: kolumnerna "column"/"table"', SQLERRM);
END $$;

-- TEST 23: 'like' och 'is'
DO $$ BEGIN
    CREATE TABLE sk1_kba_reswords.hex_like_is (
        "like" text,
        "is"   text
    );
    INSERT INTO sk1_kba_reswords.hex_like_is ("like", "is") VALUES ('pattern', 'state');
    UPDATE sk1_kba_reswords.hex_like_is SET "is" = 'active' WHERE "like" = 'pattern';
    IF EXISTS (SELECT 1 FROM sk1_kba_reswords.hex_like_is_h WHERE h_typ = 'U') THEN
        PERFORM _pass(23, 'Reserverat ord: kolumnerna "like"/"is" – trigger ok');
    ELSE
        PERFORM _fail(23, 'Reserverat ord: kolumnerna "like"/"is" – triggern loggar inte', 'ingen U i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(23, 'Reserverat ord: kolumnerna "like"/"is"', SQLERRM);
END $$;

-- TEST 24: _ext_-schema (ingen QA-trigger) med kolumner som är reserverade ord – tabellen ändå användbar
-- _ext_-scheman får inte andrad_tidpunkt/andrad_av så ingen trigger skapas;
-- detta test bekräftar att själva tabellen kan skapas och frågas mot utan fel.
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
        PERFORM _pass(24, 'Reserverat ord: _ext_-tabell med kolumner som är reserverade ord skapad och frågebar');
    ELSE
        PERFORM _fail(24, 'Reserverat ord: _ext_-tabell – raden hittades inte efter insättning');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(24, 'Reserverat ord: _ext_-schema med kolumner som är reserverade ord', SQLERRM);
END $$;


-- =============================================================================
-- STÄDNING
-- =============================================================================
DROP SCHEMA IF EXISTS sk1_kba_reswords CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_reswords CASCADE;
DROP FUNCTION IF EXISTS _pass(int, text, text);
DROP FUNCTION IF EXISTS _xfail(int, text, text);
DROP FUNCTION IF EXISTS _fail(int, text, text);


-- =============================================================================
-- SLUTRAPPORT
-- =============================================================================
\echo ''
\echo '============================================================'
\echo 'RESULTAT FÖR TEST AV RESERVERADE ORD'
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
        THEN 'ALLA TESTER GODKÄNDA (antal FAIL = 0)'
        ELSE format('%s OVÄNTAT FEL/FELAKTIGA TESTER – se raderna ovan',
                    count(*) FILTER (WHERE status = 'FAIL'))
    END AS summary
FROM _test_results;

DROP TABLE _test_results;
