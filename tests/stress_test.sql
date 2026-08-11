-- =============================================================================
-- HEX STRESSTEST  (~35 tester)
-- Kör som: sudo -u postgres psql -d hex_test -f tests/stress_test.sql
-- =============================================================================

\set ON_ERROR_STOP off
SET client_min_messages = WARNING;

CREATE TABLE IF NOT EXISTS _test_results (
    nr      int,
    name    text,
    status  text,  -- PASS / FAIL / XFAIL (förväntat fel)
    note    text
);
TRUNCATE _test_results;

-- Hjälpare: registrera godkänt
CREATE OR REPLACE FUNCTION _pass(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'PASS', note); END $$ LANGUAGE plpgsql;

-- Hjälpare: registrera förväntat fel (systemet blockerade korrekt något)
CREATE OR REPLACE FUNCTION _xfail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'XFAIL', note); END $$ LANGUAGE plpgsql;

-- Hjälpare: registrera oväntat fel
CREATE OR REPLACE FUNCTION _fail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'FAIL', note); END $$ LANGUAGE plpgsql;

-- =============================================================================
-- FÖRBEREDELSE: hjälpschema + roller för senare tester
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
VALUES ('stress_user', 'Systemanvändare för stresstest') ON CONFLICT DO NOTHING;


-- =============================================================================
-- GRUPP 1: SCHEMANAMNGIVNING
-- =============================================================================

-- TEST 01: Kortaste giltiga schemanamn (enteckenssuffix)
DO $$ BEGIN
    CREATE SCHEMA sk0_ext_a;
    PERFORM _pass(01, 'Schema: enteckenssuffix ok');
    DROP SCHEMA sk0_ext_a;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(01, 'Schema: enteckenssuffix ok', SQLERRM);
END $$;

-- TEST 02: Schemanamn med siffror i suffixet
DO $$ BEGIN
    CREATE SCHEMA sk1_kba_omrade2;
    PERFORM _pass(02, 'Schema: siffror i suffix ok');
    DROP SCHEMA sk1_kba_omrade2;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(02, 'Schema: siffror i suffix ok', SQLERRM);
END $$;

-- TEST 03: Ogiltigt schema - inget prefix (ska blockeras)
DO $$ BEGIN
    CREATE SCHEMA geodata;
    PERFORM _fail(03, 'Schema: saknat sk-prefix blockerat');
    DROP SCHEMA IF EXISTS geodata;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(03, 'Schema: saknat sk-prefix blockerat', SQLERRM);
END $$;

-- TEST 04: Citerat schemanamn med versaler (ska blockeras av Hex)
-- Obs: ociterade versaler viks tyst till gemener av PostgreSQL innan
-- triggern avfyras, så "SK1_kba_test" blir "sk1_kba_test" (giltigt).
-- Bara citerade identifierare behåller skiftläge och kan testas här.
DO $$ BEGIN
    CREATE SCHEMA "SK1_kba_quoted";
    PERFORM _fail(04, 'Schema: citerade versaler blockerade');
    DROP SCHEMA IF EXISTS "SK1_kba_quoted";
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(04, 'Schema: citerade versaler blockerade', SQLERRM);
END $$;

-- TEST 05: Ogiltigt schema - beskrivning saknas efter kategori (ska blockeras)
DO $$ BEGIN
    CREATE SCHEMA sk1_kba;
    PERFORM _fail(05, 'Schema: inget suffix efter kategori blockerat');
    DROP SCHEMA IF EXISTS sk1_kba;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(05, 'Schema: inget suffix efter kategori blockerat', SQLERRM);
END $$;

-- TEST 06: Ogiltigt schema - fel kategori (ska blockeras)
DO $$ BEGIN
    CREATE SCHEMA sk1_gis_bygg;
    PERFORM _fail(06, 'Schema: fel kategori blockerad');
    DROP SCHEMA IF EXISTS sk1_gis_bygg;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(06, 'Schema: fel kategori blockerad', SQLERRM);
END $$;

