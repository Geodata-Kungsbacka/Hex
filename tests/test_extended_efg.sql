-- ============================================================
-- HEX UTÖKAD TESTSVIT — GRUPPERNA E, F & G
--
-- E  Historiktabell-synkronisering (ALTER TABLE ADD COLUMN på kba-tabell)
--    E0  Förutsättning: historiktabellen finns innan synktesterna
--    E1  ADD COLUMN synkas automatiskt till historiktabellen
--    E2  geom förblir sist i både huvud- och historiktabellen efter synk
--    E3  Att lägga till en andra kolumn: båda syns i historiktabellen
--    E4  ADD COLUMN två gånger när redan synkat: inga dubbletter
--
-- F  Dataöverlevnad (befintliga rader överlever ADD COLUMN-omstrukturering)
--    F1  Befintliga rader och numeriska värden intakta efter ADD COLUMN
--    F2  Geometrivärden giltiga och intakta efter ADD COLUMN
--    F3  QA-trigger fungerar efter ADD COLUMN: UPDATE skriver historik + uppdaterar andrad_tidpunkt
--    F4  DELETE skriver till historiktabellen med h_typ='D'
--
-- G  QA-trigger-säkerhet vid ADD COLUMN (kolumnordningsfix)
--    G0  Förutsättning: historiktabell och QA-trigger finns
--    G1  Första ADD COLUMN: inga föräldralösa _temp0001-kolumner
--    G2  Ny kolumn före geom i huvudtabellen
--    G3  Ny kolumn före geom i historiktabellen
--    G4  QA-trigger återaktiverad efter ADD COLUMN (UPDATE skriver historik)
--    G5  Andra ADD COLUMN placerar också kolumnen före geom
--    G6  Inga föräldralösa _temp0001 efter fyra ADD COLUMNs i rad
--    G7  geom sist i båda tabellerna efter fyra ADD COLUMNs
--    G8  ADD COLUMN på tabell med befintliga rader: data intakt, ingen krasch
--    G9  ext-schema ADD COLUMN (ingen QA-trigger): kolumn före geom, inga föräldralösa
--
-- Scheman som används: sk2_kba_test, sk2_ext_test
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX UTÖKAD TESTSVIT — GRUPPERNA E, F & G'
\echo '============================================================'

-- ============================================================
-- Städning och förberedelse
-- ============================================================
DROP SCHEMA IF EXISTS sk2_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_test CASCADE;

CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_ext_test;

-- ============================================================
-- E: AUTOMATISK SYNK AV HISTORIKTABELL (ALTER TABLE ADD COLUMN på kba-tabell)
-- ============================================================
\echo ''
\echo '--- GRUPP E: Automatisk synk av historiktabell vid ALTER TABLE ---'

CREATE TABLE sk2_kba_test.sync_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    ) THEN
        RAISE NOTICE 'TEST E0 PASSED: historiktabellen sync_test_y_h finns innan synktesterna';
    ELSE
        RAISE WARNING 'TEST E0 FAILED: Ingen historiktabell för sync_test_y - kan inte köra E-testerna';
    END IF;
END $$;

ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN extra_data text;

-- E1: Den nya kolumnen måste dyka upp i historiktabellen automatiskt
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
        AND column_name = 'extra_data'
    ) THEN
        RAISE NOTICE 'TEST E1 PASSED: ADD COLUMN extra_data synkades automatiskt till historiktabellen';
    ELSE
        RAISE WARNING 'TEST E1 FAILED: extra_data synkades inte till historiktabellen sync_test_y_h';
    END IF;
END $$;

-- E2: geom måste förbli sist i BÅDE huvudtabellen och historiktabellen efter synk
DO $$
DECLARE
    geom_pos_huvud  integer;
    sista_pos_huvud integer;
    geom_pos_hist   integer;
    sista_pos_hist  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos_huvud FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO sista_pos_huvud FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y';

    SELECT ordinal_position INTO geom_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO sista_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h';

    IF geom_pos_huvud = sista_pos_huvud AND geom_pos_hist = sista_pos_hist THEN
        RAISE NOTICE 'TEST E2 PASSED: geom är sist i både huvudtabellen (pos %/%) och historiken (pos %/%)',
            geom_pos_huvud, sista_pos_huvud, geom_pos_hist, sista_pos_hist;
    ELSE
        RAISE WARNING 'TEST E2 FAILED: geom är inte sist. huvud: %/%, historik: %/%',
            geom_pos_huvud, sista_pos_huvud, geom_pos_hist, sista_pos_hist;
    END IF;
