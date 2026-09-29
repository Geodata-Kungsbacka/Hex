-- ============================================================
-- HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE
--
-- Testar:
--   1  hex_dummy_geometrier tabell (struktur och rättigheter)
--   2  hex_avvikande_srid tabell (struktur och rättigheter)
--   3  hex_lagg_till_dummy_geometri() (dummy-insättning och registrering)
--   4  hex_ta_bort_dummy_rad() (automatisk dummy-borttagning vid INSERT)
--   5  hex_avvikande_srid registrering vid SRID ≠ 3007
--   6  Rensning vid DROP TABLE (hex_hantera_borttagen_tabell)
--   7  hex_installningar: inställningsbart SRID, dummy-position och
--      hex_underhall():s ombyggnad av hex_avvikande_srid
--
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_dummy_test CASCADE;

CREATE SCHEMA sk0_ext_dummy_test;

-- ============================================================
-- 1: hex_dummy_geometrier tabell
-- ============================================================
\echo ''
\echo '--- GRUPP 1: hex_dummy_geometrier tabellstruktur ---'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'hex_dummy_geometrier') THEN
        RAISE NOTICE 'TEST 1a PASSED: tabellen hex_dummy_geometrier finns';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: tabellen hex_dummy_geometrier saknas';
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'hex_dummy_geometrier'
      AND column_name IN ('schema_namn', 'tabell_namn', 'gid', 'registrerad');
    IF col_count = 4 THEN
        RAISE NOTICE 'TEST 1b PASSED: hex_dummy_geometrier har alla 4 förväntade kolumner';
    ELSE
        RAISE WARNING 'TEST 1b FAILED: Förväntade 4 kolumner, hittade %', col_count;
    END IF;
END $$;

-- Kontrollera att PRIMARY KEY finns (schema_namn, tabell_namn, gid)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'public' AND c.conrelid = 'public.hex_dummy_geometrier'::regclass
          AND c.contype = 'p'
    ) THEN
        RAISE NOTICE 'TEST 1c PASSED: hex_dummy_geometrier har en PRIMARY KEY';
    ELSE
        RAISE WARNING 'TEST 1c FAILED: hex_dummy_geometrier saknar PRIMARY KEY';
    END IF;
END $$;

-- ============================================================
-- 2: hex_avvikande_srid tabell
-- ============================================================
\echo ''
\echo '--- GRUPP 2: hex_avvikande_srid tabellstruktur ---'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'hex_avvikande_srid') THEN
        RAISE NOTICE 'TEST 2a PASSED: tabellen hex_avvikande_srid finns';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: tabellen hex_avvikande_srid saknas';
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'hex_avvikande_srid'
      AND column_name IN ('schema_namn', 'tabell_namn', 'srid', 'registrerad', 'registrerad_av');
    IF col_count = 5 THEN
        RAISE NOTICE 'TEST 2b PASSED: hex_avvikande_srid har alla 5 förväntade kolumner';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: Förväntade 5 kolumner, hittade %', col_count;
    END IF;
END $$;

-- Kontrollera att PRIMARY KEY är (schema_namn, tabell_namn)
DO $$
DECLARE pk_cols text;
BEGIN
    SELECT string_agg(a.attname, ', ' ORDER BY k.n)
    INTO pk_cols
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, n) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE n.nspname = 'public'
      AND c.conrelid = 'public.hex_avvikande_srid'::regclass
      AND c.contype = 'p';

    IF pk_cols = 'schema_namn, tabell_namn' THEN
        RAISE NOTICE 'TEST 2c PASSED: hex_avvikande_srid PRIMARY KEY är (schema_namn, tabell_namn)';
    ELSE
        RAISE WARNING 'TEST 2c FAILED: Förväntade PK (schema_namn, tabell_namn), fick: %', pk_cols;
    END IF;
END $$;

-- ============================================================
-- 3: hex_lagg_till_dummy_geometri — dummy sätts in vid CREATE TABLE
-- ============================================================
\echo ''
\echo '--- GRUPP 3: hex_lagg_till_dummy_geometri() ---'

CREATE TABLE sk0_ext_dummy_test.punker_p (
    beskrivning text,
    geom geometry(Point, 3007)
);