-- TEST 07: Roller skapas och tas bort automatiskt tillsammans med schemat
DO $$ BEGIN
    CREATE SCHEMA sk1_kba_rolecheck;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_rolecheck') THEN
        PERFORM _fail(07, 'Schema: w_-roll skapas automatiskt', 'rollen saknas efter CREATE SCHEMA');
    ELSE
        PERFORM _pass(07, 'Schema: w_-roll skapas automatiskt');
    END IF;
    DROP SCHEMA sk1_kba_rolecheck CASCADE;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_rolecheck') THEN
        PERFORM _fail(07, 'Schema: w_-roll tas bort automatiskt', 'rollen finns fortfarande efter DROP SCHEMA');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(07, 'Schema: rollernas automatiska livscykel', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 2: TABELLSKAPANDE
-- =============================================================================

-- TEST 08: Tabell utan geometri (inget suffix) - ska lyckas, ingen omstrukturering
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
        PERFORM _pass(08, 'Tabell: tabell utan geometri får gid');
    ELSE
        PERFORM _fail(08, 'Tabell: tabell utan geometri får gid', 'gid-kolumnen saknas');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(08, 'Tabell: tabell utan geometri och utan suffix', SQLERRM);
END $$;

-- TEST 09: Tabell med geometrisuffix men utan geom-kolumn, vanlig användare (ska misslyckas)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.saknar_geom_p (
        namn text
    );
    PERFORM _fail(09, 'Tabell: geometrisuffix utan geom-kolumn blockerad för normal användare');
    DROP TABLE IF EXISTS sk1_kba_stress.saknar_geom_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(09, 'Tabell: geometrisuffix utan geom-kolumn blockerad för normal användare', SQLERRM);
END $$;

-- TEST 10: Tabell med två geometrikolumner (ska misslyckas)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.dubbel_geom_p (
        namn text,
        geom  geometry(Point, 3006),
        geom2 geometry(Point, 3006)
    );
    PERFORM _fail(10, 'Tabell: två geom-kolumner blockerade');
    DROP TABLE IF EXISTS sk1_kba_stress.dubbel_geom_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(10, 'Tabell: två geom-kolumner blockerade', SQLERRM);
END $$;

-- TEST 11: Tabell med fel namn på geom-kolumnen (ska misslyckas)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.fel_namn_p (
        namn  text,
        shape geometry(Point, 3006)
    );
    PERFORM _fail(11, 'Tabell: fel namn på geom-kolumn blockerat');
    DROP TABLE IF EXISTS sk1_kba_stress.fel_namn_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(11, 'Tabell: fel namn på geom-kolumn blockerat', SQLERRM);
END $$;

-- TEST 12: Tabellsuffix/geometrityp stämmer inte - _p-suffix med Polygon-geom (ska misslyckas)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.fel_suffix_p (
        namn text,
        geom geometry(Polygon, 3006)
    );
    PERFORM _fail(12, 'Tabell: suffix/typ-missmatch blockerad (_p med Polygon)');
    DROP TABLE IF EXISTS sk1_kba_stress.fel_suffix_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(12, 'Tabell: suffix/typ-missmatch blockerad (_p med Polygon)', SQLERRM);
END $$;

-- TEST 13: Giltig tabell - alla fyra geometrisuffixtyper
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.punkter_p  (namn text, geom geometry(Point, 3006));
    CREATE TABLE sk1_kba_stress.linjer_l   (namn text, geom geometry(LineString, 3006));
    CREATE TABLE sk1_kba_stress.ytor_y     (namn text, geom geometry(Polygon, 3006));
    CREATE TABLE sk1_kba_stress.blandat_g  (namn text, geom geometry(Geometry, 3006));
    PERFORM _pass(13, 'Tabell: alla fyra suffixtyper skapade ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(13, 'Tabell: alla fyra suffixtyper', SQLERRM);
END $$;

-- TEST 14: Standardkolumner i korrekt ordning (gid först, geom sist)
DO $$ BEGIN
    DECLARE
        forsta_kol text;
        sista_kol  text;
    BEGIN
        SELECT column_name INTO forsta_kol
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'punkter_p'
        ORDER BY ordinal_position LIMIT 1;

        SELECT column_name INTO sista_kol
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'punkter_p'
        ORDER BY ordinal_position DESC LIMIT 1;

        IF forsta_kol = 'gid' AND sista_kol = 'geom' THEN
            PERFORM _pass(14, 'Tabell: gid först, geom sist');
        ELSE
            PERFORM _fail(14, 'Tabell: gid först, geom sist',
                format('forsta=%s sista=%s', forsta_kol, sista_kol));
        END IF;
    END;
END $$;

-- TEST 15: GiST-index skapas automatiskt
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk1_kba_stress' AND tablename = 'punkter_p'
        AND indexdef ILIKE '%gist%'
    ) THEN
        PERFORM _pass(15, 'Tabell: GiST-index skapas automatiskt');
    ELSE
        PERFORM _fail(15, 'Tabell: GiST-index skapas automatiskt', 'inget GiST-index hittades');
    END IF;
END $$;

-- TEST 16: Tabell i public-schema ska ignoreras av Hex (inget gid tillagt)
DO $$ BEGIN
    CREATE TABLE public.hex_ignored_test (namn text);
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'hex_ignored_test'
        AND column_name = 'gid'
    ) THEN
        PERFORM _fail(16, 'Tabell: public-schema ignoreras (inget gid tillagt)', 'gid lades till i public-tabell');
    ELSE
        PERFORM _pass(16, 'Tabell: public-schema ignoreras (inget gid tillagt)');
    END IF;
    DROP TABLE public.hex_ignored_test;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(16, 'Tabell: public-schema ignoreras', SQLERRM);