END $$;

-- E3: Att lägga till en andra kolumn - båda ska dyka upp i historiktabellen
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN kategori integer;

DO $$
DECLARE synkade integer;
BEGIN
    SELECT COUNT(*) INTO synkade FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name IN ('extra_data', 'kategori');
    IF synkade = 2 THEN
        RAISE NOTICE 'TEST E3 PASSED: Både extra_data och kategori synkade till historiktabellen';
    ELSE
        RAISE WARNING 'TEST E3 FAILED: Endast % av 2 förväntade kolumner synkade till historiktabellen', synkade;
    END IF;
END $$;

-- E4: Att köra ADD COLUMN två gånger när redan synkat - får inte ge dubbletter
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN stable_col text;
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN another_col text;

DO $$
DECLARE antal_dup integer;
BEGIN
    SELECT COUNT(*) INTO antal_dup FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name = 'stable_col';
    IF antal_dup = 1 THEN
        RAISE NOTICE 'TEST E4 PASSED: stable_col förekommer exakt en gång i historiken (inga dubbletter från upprepade synkar)';
    ELSE
        RAISE WARNING 'TEST E4 FAILED: stable_col förekommer % gånger i historiktabellen (förväntade 1)', antal_dup;
    END IF;
END $$;

-- ============================================================
-- F: DATAÖVERLEVNAD
-- ============================================================
\echo ''
\echo '--- GRUPP F: Dataöverlevnad ---'

CREATE TABLE sk2_kba_test.data_test_y (
    naam       text,
    waarde     numeric(10,2),
    categorie  text,
    geom       geometry(Polygon, 3007)
);

INSERT INTO sk2_kba_test.data_test_y (naam, waarde, categorie, geom) VALUES
    ('objekt_1', 123.45, 'A', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3007)),
    ('objekt_2', 678.90, 'B', ST_GeomFromText('POLYGON((200 200,300 200,300 300,200 300,200 200))', 3007));

-- F1: ADD COLUMN - befintliga rader och värden måste överleva
ALTER TABLE sk2_kba_test.data_test_y ADD COLUMN extra text;

DO $$
DECLARE
    antal_rader integer;
    summa_val   numeric;
BEGIN
    SELECT COUNT(*), SUM(waarde) INTO antal_rader, summa_val
    FROM sk2_kba_test.data_test_y;
    IF antal_rader = 2 AND summa_val = 802.35 THEN
        RAISE NOTICE 'TEST F1 PASSED: Både rader och numeriska värden intakta efter ADD COLUMN (antal=%, summa=%)', antal_rader, summa_val;
    ELSE
        RAISE WARNING 'TEST F1 FAILED: Data bevarades inte. rader=%, summa=%', antal_rader, summa_val;
    END IF;
END $$;

-- F2: Geometrivärden måste överleva ADD COLUMN
DO $$
DECLARE antal_geom integer;
BEGIN
    SELECT COUNT(*) INTO antal_geom
    FROM sk2_kba_test.data_test_y
    WHERE ST_IsValid(geom) AND NOT ST_IsEmpty(geom);
    IF antal_geom = 2 THEN
        RAISE NOTICE 'TEST F2 PASSED: Båda geometrivärdena giltiga och intakta efter ADD COLUMN';
    ELSE
        RAISE WARNING 'TEST F2 FAILED: Förväntade 2 giltiga geometrier, hittade %', antal_geom;
    END IF;
END $$;

-- F3: QA-triggern fungerar efter ADD COLUMN - UPDATE skriver historik och uppdaterar andrad_tidpunkt
DO $$
DECLARE
    antal_hist integer;
    gammal_ts  timestamptz;
    ny_ts      timestamptz;