-- 3a: hex_dummy_geometrier innehåller en rad för den nya tabellen
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 3a PASSED: dummy-rad registrerad i hex_dummy_geometrier för punker_p';
    ELSE
        RAISE WARNING 'TEST 3a FAILED: Ingen post i hex_dummy_geometrier för punker_p';
    END IF;
END $$;

-- 3b: Själva tabellen innehåller exakt 1 rad (dummyn)
DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 1 THEN
        RAISE NOTICE 'TEST 3b PASSED: punker_p innehåller exakt 1 dummy-rad';
    ELSE
        RAISE WARNING 'TEST 3b FAILED: Förväntade 1 dummy-rad, hittade %', row_count;
    END IF;
END $$;

-- 3c: Dummy-raden har en giltig, icke-tom Point-geometri
DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk0_ext_dummy_test.punker_p
    WHERE ST_GeometryType(geom) = 'ST_Point' AND NOT ST_IsEmpty(geom);
    IF geom_count = 1 THEN
        RAISE NOTICE 'TEST 3c PASSED: Dummy-raden har giltig icke-tom Point-geometri';
    ELSE
        RAISE WARNING 'TEST 3c FAILED: Förväntade 1 giltig Point-geometri, hittade %', geom_count;
    END IF;
END $$;

-- 3d: hex_ta_bort_dummy-triggern finns på tabellen
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_dummy_test'
          AND c.relname = 'punker_p'
          AND t.tgname = 'hex_ta_bort_dummy'
    ) THEN
        RAISE NOTICE 'TEST 3d PASSED: hex_ta_bort_dummy-triggern installerad på punker_p';
    ELSE
        RAISE WARNING 'TEST 3d FAILED: hex_ta_bort_dummy-triggern saknas på punker_p';
    END IF;
END $$;

-- 3e: Polygon-tabell får också korrekt geometrityp i dummyn
CREATE TABLE sk0_ext_dummy_test.omraden_y (
    namn text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk0_ext_dummy_test.omraden_y
    WHERE ST_GeometryType(geom) = 'ST_Polygon' AND NOT ST_IsEmpty(geom);
    IF geom_count = 1 THEN
        RAISE NOTICE 'TEST 3e PASSED: Polygon-tabellen omraden_y har giltig Polygon-dummy-rad';
    ELSE
        RAISE WARNING 'TEST 3e FAILED: Förväntade 1 Polygon-dummy, hittade %', geom_count;
    END IF;
END $$;

-- ============================================================
-- 4: hex_ta_bort_dummy_rad — dummyn tas bort automatiskt vid första riktiga INSERT
-- ============================================================
\echo ''
\echo '--- GRUPP 4: hex_ta_bort_dummy_rad() ---'

-- 4a: Före riktig insättning finns dummyn kvar
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 4a PASSED: Dummy-spårningsraden finns fortfarande kvar före första riktiga INSERT';
    ELSE
        RAISE WARNING 'TEST 4a FAILED: Dummy-spårningsraden försvann för tidigt';
    END IF;
END $$;

-- Sätt in första riktiga raden
INSERT INTO sk0_ext_dummy_test.punker_p (beskrivning, geom)
VALUES ('riktig punkt', ST_GeomFromText('POINT(319000 6400000)', 3007));

-- 4b: Efter riktig insättning är dummy-raden borttagen från tabellen
DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 1 THEN
        RAISE NOTICE 'TEST 4b PASSED: Endast 1 rad kvar efter första riktiga INSERT (dummy borttagen)';
    ELSE
        RAISE WARNING 'TEST 4b FAILED: Förväntade 1 rad (endast riktig), hittade % (dummyn kanske inte togs bort)', row_count;
    END IF;
END $$;

-- 4c: Den kvarvarande raden är den riktiga (har vårt kända beskrivningsvärde)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM sk0_ext_dummy_test.punker_p
        WHERE beskrivning = 'riktig punkt'
    ) THEN
        RAISE NOTICE 'TEST 4c PASSED: Kvarvarande rad är den riktiga dataraden';
    ELSE
        RAISE WARNING 'TEST 4c FAILED: Riktig datarad hittades inte efter dummy-borttagning';
    END IF;