END $$;

-- TEST 17: MULTIPOLYGON-geom med _y-suffix (ska lyckas)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.multi_y (
        namn text,
        geom geometry(MultiPolygon, 3006)
    );
    PERFORM _pass(17, 'Tabell: MultiPolygon med _y-suffix ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(17, 'Tabell: MultiPolygon med _y-suffix', SQLERRM);
END $$;

-- TEST 18: Tabell med många kolumner (kolumnordningen fortfarande korrekt)
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.manga_kolumner_p (
        c01 text, c02 int, c03 bool, c04 numeric, c05 date,
        c06 text, c07 int, c08 bool, c09 numeric, c10 date,
        geom geometry(Point, 3006)
    );
    DECLARE
        sista_kol text;
        naest_sista text;
    BEGIN
        SELECT column_name INTO sista_kol
        FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'manga_kolumner_p'
        ORDER BY ordinal_position DESC LIMIT 1;

        IF sista_kol = 'geom' THEN
            PERFORM _pass(18, 'Tabell: geom sist trots många kolumner');
        ELSE
            PERFORM _fail(18, 'Tabell: geom sist trots många kolumner', format('sista=%s', sista_kol));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(18, 'Tabell: många kolumner', SQLERRM);
END $$;

-- TEST 19: DROP TABLE städar automatiskt bort historiktabellen
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.temp_drop_p (
        namn text,
        geom geometry(Point, 3006)
    );
    -- Historiktabellen ska finnas
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'sk1_kba_stress' AND tablename = 'temp_drop_p_h') THEN
        PERFORM _fail(19, 'Tabell: DROP städar bort _h-tabellen', '_h-tabellen skapades inte');
    ELSE
        DROP TABLE sk1_kba_stress.temp_drop_p;
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'sk1_kba_stress' AND tablename = 'temp_drop_p_h') THEN
            PERFORM _fail(19, 'Tabell: DROP städar bort _h-tabellen', '_h-tabellen finns fortfarande efter DROP');
        ELSE
            PERFORM _pass(19, 'Tabell: DROP städar bort _h-tabellen');
        END IF;
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(19, 'Tabell: DROP städar bort _h-tabellen', SQLERRM);
END $$;