BEGIN
    SELECT andrad_tidpunkt INTO gammal_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';

    PERFORM pg_sleep(0.05);

    UPDATE sk2_kba_test.data_test_y SET waarde = 999.99 WHERE naam = 'objekt_1';

    SELECT andrad_tidpunkt INTO ny_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';
    SELECT COUNT(*) INTO antal_hist
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_1' AND h_typ = 'U';

    -- andrad_tidpunkt har historik_qa=true så ingen DEFAULT - den börjar som NULL och sätts av
    -- UPDATE-triggern. Kontrollera att ny_ts INTE ÄR NULL och (var NULL eller ökade).
    IF antal_hist = 1 AND ny_ts IS NOT NULL AND (gammal_ts IS NULL OR ny_ts > gammal_ts) THEN
        RAISE NOTICE 'TEST F3 PASSED: UPDATE skrev 1 historikrad och uppdaterade andrad_tidpunkt (gammal=%, ny=%)',
            gammal_ts, ny_ts;
    ELSIF antal_hist = 1 AND ny_ts IS NULL THEN
        RAISE WARNING 'TEST F3 FAILED: Historikrad skrevs men andrad_tidpunkt fortfarande NULL efter UPDATE (gammal=%, ny=%)',
            gammal_ts, ny_ts;
    ELSIF antal_hist = 1 THEN
        RAISE WARNING 'TEST F3 PARTIAL: Historikrad skrevs men andrad_tidpunkt uppdaterades inte (gammal=%, ny=%)',
            gammal_ts, ny_ts;
    ELSE
        RAISE WARNING 'TEST F3 FAILED: Förväntade 1 historikrad, fick %. andrad_tidpunkt: gammal=%, ny=%',
            antal_hist, gammal_ts, ny_ts;
    END IF;
END $$;

-- F4: DELETE skriver till historiktabellen med h_typ='D'
DO $$
DECLARE antal_hist integer;
BEGIN
    DELETE FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_2';
    SELECT COUNT(*) INTO antal_hist
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_2' AND h_typ = 'D';
    IF antal_hist = 1 THEN
        RAISE NOTICE 'TEST F4 PASSED: DELETE skrev 1 historikrad med h_typ=''D''';
    ELSE
        RAISE WARNING 'TEST F4 FAILED: Förväntade 1 DELETE-historikrad, fick %', antal_hist;
    END IF;
END $$;

-- ============================================================
-- G: QA TRIGGER SAFETY DURING ADD COLUMN (COLUMN-ORDER FIX)
--
-- Bug: steg 4 och 5 i hex_hantera_ny_kolumn gör UPDATE-satser
-- för att kopiera kolumndata till en temporär _temp0001-kolumn.
-- QA-triggern (trg_<tabell>_qa) fångar UPDATEn och kör:
--   INSERT INTO <historiktabell> SELECT OLD.*
-- Men historiktabellen har inte _temp0001-kolumnen ännu, vilket ger:
--   "INSERT has more expressions than target columns"
-- EXCEPTION-blocket fångar felet men lämnar _temp0001-kolumnen kvar.
-- Vid nästa ADD COLUMN hittar _temp0001-vakten de föräldralösa
-- kolumnerna och hoppar över steg 3-5 (CONTINUE), vilket gör att
-- geom aldrig flyttas sist → nya kolumner hamnar efter geom.
--
-- Fix: inaktivera QA-triggern innan steg 3/4/5 påbörjas, inte
-- inne i steg 6 efter att felet redan inträffat.
-- ============================================================
\echo ''
\echo '--- GRUPP G: QA-trigger-säkerhet vid ADD COLUMN (kolumnordningsfix) ---'

-- G-setup: färsk kba-tabell som automatiskt får QA-trigger och historiktabell
CREATE TABLE sk2_kba_test.qa_order_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

-- G0: Förutsättning - historiktabell och QA-trigger ska finnas
DO $$
DECLARE
    has_history boolean;
    has_trigger boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h'
    ) INTO has_history;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_schema = 'sk2_kba_test'
          AND event_object_table = 'qa_order_test_y'
          AND trigger_name LIKE 'trg_%_qa'
    ) INTO has_trigger;

    IF has_history AND has_trigger THEN
        RAISE NOTICE 'TEST G0 PASSED: Historiktabell och QA-trigger finns (buggens förutsättningar verifierade)';
    ELSIF NOT has_history THEN
        RAISE WARNING 'TEST G0 FAILED: Ingen historiktabell qa_order_test_y_h - kba-schemauppsättningen är trasig';
    ELSE
        RAISE WARNING 'TEST G0 FAILED: Ingen QA-trigger på qa_order_test_y - triggerskapandet är trasigt';
    END IF;
END $$;

-- G1: Första ADD COLUMN får inte lämna kvar föräldralösa _temp0001-kolumner
--     Bugg: steg 4.1 (ADD _temp0001) lyckades, steg 4.2 (UPDATE) triggade QA-triggern
--     som kraschade med "INSERT has more expressions than target columns".
--     EXCEPTION fångade felet men _temp0001 lämnades kvar.
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_a text;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_order_test_y', 'qa_order_test_y_h')
      AND column_name LIKE '%_temp0001';

    IF orphan_count = 0 THEN
        RAISE NOTICE 'TEST G1 PASSED: Inga föräldralösa _temp0001-kolumner efter första ADD COLUMN (QA-triggern korrekt inaktiverad under omstrukturering)';
    ELSE
        RAISE WARNING 'TEST G1 FAILED: % föräldralösa _temp0001-kolumn(er) - QA-triggern avfyrades under omstrukturerings-UPDATE och lämnade föräldralösa kolumner', orphan_count;
    END IF;