END $$;

-- 4d: hex_dummy_geometrier-posten städad
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 4d PASSED: hex_dummy_geometrier-posten städad efter riktig INSERT';
    ELSE
        RAISE WARNING 'TEST 4d FAILED: hex_dummy_geometrier har fortfarande en post för punker_p efter riktig INSERT';
    END IF;
END $$;

-- 4e: hex_ta_bort_dummy-triggern finns fortfarande kvar (ofarlig efter att dummyn tagits bort)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_dummy_test'
          AND c.relname = 'punker_p'
          AND t.tgname = 'hex_ta_bort_dummy'
    ) THEN
        RAISE NOTICE 'TEST 4e PASSED: hex_ta_bort_dummy-triggern finns fortfarande kvar (ofarlig - early-exit-spärr aktiv)';
    ELSE
        RAISE WARNING 'TEST 4e INFO: hex_ta_bort_dummy-triggern togs bort efter dummy-städning';
    END IF;
END $$;

-- 4f: Efterföljande insättningar fungerar problemfritt (triggern blir en no-op)
INSERT INTO sk0_ext_dummy_test.punker_p (beskrivning, geom)
VALUES ('andra riktiga punkten', ST_GeomFromText('POINT(319001 6400001)', 3007));

DO $$
DECLARE row_count integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk0_ext_dummy_test.punker_p;
    IF row_count = 2 THEN
        RAISE NOTICE 'TEST 4f PASSED: Andra INSERT fungerar problemfritt, triggern är en ofarlig no-op (2 rader totalt)';
    ELSE
        RAISE WARNING 'TEST 4f FAILED: Förväntade 2 rader efter andra INSERT, hittade %', row_count;
    END IF;
END $$;

-- ============================================================
-- 5: hex_avvikande_srid — registreras vid SRID ≠ 3007
-- ============================================================
\echo ''
\echo '--- GRUPP 5: hex_avvikande_srid-registrering ---'

-- 5a: Tabell med korrekt SRID (3007) ska INTE finnas i hex_avvikande_srid
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 5a PASSED: Tabell med SRID 3007 ej registrerad i hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5a FAILED: Tabell med SRID 3007 felaktigt registrerad som avvikande';
    END IF;
END $$;

-- Skapa en tabell med SRID 3006 (felaktig — ska flaggas)
CREATE TABLE sk0_ext_dummy_test.fel_srid_y (
    namn text,
    geom geometry(Polygon, 3006)
);

-- 5b: Tabell med SRID 3006 ska finnas i hex_avvikande_srid
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y'
    ) THEN
        RAISE NOTICE 'TEST 5b PASSED: Tabell med SRID 3006 registrerad i hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5b FAILED: Tabell med SRID 3006 ej registrerad i hex_avvikande_srid';
    END IF;
END $$;

-- 5c: Det lagrade SRID-värdet är korrekt (3006)
DO $$
DECLARE stored_srid integer;
BEGIN
    SELECT srid INTO stored_srid
    FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y';
    IF stored_srid = 3006 THEN
        RAISE NOTICE 'TEST 5c PASSED: Lagrad SRID är 3006 (korrekt registrerad)';
    ELSE
        RAISE WARNING 'TEST 5c FAILED: Förväntade lagrad SRID 3006, fick %', stored_srid;
    END IF;
END $$;

-- 5d: Tabell med korrekt SRID — ADD COLUMN (användarkolumn, ej geom) ska INTE utlösa avvikande
ALTER TABLE sk0_ext_dummy_test.punker_p ADD COLUMN kategori text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'punker_p'
    ) THEN
        RAISE NOTICE 'TEST 5d PASSED: ADD COLUMN (icke-geom) på SRID-3007-tabell skapar ingen avvikande-post';
    ELSE
        RAISE WARNING 'TEST 5d FAILED: Oväntad avvikande-post för SRID-3007-tabell efter ADD COLUMN';
    END IF;
END $$;

-- 5e: Två tabeller med olika felaktiga SRID — båda finns i hex_avvikande_srid
CREATE TABLE sk0_ext_dummy_test.annan_srid_y (
    namn text,
    geom geometry(Polygon, 4326)
);