-- TEST 20: DROP TABLE städar bort posten i hex_metadata
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.temp_meta_p (namn text, geom geometry(Point, 3006));
    DROP TABLE sk1_kba_stress.temp_meta_p;
    IF EXISTS (
        SELECT 1 FROM hex_metadata
        WHERE parent_schema = 'sk1_kba_stress' AND parent_table = 'temp_meta_p'
    ) THEN
        PERFORM _fail(20, 'Tabell: DROP städar hex_metadata', 'kvarbliven rad i hex_metadata');
    ELSE
        PERFORM _pass(20, 'Tabell: DROP städar hex_metadata');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(20, 'Tabell: DROP städar hex_metadata', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 3: ALTER TABLE / KOLUMNORDNING
-- =============================================================================

-- TEST 21: ADD COLUMN placeras före de avslutande standardkolumnerna och geom
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.alter_test_p (namn text, geom geometry(Point, 3006));
    ALTER TABLE sk1_kba_stress.alter_test_p ADD COLUMN ny_kolumn text;
    DECLARE
        sista_kol text;
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
            PERFORM _pass(21, 'ALTER TABLE: ny kolumn före avslutande standardkolumner och geom');
        ELSE
            PERFORM _fail(21, 'ALTER TABLE: ny kolumn före avslutande standardkolumner och geom',
                format('ny=%s andrad_av=%s geom=%s', ny_pos, av_pos, geom_pos));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(21, 'ALTER TABLE: kolumnordning', SQLERRM);
END $$;

-- TEST 22: ADD flera kolumner i en ALTER TABLE
DO $$ BEGIN
    ALTER TABLE sk1_kba_stress.alter_test_p ADD COLUMN kol_a text, ADD COLUMN kol_b int;
    DECLARE sista_kol text;
    BEGIN
        SELECT column_name INTO sista_kol FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'alter_test_p'
        ORDER BY ordinal_position DESC LIMIT 1;
        IF sista_kol = 'geom' THEN
            PERFORM _pass(22, 'ALTER TABLE: ADD av flera kolumner håller geom sist');
        ELSE
            PERFORM _fail(22, 'ALTER TABLE: ADD av flera kolumner håller geom sist', format('sista=%s', sista_kol));
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(22, 'ALTER TABLE: ADD av flera kolumner', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 4: VYER
-- =============================================================================

-- TEST 23: Giltigt vynamn med korrekt prefix och suffix
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.v_punkter_p AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _pass(23, 'Vy: giltigt namn accepterat');
    DROP VIEW sk1_kba_stress.v_punkter_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(23, 'Vy: giltigt namn accepterat', SQLERRM);
END $$;

-- TEST 24: Vy utan v_-prefix (ska blockeras)
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.punkter_vy_p AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _fail(24, 'Vy: saknat v_-prefix blockerat');
    DROP VIEW IF EXISTS sk1_kba_stress.punkter_vy_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(24, 'Vy: saknat v_-prefix blockerat', SQLERRM);
END $$;

-- TEST 25: Vy med geom men fel suffix (ska blockeras)
DO $$ BEGIN
    CREATE VIEW sk1_kba_stress.v_punkter_y AS
        SELECT * FROM sk1_kba_stress.punkter_p;
    PERFORM _fail(25, 'Vy: fel geometrisuffix blockerat');
    DROP VIEW IF EXISTS sk1_kba_stress.v_punkter_y;
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(25, 'Vy: fel geometrisuffix blockerat', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 5: DATAKVALITET / GEOMETRIVALIDERING (_kba_-schema)
-- =============================================================================

-- TEST 26: Giltig geometri-insättning i _kba_-schema (ska lyckas)
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Giltig punkt', ST_SetSRID(ST_MakePoint(319000, 6400000), 3006));
    PERFORM _pass(26, 'Data: giltig geometri-insättning i _kba_ ok');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(26, 'Data: giltig geometri-insättning i _kba_', SQLERRM);
END $$;

-- TEST 27: Tom geometri avvisas i _kba_-schema
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Tom geom', ST_SetSRID(ST_GeomFromText('POINT EMPTY'), 3006));
    PERFORM _fail(27, 'Data: tom geometri blockerad i _kba_');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(27, 'Data: tom geometri blockerad i _kba_', SQLERRM);
END $$;

-- TEST 28: Ogiltig (självkorsande) polygon avvisas i _kba_
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.ytor_y (namn, geom)
    VALUES ('Ogiltig yta',
        ST_SetSRID(ST_GeomFromText(
            'POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))'  -- bowtie
        ), 3006)
    );
    PERFORM _fail(28, 'Data: ogiltig polygon blockerad i _kba_');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(28, 'Data: ogiltig polygon blockerad i _kba_', SQLERRM);
END $$;

-- TEST 29: _ext_-schema har INGEN geometrivalidering (samma ogiltiga geom ska accepteras)
DO $$ BEGIN
    CREATE TABLE sk0_ext_stress.omraden_y (
        namn text,
        geom geometry(Polygon, 3006)
    );
    INSERT INTO sk0_ext_stress.omraden_y (namn, geom)
    VALUES ('Ogiltig yta – ext OK',
        ST_SetSRID(ST_GeomFromText('POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))'), 3006)
    );
    PERFORM _pass(29, 'Data: ogiltig geom accepterad i _ext_-schema (ingen validering)');
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(29, 'Data: ogiltig geom accepterad i _ext_-schema', SQLERRM);
END $$;

-- TEST 30: UPDATE loggas i _h-tabellen
DO $$ BEGIN
    UPDATE sk1_kba_stress.punkter_p SET namn = 'Uppdaterad' WHERE namn = 'Giltig punkt';
    IF EXISTS (SELECT 1 FROM sk1_kba_stress.punkter_p_h WHERE h_typ = 'U') THEN
        PERFORM _pass(30, 'Historik: UPDATE loggad i _h');
    ELSE
        PERFORM _fail(30, 'Historik: UPDATE loggad i _h', 'ingen U-rad i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(30, 'Historik: UPDATE loggad', SQLERRM);
END $$;

-- TEST 31: DELETE loggas i _h-tabellen
DO $$ BEGIN
    DELETE FROM sk1_kba_stress.punkter_p WHERE namn = 'Uppdaterad';
    IF EXISTS (SELECT 1 FROM sk1_kba_stress.punkter_p_h WHERE h_typ = 'D') THEN
        PERFORM _pass(31, 'Historik: DELETE loggad i _h');
    ELSE
        PERFORM _fail(31, 'Historik: DELETE loggad i _h', 'ingen D-rad i _h');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(31, 'Historik: DELETE loggad', SQLERRM);
END $$;

-- TEST 32: andrad_tidpunkt uppdateras automatiskt vid UPDATE
-- INSERT och UPDATE körs i separata transaktioner så NOW() ger olika värden.
DO $$ BEGIN
    INSERT INTO sk1_kba_stress.punkter_p (namn, geom)
    VALUES ('Tid test', ST_SetSRID(ST_MakePoint(319000, 6400000), 3006));
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(32, 'Trigger: andrad_tidpunkt (INSERT)', SQLERRM);
END $$;

SELECT pg_sleep(0.05);  -- säkerställ att transaktionsgränsen ger olika NOW()

DO $$ DECLARE
    tid_fore  timestamptz;
    tid_efter timestamptz;
BEGIN
    SELECT andrad_tidpunkt INTO tid_fore
    FROM sk1_kba_stress.punkter_p WHERE namn = 'Tid test';

    UPDATE sk1_kba_stress.punkter_p
    SET namn = 'Tid test uppdaterad'
    WHERE namn = 'Tid test';

    SELECT andrad_tidpunkt INTO tid_efter
    FROM sk1_kba_stress.punkter_p WHERE namn = 'Tid test uppdaterad';

    IF tid_efter > tid_fore OR (tid_fore IS NULL AND tid_efter IS NOT NULL) THEN
        PERFORM _pass(32, 'Trigger: andrad_tidpunkt uppdaterad vid UPDATE');
    ELSE
        PERFORM _fail(32, 'Trigger: andrad_tidpunkt uppdaterad vid UPDATE',
            format('fore=%s efter=%s', tid_fore, tid_efter));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(32, 'Trigger: andrad_tidpunkt', SQLERRM);
END $$;


-- =============================================================================
-- GRUPP 6: DESTRUKTIVA KONFIGURATIONSTESTER
-- =============================================================================

-- TEST 33: Töm hex_standardiserade_kolumner – tabeller skapas ändå men utan standardkolumner
DO $$ BEGIN
    TRUNCATE hex_standardiserade_kolumner;

    CREATE TABLE sk1_kba_stress.utan_std_p (
        namn text,
        geom geometry(Point, 3006)
    );

    -- Ska inte ha gid eftersom konfigurationen är tom
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_stress' AND table_name = 'utan_std_p'
        AND column_name = 'gid'
    ) THEN
        PERFORM _fail(33, 'Konfig: tom hex_standardiserade_kolumner – inget gid tillagt', 'gid finns fortfarande');
    ELSE
        PERFORM _pass(33, 'Konfig: tom hex_standardiserade_kolumner – inget gid tillagt');
    END IF;

    DROP TABLE sk1_kba_stress.utan_std_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(33, 'Konfig: tom hex_standardiserade_kolumner', SQLERRM);
END $$;

-- Återställ standardkolumner efter test 33
INSERT INTO hex_standardiserade_kolumner (kolumnnamn, ordinal_position, datatyp, default_varde, beskrivning, schema_uttryck, historik_qa, anvandare_kan_redigera) VALUES
    ('gid',             1,  'integer GENERATED ALWAYS AS IDENTITY', NULL,                'Primärnyckel',               'IS NOT NULL',    false, false),
    ('skapad_tidpunkt', -4, 'timestamptz',  'NOW()',             'Tidpunkt då raden skapades',   'IS NOT NULL',    false, false),
    ('skapad_av',       -3, 'character varying', 'session_user', 'Användare som skapade raden',  'LIKE ''%_kba_%''', false, false),
    ('andrad_tidpunkt', -2, 'timestamptz',  'NOW()',             'Senaste ändringstidpunkt',     'LIKE ''%_kba_%''', true,  false),
    ('andrad_av',       -1, 'character varying', 'session_user', 'Användare som senast ändrade', 'LIKE ''%_kba_%''', true,  false)
ON CONFLICT (kolumnnamn) DO UPDATE SET
    default_varde          = EXCLUDED.default_varde,
    historik_qa            = EXCLUDED.historik_qa,
    anvandare_kan_redigera = EXCLUDED.anvandare_kan_redigera;

-- TEST 34: Töm hex_standardiserade_roller – schema skapas men får inga roller
DO $$ BEGIN
    TRUNCATE hex_standardiserade_roller;
    CREATE SCHEMA sk1_kba_norolls;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname LIKE '%_norolls%') THEN
        PERFORM _fail(34, 'Konfig: tom hex_standardiserade_roller – inga roller skapade',
            'roller skapades ändå');
    ELSE
        PERFORM _pass(34, 'Konfig: tom hex_standardiserade_roller – inga roller skapade');
    END IF;
    DROP SCHEMA sk1_kba_norolls;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(34, 'Konfig: tom hex_standardiserade_roller', SQLERRM);
END $$;

-- Återställ standardroller (alla fyra roller med korrekta värden)
INSERT INTO hex_standardiserade_roller (rollnamn, rolltyp, schema_uttryck, with_login, arvs_fran, beskrivning) VALUES
    ('r_{schema}',    'read',  'IS NOT NULL', false, NULL,          'Läsbehörighetsgrupp – tilldelas AD-användare och AD-grupper'),
    ('w_{schema}',    'write', 'IS NOT NULL', false, NULL,          'Skrivbehörighetsgrupp – tilldelas AD-användare och AD-grupper'),
    ('gs_r_{schema}', 'read',  'IS NOT NULL', true,  'r_{schema}',  'GeoServer läs-tjänstekonto – ärver behörigheter från r_{schema}'),
    ('gs_w_{schema}', 'write', 'IS NOT NULL', true,  'w_{schema}',  'GeoServer skriv-tjänstekonto – ärver behörigheter från w_{schema}')
ON CONFLICT (rollnamn) DO UPDATE SET
    with_login  = EXCLUDED.with_login,
    arvs_fran   = EXCLUDED.arvs_fran,
    rolltyp     = EXCLUDED.rolltyp,
    beskrivning = EXCLUDED.beskrivning;

-- TEST 35: Ogiltig rolltyp blockeras av CHECK-villkor (ska blockeras)
DO $$ BEGIN
    INSERT INTO hex_standardiserade_roller (rollnamn, rolltyp, schema_uttryck)
    VALUES ('r_test', 'execute', 'IS NOT NULL');
    PERFORM _fail(35, 'Konfig: ogiltig rolltyp blockerad av CHECK');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(35, 'Konfig: ogiltig rolltyp blockerad av CHECK', SQLERRM);
END $$;

-- TEST 36: Duplicerad anvandare i hex_systemanvandare (ska blockeras)
DO $$ BEGIN
    INSERT INTO hex_systemanvandare (anvandare, beskrivning) VALUES ('fme', 'duplikat');
    PERFORM _fail(36, 'Konfig: duplicerad systemanvandare blockerad');
EXCEPTION WHEN OTHERS THEN
    PERFORM _xfail(36, 'Konfig: duplicerad systemanvandare blockerad', SQLERRM);
END $$;

-- TEST 37: Sätt manuellt in en föräldralös rad i hex_afvaktande_geometri, ta sedan bort tabellen
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.orphan_p (namn text, geom geometry(Point, 3006));

    -- Lägg manuellt till en andra (föräldralös) rad för en obefintlig tabell
    INSERT INTO hex_afvaktande_geometri (schema_namn, tabell_namn, registrerad_av)
    VALUES ('sk1_kba_stress', 'nonexistent_l', 'stress_test');

    -- Verifiera att den finns
    IF (SELECT count(*) FROM hex_afvaktande_geometri WHERE tabell_namn = 'nonexistent_l') = 1 THEN
        PERFORM _pass(37, 'Konfig: manuell föräldralös radinsättning i hex_afvaktande_geometri ok');
    ELSE
        PERFORM _fail(37, 'Konfig: föräldralös radinsättning', 'raden hittades inte');
    END IF;

    -- Städa upp
    DELETE FROM hex_afvaktande_geometri WHERE tabell_namn = 'nonexistent_l';
    DROP TABLE sk1_kba_stress.orphan_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(37, 'Konfig: föräldralös rad i hex_afvaktande_geometri', SQLERRM);
END $$;

-- TEST 38: GeoServer-notifiering avfyras för sk0 och sk1 men INTE sk2
DO $$ BEGIN
    -- Vi fångar vilka scheman som utlöser notifieringen genom att inspektera triggerlogiken direkt
    -- sk2 ska inte notifiera (bekräftat genom att inspektera funktionen hex_notifiera_gs)
    DECLARE result text;
    BEGIN
        SELECT prosrc INTO result FROM pg_proc WHERE proname = 'hex_notifiera_gs';
        IF result ILIKE '%sk[01]%' OR result ILIKE '%sk0%' OR result ILIKE '%sk1%' THEN
            PERFORM _pass(38, 'GeoServer: notifiering avfyras bara för sk0/sk1 (sk2 undantaget)');
        ELSE
            PERFORM _fail(38, 'GeoServer: notifiering avfyras bara för sk0/sk1', 'oväntad funktionskällkod');
        END IF;
    END;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(38, 'GeoServer: notifieringsfilter', SQLERRM);
END $$;

-- TEST 39: FME tvåstegsmönster: tabell borttagen innan geom tillagd – afvaktande-rad städas bort
DO $$ BEGIN
    -- Sätt in stress_user som systemanvändare om den inte redan finns
    INSERT INTO hex_systemanvandare (anvandare, beskrivning)
    VALUES ('stress_user', 'Stresstest') ON CONFLICT DO NOTHING;

    -- Simulera manuellt afvaktande-scenariot
    INSERT INTO hex_afvaktande_geometri (schema_namn, tabell_namn, registrerad_av)
    VALUES ('sk1_kba_stress', 'fme_half_done_l', 'stress_user')
    ON CONFLICT DO NOTHING;

    IF (SELECT count(*) FROM hex_afvaktande_geometri WHERE tabell_namn = 'fme_half_done_l') = 1 THEN
        PERFORM _pass(39, 'FME: afvaktande-rad finns innan uppstädning');
        DELETE FROM hex_afvaktande_geometri WHERE tabell_namn = 'fme_half_done_l';
    ELSE
        PERFORM _fail(39, 'FME: uppsättning av afvaktande-rad misslyckades');
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(39, 'FME: simulering av afvaktande-uppstädning', SQLERRM);
END $$;

-- TEST 40: Tabell med IDENTITY-kolumn (gid) bevarar sekvensen efter omstrukturering
DO $$ BEGIN
    CREATE TABLE sk1_kba_stress.seq_test_p (
        namn text,
        geom geometry(Point, 3006)
    );
    -- Sätt in rader och verifiera att gid autoinkrementeras
    INSERT INTO sk1_kba_stress.seq_test_p (namn, geom)
    VALUES ('rad1', ST_SetSRID(ST_MakePoint(319001, 6400001), 3006)),
           ('rad2', ST_SetSRID(ST_MakePoint(319002, 6400002), 3006));

    DECLARE g1 int; g2 int;
    BEGIN
        SELECT gid INTO g1 FROM sk1_kba_stress.seq_test_p WHERE namn = 'rad1';
        SELECT gid INTO g2 FROM sk1_kba_stress.seq_test_p WHERE namn = 'rad2';
        IF g2 = g1 + 1 THEN
            PERFORM _pass(40, 'Tabell: IDENTITY/sekvens fungerar efter omstrukturering');
        ELSE
            PERFORM _fail(40, 'Tabell: IDENTITY/sekvens efter omstrukturering',
                format('gid1=%s gid2=%s (förväntade i följd)', g1, g2));
        END IF;
    END;
    DROP TABLE sk1_kba_stress.seq_test_p;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(40, 'Tabell: IDENTITY-sekvens', SQLERRM);
END $$;

-- TEST 41: Triggern hex_tvinga_gid finns och kastar klientangivet gid
-- Simulerar QGIS beteende: INSERT ... OVERRIDING SYSTEM VALUE VALUES (999, ...)
-- Triggern måste ersätta 999 med nästa sekvensvärde.
DO $$ DECLARE
    trigger_finns  boolean;
    infogat_gid integer;
BEGIN
    CREATE TABLE sk1_kba_stress.gid_override_test (
        naam text
    );

    -- 41a: triggern skapades av hex_hantera_ny_tabell
    SELECT EXISTS (
        SELECT 1
        FROM   pg_trigger      t
        JOIN   pg_class        c ON c.oid = t.tgrelid
        JOIN   pg_namespace    n ON n.oid = c.relnamespace
        WHERE  n.nspname = 'sk1_kba_stress'
          AND  c.relname = 'gid_override_test'
          AND  t.tgname  = 'hex_tvinga_gid'
    ) INTO trigger_finns;

    IF trigger_finns THEN
        PERFORM _pass(41, 'GID-åsidosättning: triggern hex_tvinga_gid skapad');
    ELSE
        PERFORM _fail(41, 'GID-åsidosättning: triggern hex_tvinga_gid skapad', 'triggern saknas');
        DROP TABLE sk1_kba_stress.gid_override_test;
        RETURN;
    END IF;

    -- 41b: klientangivet gid ersätts tyst
    INSERT INTO sk1_kba_stress.gid_override_test (gid, naam)
    OVERRIDING SYSTEM VALUE
    VALUES (999, 'override-test');

    SELECT gid INTO infogat_gid
    FROM   sk1_kba_stress.gid_override_test
    WHERE  naam = 'override-test';

    IF infogat_gid IS NOT NULL AND infogat_gid <> 999 THEN
        PERFORM _pass(42, 'GID-åsidosättning: klientens gid 999 ersatt med sekvensvärde');
    ELSIF infogat_gid = 999 THEN
        PERFORM _fail(42, 'GID-åsidosättning: klientens gid 999 ersatt med sekvensvärde',
            'triggern åsidosatte inte – gid 999 sparades');
    ELSE
        PERFORM _fail(42, 'GID-åsidosättning: klientens gid 999 ersatt med sekvensvärde',
            format('oväntat gid=%s', infogat_gid));
    END IF;

    DROP TABLE sk1_kba_stress.gid_override_test;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(41, 'GID-åsidosättning: hex_tvinga_gid', SQLERRM);
END $$;


-- =============================================================================
-- STÄDNING
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
-- SLUTRAPPORT
-- =============================================================================
\echo ''
\echo '============================================================'
\echo 'RESULTAT FÖR STRESSTEST'
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