END $$;

-- G2: Ny kolumn ska ligga FÖRE geom i huvudtabellen efter första ADD COLUMN
DO $$
DECLARE
    col_a_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_a_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'col_a';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    IF col_a_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G2 PASSED: col_a (pos %) före geom (pos %/%) i huvudtabellen', col_a_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G2 FAILED: geom är inte sist i huvudtabellen. geom=%, sist=%', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G2 FAILED: col_a (pos %) är efter geom (pos %) - omstrukturering hoppades över (orphan-vakten avfyrades)', col_a_pos, geom_pos;
    END IF;
END $$;

-- G3: Ny kolumn ska ligga FÖRE geom i historiktabellen efter första ADD COLUMN
DO $$
DECLARE
    col_a_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_a_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'col_a';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h';

    IF col_a_pos IS NULL THEN
        RAISE WARNING 'TEST G3 FAILED: col_a hittades inte i historiktabellen - historiksynk misslyckades';
    ELSIF col_a_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G3 PASSED: col_a (pos %) före geom (pos %/%) i historiktabellen', col_a_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G3 FAILED: geom är inte sist i historiken. geom=%, sist=%', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G3 FAILED: col_a (pos %) är efter geom (pos %) i historiktabellen', col_a_pos, geom_pos;
    END IF;
END $$;

-- G4: QA-triggern måste vara återaktiverad efter ADD COLUMN
--     Fixet inaktiverar triggern temporärt - den måste återaktiveras annars skrivs ingen historik.
INSERT INTO sk2_kba_test.qa_order_test_y (info, col_a, geom)
VALUES ('test_rad', 'initial', ST_GeomFromText('POLYGON((0 0,10 0,10 10,0 10,0 0))', 3007));

DO $$
DECLARE hist_count integer;
BEGIN
    UPDATE sk2_kba_test.qa_order_test_y SET col_a = 'updated' WHERE info = 'test_rad';

    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.qa_order_test_y_h
    WHERE info = 'test_rad' AND h_typ = 'U';

    IF hist_count = 1 THEN
        RAISE NOTICE 'TEST G4 PASSED: QA-triggern återaktiverad efter ADD COLUMN - UPDATE skrev 1 historikrad';
    ELSE
        RAISE WARNING 'TEST G4 FAILED: Förväntade 1 historikrad från UPDATE, fick % (QA-triggern kan fortfarande vara inaktiverad)', hist_count;
    END IF;
END $$;

-- G5: Andra ADD COLUMN ska också placera kolumnen FÖRE geom
--     Buggkedja: föräldralösa _temp0001 från G1 skulle göra att _temp0001-vakten
--     hoppar över steg 3-5 vid nästa ADD COLUMN → ny kolumn hamnar efter geom.
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_b integer;

DO $$
DECLARE
    col_b_pos  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT ordinal_position INTO col_b_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'col_b';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    IF col_b_pos < geom_pos AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST G5 PASSED: col_b (pos %) före geom (pos %/%) efter andra ADD COLUMN (ingen föräldralös kedjeeffekt)', col_b_pos, geom_pos, last_pos;
    ELSIF geom_pos != last_pos THEN
        RAISE WARNING 'TEST G5 FAILED: geom är inte sist efter andra ADD COLUMN (geom=%, sist=%). Orphan _temp0001-vakten hoppade troligen över omstruktureringen.', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G5 FAILED: col_b (pos %) efter geom (pos %) - orphan _temp0001-vakten blockerade omstrukturering vid andra ADD COLUMN', col_b_pos, geom_pos;
    END IF;
END $$;

-- G6: Inga föräldralösa _temp0001-kolumner efter flera ADD COLUMNs i rad
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_c boolean;
ALTER TABLE sk2_kba_test.qa_order_test_y ADD COLUMN col_d timestamptz;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_order_test_y', 'qa_order_test_y_h')
      AND column_name LIKE '%_temp0001';

    IF orphan_count = 0 THEN
        RAISE NOTICE 'TEST G6 PASSED: Inga föräldralösa _temp0001-kolumner efter fyra ADD COLUMNs';
    ELSE
        RAISE WARNING 'TEST G6 FAILED: % föräldralösa _temp0001-kolumn(er) efter fyra ADD COLUMNs', orphan_count;
    END IF;