DO $$
DECLARE srid_val integer;
BEGIN
    SELECT srid INTO srid_val
    FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'annan_srid_y';
    IF srid_val = 4326 THEN
        RAISE NOTICE 'TEST 5e PASSED: Tabell med SRID 4326 registrerad med korrekt SRID i hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 5e FAILED: Förväntade SRID 4326 för annan_srid_y, fick %', srid_val;
    END IF;
END $$;

-- ============================================================
-- 6: Städning — hex_dummy_geometrier och hex_avvikande_srid
--    rensas när tabeller tas bort
-- ============================================================
\echo ''
\echo '--- GRUPP 6: Städning vid DROP TABLE ---'

-- Kontrollera nuvarande tillstånd: båda avvikande tabellerna registrerade
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test';
    IF cnt >= 1 THEN
        RAISE NOTICE 'TEST 6a PASSED: Minst 1 avvikande SRID-post före DROP (antal=%)', cnt;
    ELSE
        RAISE WARNING 'TEST 6a INFO: Förväntade minst 1 avvikande SRID-post, hittade %', cnt;
    END IF;
END $$;

DROP TABLE sk0_ext_dummy_test.fel_srid_y;

-- 6b: Efter att den avvikande tabellen tagits bort är dess post borttagen
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'fel_srid_y'
    ) THEN
        RAISE NOTICE 'TEST 6b PASSED: hex_avvikande_srid-posten borttagen efter DROP TABLE';
    ELSE
        RAISE WARNING 'TEST 6b FAILED: hex_avvikande_srid-posten inte städad efter DROP TABLE';
    END IF;
END $$;

-- 6c: Att ta bort en tabell som har en dummy (omraden_y har fortfarande dummy eftersom inga riktiga rader satts in)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'omraden_y'
    ) THEN
        RAISE NOTICE 'TEST 6c PASSED: omraden_y-dummyn fortfarande spårad före DROP';
    ELSE
        RAISE WARNING 'TEST 6c INFO: omraden_y-dummyns spårningspost redan borta före DROP';
    END IF;
END $$;

DROP TABLE sk0_ext_dummy_test.omraden_y;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'omraden_y'
    ) THEN
        RAISE NOTICE 'TEST 6d PASSED: hex_dummy_geometrier-posten borttagen efter DROP TABLE omraden_y';
    ELSE
        RAISE WARNING 'TEST 6d FAILED: hex_dummy_geometrier-posten inte städad efter DROP TABLE';
    END IF;
END $$;

-- ============================================================
-- 7: hex_installningar — inställningsbart SRID och dummy-position
-- ============================================================
\echo ''
\echo '--- GRUPP 7: hex_installningar (srid, dummy_x/dummy_y) ---'

-- 7a: Standardvärden
DO $$
DECLARE antal integer;
BEGIN
    SELECT count(*) INTO antal FROM public.hex_installningar;
    IF antal = 1 AND public.hex_srid() = 3007
       AND public.hex_srid_namn(3007) = 'SWEREF99 12 00' THEN
        RAISE NOTICE 'TEST 7a PASSED: en rad, hex_srid() = 3007 (SWEREF99 12 00)';
    ELSE
        RAISE WARNING 'TEST 7a FAILED: antal=%, hex_srid()=%, namn=%',
            antal, public.hex_srid(), public.hex_srid_namn(3007);
    END IF;
END $$;

-- 7b–7c: Bara en rad, och bara SRID som finns i spatial_ref_sys
DO $$
BEGIN
    BEGIN
        INSERT INTO public.hex_installningar (id) VALUES (false);
        RAISE WARNING 'TEST 7b FAILED: en andra rad (id = false) accepterades';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'TEST 7b PASSED: en andra rad avvisas';
    END;
    BEGIN
        UPDATE public.hex_installningar SET srid = 999999;
        RAISE WARNING 'TEST 7c FAILED: SRID som saknas i spatial_ref_sys accepterades';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'TEST 7c PASSED: SRID som saknas i spatial_ref_sys avvisas';
    END;
END $$;

-- 7d: Dummy i en 3007-tabell hamnar på (dummy_x, dummy_y)
CREATE TABLE sk0_ext_dummy_test.pos_sweref1200_p (namn text, geom geometry(Point, 3007));
-- 7e: Dummy i en 3006-tabell transformeras till samma plats
CREATE TABLE sk0_ext_dummy_test.pos_sweref99tm_p (namn text, geom geometry(Point, 3006));

DO $$
DECLARE
    g3007 geometry;
    g3006 geometry;
    ref   geometry := ST_SetSRID(ST_MakePoint(160000, 6395000), 3007);
BEGIN
    SELECT t.geom INTO g3007
    FROM   sk0_ext_dummy_test.pos_sweref1200_p t
    JOIN   public.hex_dummy_geometrier d
           ON d.schema_namn = 'sk0_ext_dummy_test' AND d.tabell_namn = 'pos_sweref1200_p'
          AND d.gid = t.gid;
    SELECT t.geom INTO g3006
    FROM   sk0_ext_dummy_test.pos_sweref99tm_p t
    JOIN   public.hex_dummy_geometrier d
           ON d.schema_namn = 'sk0_ext_dummy_test' AND d.tabell_namn = 'pos_sweref99tm_p'
          AND d.gid = t.gid;

    IF g3007 IS NOT NULL AND ST_Equals(g3007, ref) THEN
        RAISE NOTICE 'TEST 7d PASSED: dummy i 3007-tabell ligger på (160000, 6395000)';
    ELSE
        RAISE WARNING 'TEST 7d FAILED: dummy i 3007-tabell: %', ST_AsEWKT(g3007);
    END IF;

    IF g3006 IS NOT NULL AND ST_SRID(g3006) = 3006
       AND ST_Distance(ST_Transform(g3006, 3007), ref) < 0.01 THEN
        RAISE NOTICE 'TEST 7e PASSED: dummy i 3006-tabell transformerad till samma plats';
    ELSE
        RAISE WARNING 'TEST 7e FAILED: dummy i 3006-tabell: %', ST_AsEWKT(g3006);
    END IF;
END $$;

-- Byt förväntat koordinatsystem till 3006 och flytta referenspunkten dit.
-- Spara registrerad för 4326-tabellen, som avviker både före och efter.
CREATE TEMP TABLE tmp_hex_srid_fore AS
SELECT registrerad FROM public.hex_avvikande_srid
WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'annan_srid_y';

UPDATE public.hex_installningar
SET    srid    = 3006,
       dummy_x = ST_X(p.g),
       dummy_y = ST_Y(p.g)
FROM   (SELECT ST_Transform(ST_SetSRID(ST_MakePoint(160000, 6395000), 3007), 3006) AS g) p;

CREATE TEMP TABLE tmp_hex_underhall AS
SELECT * FROM public.hex_underhall() u WHERE u.trigger_namn = 'avvikande_srid';

-- 7f–7h: hex_underhall() bygger om hex_avvikande_srid mot det nya SRID:t
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.hex_avvikande_srid
               WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'pos_sweref1200_p'
                 AND srid = 3007)
       AND EXISTS (SELECT 1 FROM tmp_hex_underhall
                   WHERE tabell_namn = 'pos_sweref1200_p' AND atgard = 'registrerad: SRID 3007') THEN
        RAISE NOTICE 'TEST 7f PASSED: 3007-tabell registrerad som avvikande efter byte till 3006';
    ELSE
        RAISE WARNING 'TEST 7f FAILED: 3007-tabell inte registrerad efter byte till 3006';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.hex_avvikande_srid
                   WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'pos_sweref99tm_p')
       AND EXISTS (SELECT 1 FROM tmp_hex_underhall
                   WHERE tabell_namn = 'pos_sweref99tm_p' AND atgard = 'avregistrerad') THEN
        RAISE NOTICE 'TEST 7g PASSED: 3006-tabell avregistrerad efter byte till 3006';
    ELSE
        RAISE WARNING 'TEST 7g FAILED: 3006-tabell ligger kvar som avvikande';
    END IF;

    IF (SELECT registrerad FROM public.hex_avvikande_srid
        WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'annan_srid_y')
       = (SELECT registrerad FROM tmp_hex_srid_fore)
       AND EXISTS (SELECT 1 FROM tmp_hex_underhall
                   WHERE tabell_namn = 'annan_srid_y' AND atgard = 'redan finns') THEN
        RAISE NOTICE 'TEST 7h PASSED: 4326-tabell orörd (registrerad står kvar)';
    ELSE
        RAISE WARNING 'TEST 7h FAILED: 4326-tabellens rad skrevs om eller försvann';
    END IF;