END $$;

-- G7: geom är sist i BÅDA tabellerna efter fyra ADD COLUMNs
DO $$
DECLARE
    geom_pos_main  integer;
    last_pos_main  integer;
    geom_pos_hist  integer;
    last_pos_hist  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y';

    SELECT ordinal_position INTO geom_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_order_test_y_h';

    IF geom_pos_main = last_pos_main AND geom_pos_hist = last_pos_hist THEN
        RAISE NOTICE 'TEST G7 PASSED: geom sist i huvudtabellen (pos %/%) och historiken (pos %/%) efter fyra ADD COLUMNs',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    ELSE
        RAISE WARNING 'TEST G7 FAILED: geom är inte sist. huvudtabell: %/%, historik: %/%',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    END IF;
END $$;

-- G8: ADD COLUMN på tabell MED befintliga rader - omstrukturerings-UPDATE får inte krascha
--     Detta är det exakta scenariot som loggades: QA-triggern fångade UPDATE:n och kraschade
--     när tabellen innehöll rader (INSERT INTO hist SELECT OLD.* misslyckades med felaktigt kolumnantal).
CREATE TABLE sk2_kba_test.qa_rows_test_y (
    naam text,
    geom geometry(Polygon, 3007)
);

INSERT INTO sk2_kba_test.qa_rows_test_y (naam, geom) VALUES
    ('r1', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007)),
    ('r2', ST_GeomFromText('POLYGON((2 2,3 2,3 3,2 3,2 2))', 3007)),
    ('r3', ST_GeomFromText('POLYGON((4 4,5 4,5 5,4 5,4 4))', 3007));

ALTER TABLE sk2_kba_test.qa_rows_test_y ADD COLUMN waarde numeric(10,2);

DO $$
DECLARE
    row_count    integer;
    orphan_count integer;
    col_pos      integer;
    geom_pos     integer;
BEGIN
    SELECT COUNT(*) INTO row_count FROM sk2_kba_test.qa_rows_test_y;

    SELECT COUNT(*) INTO orphan_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test'
      AND table_name IN ('qa_rows_test_y', 'qa_rows_test_y_h')
      AND column_name LIKE '%_temp0001';

    SELECT ordinal_position INTO col_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_rows_test_y' AND column_name = 'waarde';

    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'qa_rows_test_y' AND column_name = 'geom';

    IF row_count = 3 AND orphan_count = 0 AND col_pos < geom_pos THEN
        RAISE NOTICE 'TEST G8 PASSED: ADD COLUMN på tabell med 3 rader: data intakt, inga föräldralösa, waarde (pos %) före geom (pos %)',
            col_pos, geom_pos;
    ELSE
        RAISE WARNING 'TEST G8 FAILED: rader=%, föräldralösa=%, waarde_pos=%, geom_pos=%. Förväntade: rader=3, föräldralösa=0, waarde före geom.',
            row_count, orphan_count, col_pos, geom_pos;
    END IF;
END $$;

-- G9: ext-schema - ADD COLUMN utan QA-trigger (ingen historiktabell)
--     Verifierar att fixet inte bryter tabeller som saknar QA-trigger.
--     DISABLE TRIGGER på en tabell utan den triggern hanteras med EXCEPTION -> NOTICE.
CREATE TABLE sk2_ext_test.ext_order_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_ext_test.ext_order_test_y ADD COLUMN extra text;

DO $$
DECLARE
    extra_pos    integer;
    geom_pos     integer;
    last_pos     integer;
    orphan_count integer;
BEGIN
    SELECT ordinal_position INTO extra_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y' AND column_name = 'extra';
    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y';
    SELECT COUNT(*) INTO orphan_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'ext_order_test_y'
      AND column_name LIKE '%_temp0001';

    IF extra_pos < geom_pos AND geom_pos = last_pos AND orphan_count = 0 THEN
        RAISE NOTICE 'TEST G9 PASSED: ext-schema ADD COLUMN: extra (pos %) före geom (pos %/%), inga föräldralösa',
            extra_pos, geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST G9 FAILED: ext-schema. extra_pos=%, geom_pos=%, last_pos=%, föräldralösa=%',
            extra_pos, geom_pos, last_pos, orphan_count;
    END IF;
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk2_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_test CASCADE;

\echo ''
\echo 'HEX UTÖKAD E, F & G KLAR'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