END $$;

-- 7i–7k: Triggrarna och dummyn följer den nya inställningen
CREATE TABLE sk0_ext_dummy_test.ny_sweref99tm_p (namn text, geom geometry(Point, 3006));
CREATE TABLE sk0_ext_dummy_test.ny_sweref1200_p (namn text, geom geometry(Point, 3007));

DO $$
DECLARE
    g   geometry;
    ref geometry := ST_SetSRID(ST_MakePoint(160000, 6395000), 3007);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hex_avvikande_srid
                   WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'ny_sweref99tm_p') THEN
        RAISE NOTICE 'TEST 7i PASSED: ny 3006-tabell inte avvikande när hex_srid() = 3006';
    ELSE
        RAISE WARNING 'TEST 7i FAILED: ny 3006-tabell registrerad som avvikande';
    END IF;

    IF EXISTS (SELECT 1 FROM public.hex_avvikande_srid
               WHERE schema_namn = 'sk0_ext_dummy_test' AND tabell_namn = 'ny_sweref1200_p'
                 AND srid = 3007) THEN
        RAISE NOTICE 'TEST 7j PASSED: ny 3007-tabell avvikande när hex_srid() = 3006';
    ELSE
        RAISE WARNING 'TEST 7j FAILED: ny 3007-tabell inte registrerad som avvikande';
    END IF;

    SELECT t.geom INTO g
    FROM   sk0_ext_dummy_test.ny_sweref99tm_p t
    JOIN   public.hex_dummy_geometrier d
           ON d.schema_namn = 'sk0_ext_dummy_test' AND d.tabell_namn = 'ny_sweref99tm_p'
          AND d.gid = t.gid;
    IF g IS NOT NULL AND ST_Distance(ST_Transform(g, 3007), ref) < 0.01 THEN
        RAISE NOTICE 'TEST 7k PASSED: dummy byggd från 3006-inställningen ligger på samma plats';
    ELSE
        RAISE WARNING 'TEST 7k FAILED: dummy i ny 3006-tabell: %', ST_AsEWKT(g);
    END IF;
END $$;

-- Återställ standardvärdena. Körs oavsett utfall ovan.
UPDATE public.hex_installningar
SET    srid = 3007, dummy_x = 160000, dummy_y = 6395000, dummy_storlek = 100;
SELECT count(*) AS avvikande_srid_atgarder
FROM   public.hex_underhall() u WHERE u.trigger_namn = 'avvikande_srid';

-- 7l: Efter återställning är 3007-tabellerna inte längre avvikande, 3006 är det
DO $$
DECLARE antal_3006 integer;
BEGIN
    SELECT count(*) INTO antal_3006 FROM public.hex_avvikande_srid
    WHERE schema_namn = 'sk0_ext_dummy_test'
      AND tabell_namn IN ('pos_sweref99tm_p', 'ny_sweref99tm_p');
    IF NOT EXISTS (SELECT 1 FROM public.hex_avvikande_srid
                   WHERE schema_namn = 'sk0_ext_dummy_test'
                     AND tabell_namn IN ('pos_sweref1200_p', 'ny_sweref1200_p'))
       AND antal_3006 = 2 THEN
        RAISE NOTICE 'TEST 7l PASSED: återställning till 3007 byggde om hex_avvikande_srid';
    ELSE
        RAISE WARNING 'TEST 7l FAILED: hex_avvikande_srid stämmer inte efter återställning (3006-rader: %)',
            antal_3006;
    END IF;
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_dummy_test CASCADE;

\echo ''
\echo 'HEX DUMMY GEOMETRI & AVVIKANDE SRID TEST SUITE SLUTFÖRD'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED'
