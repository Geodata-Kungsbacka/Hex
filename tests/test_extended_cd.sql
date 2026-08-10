-- ============================================================
-- HEX UTÖKAD TESTSVIT — GRUPPERNA C & D
--
-- C  Klient-simulering (GeoServer, QGIS, FME)
--    C1  GeoServer application_name: full omstrukturering körs ändå
--    C2  QGIS application_name: full kba-behandling (andrad_tidpunkt + historik)
--    C3  FME application_name: omstrukturering körs ändå
--    C4  GeoServer/QGIS-liknande metadatafrågor är säkra
--    C5  QGIS-liknande EXPLAIN på geometrifråga fungerar
--
-- D  Strukturella specialfall och adversariella tester
--    D1  CREATE UNLOGGED TABLE: UNLOGGED tappas tyst under omstrukturering
--    D2  CREATE TABLE IF NOT EXISTS (ny tabell): omstruktureras normalt
--    D3  CREATE TABLE IF NOT EXISTS (befintlig tabell): säker no-op
--    D4  CREATE TABLE LIKE: kopierar struktur, Hex lägger till gid + GiST-index
--    D5  ALTER TABLE RENAME TO: namnbyte på historiktabell spåras via OID
--    D6  ADD COLUMN och sedan DROP av användarkolumn: inga föräldralösa _temp0001
--    D7  DROP av standardkolumn: inga föräldralösa _temp0001 (existenskontroll)
--    D8  Flera ADD COLUMN i en ALTER TABLE: alla finns, geom sist
--    D9  61-tecken tabellnamn: 63-tecken historiknamn skapas korrekt
--    D10 62-tecken tabellnamn: 64-tecken namn trunkeras till 63 (avslutande h tappas)
--    D11 _h-tabellundantag: _h-tabeller hoppar över Hex-omstrukturering
--    D12 CREATE SCHEMA IF NOT EXISTS på befintligt schema: säker no-op
--
-- Scheman som används: sk2_ext_test, sk2_kba_test, sk2_sys_test, sk1_kba_htest
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX UTÖKAD TESTSVIT — GRUPPERNA C & D'
\echo '============================================================'

-- ============================================================
-- Städning och förberedelse
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

CREATE SCHEMA sk2_ext_test;
CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_sys_test;
CREATE SCHEMA sk1_kba_htest;

-- Förbered en geometritabell i sk2_ext_test så att C4/C5 och D-testerna har något att fråga mot
CREATE TABLE sk2_ext_test.fororeningar_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- Förbered en tabell i sk2_sys_test så att C4 kan räkna över scheman
CREATE TABLE sk2_sys_test.konfig (
    param text,
    varde text
);

-- ============================================================
-- C: KLIENT-SIMULERING (GeoServer, QGIS, FME)
-- ============================================================
\echo ''
\echo '--- GRUPP C: Simulering av klientapplikationer ---'

-- C1: application_name = GeoServer - INTE FME, full omstrukturering måste ske
SET application_name = 'GeoServer 2.24.3';

CREATE TABLE sk2_ext_test.gs_lager_p (
    layer_id integer,
    geom geometry(Point, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'gs_lager_p'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST C1 PASSED: Tabell skapad via GeoServer-namngiven anslutning omstruktureras ändå';
    ELSE
        RAISE WARNING 'TEST C1 FAILED: GeoServer application_name fick tabellen att hoppa över omstrukturering';
    END IF;
END $$;

RESET application_name;

-- C2: application_name = QGIS - inte FME, full kba-omstrukturering
SET application_name = 'QGIS 3.34.8 Prizren';

CREATE TABLE sk1_kba_htest.byggnader_y (
    fastighet text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_htest' AND table_name = 'byggnader_y'
        AND column_name = 'andrad_tidpunkt'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_htest' AND table_name = 'byggnader_y_h'
    ) THEN
        RAISE NOTICE 'TEST C2 PASSED: QGIS-anslutning får full kba-behandling (andrad_tidpunkt + historiktabell)';
    ELSE
        RAISE WARNING 'TEST C2 FAILED: QGIS kba-tabell saknar andrad_tidpunkt eller historiktabell';
    END IF;
END $$;

RESET application_name;

-- C3: application_name = FME - omstrukturering sker ändå
SET application_name = 'FME Desktop 2024.0.0.0';

CREATE TABLE sk2_ext_test.fme_import_y (
    kalla text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'fme_import_y'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST C3 PASSED: FME-anslutning får ändå tabellen omstrukturerad (gid finns)';
    ELSE
        RAISE WARNING 'TEST C3 FAILED: FME application_name fick tabellen att hoppa över omstrukturering';
    END IF;
END $$;

RESET application_name;

-- C4: GeoServer/QGIS-liknande metadatafrågor (skrivskyddade, måste alltid vara säkra)
DO $$
DECLARE antal integer;
BEGIN
    SELECT COUNT(*) INTO antal FROM geometry_columns
    WHERE f_table_schema IN ('sk2_ext_test', 'sk2_kba_test');

    SELECT COUNT(*) INTO antal FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test';

    SELECT COUNT(*) INTO antal FROM information_schema.tables
    WHERE table_schema IN ('sk2_ext_test', 'sk2_kba_test', 'sk2_sys_test');

    SELECT COUNT(*) INTO antal FROM pg_indexes
    WHERE schemaname = 'sk2_ext_test';

    RAISE NOTICE 'TEST C4 PASSED: GeoServer/QGIS-liknande metadatafrågor fungerar utan problem (% tabeller hittade)', antal;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST C4 FAILED: Fel vid metadatafråga: %', SQLERRM;
END $$;

-- C5: QGIS-liknande EXPLAIN på en Hex-hanterad tabell
DO $$
BEGIN
    EXECUTE 'EXPLAIN SELECT * FROM sk2_ext_test.fororeningar_y WHERE ST_Intersects(geom, ST_MakeEnvelope(0,0,100,100,3007))';
    RAISE NOTICE 'TEST C5 PASSED: EXPLAIN på geometrifiltrerad fråga fungerar utan problem';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST C5 FAILED: EXPLAIN misslyckades: %', SQLERRM;
END $$;

-- ============================================================
-- D: ADVERSARIELLA OCH STRUKTURELLA SPECIALFALL
-- ============================================================
\echo ''
\echo '--- GRUPP D: Adversariella och strukturella specialfall ---'

-- D1: CREATE UNLOGGED TABLE - Hex omstrukturerar den; UNLOGGED-egenskapen kan tappas tyst
CREATE UNLOGGED TABLE sk2_ext_test.temp_import_y (
    batch_id integer,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE persistens char(1);
BEGIN
    SELECT relpersistence INTO persistens
    FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'sk2_ext_test' AND c.relname = 'temp_import_y';

    CASE persistens
        WHEN 'p' THEN
            RAISE WARNING 'TEST D1 INFO: UNLOGGED TABLE blev permanent/loggad efter Hex-omstrukturering. UNLOGGED-egenskapen tappas tyst under hex_byt_ut_tabell. Förväntat om temp-tabellen skapas som permanent.';
        WHEN 'u' THEN
            RAISE NOTICE 'TEST D1 PASSED: UNLOGGED-egenskapen bevarad efter omstrukturering';
        ELSE
            RAISE WARNING 'TEST D1 UNEXPECTED: relpersistence = "%"', persistens;
    END CASE;
END $$;

-- D2: CREATE TABLE IF NOT EXISTS (tabellen finns INTE ännu) - ska fungera normalt
DO $$
BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS sk2_ext_test.ifnotexists_y (
        naam text,
        geom geometry(Polygon, 3007)
    )';
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'ifnotexists_y'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST D2 PASSED: CREATE TABLE IF NOT EXISTS (ny tabell) omstrukturerad korrekt';
    ELSE
        RAISE WARNING 'TEST D2 FAILED: Ny tabell via IF NOT EXISTS omstrukturerades inte';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D2 FAILED: %', SQLERRM;
END $$;

-- D3: CREATE TABLE IF NOT EXISTS (tabellen finns REDAN) - måste vara en säker no-op
DO $$
BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS sk2_ext_test.ifnotexists_y (
        naam text,
        geom geometry(Polygon, 3007)
    )';
    RAISE NOTICE 'TEST D3 PASSED: CREATE TABLE IF NOT EXISTS på befintlig tabell är en säker no-op';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D3 FAILED: IF NOT EXISTS på befintlig tabell orsakade fel: %', SQLERRM;
END $$;

-- D4: CREATE TABLE LIKE - kopierar kolumnstruktur, måste omstruktureras av Hex
CREATE TABLE sk2_ext_test.fororeningar_kopia_y
    (LIKE sk2_ext_test.fororeningar_y);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_kopia_y'
        AND column_name = 'gid'
    )
    AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk2_ext_test' AND tablename = 'fororeningar_kopia_y'
        AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST D4 PASSED: CREATE TABLE LIKE omstruktureras korrekt (gid + GiST-index)';
    ELSE
        RAISE WARNING 'TEST D4 FAILED: CREATE TABLE LIKE omstrukturerades inte (gid eller GiST-index saknas)';
    END IF;
END $$;

-- D5: ALTER TABLE RENAME TO - hex_hantera_ny_kolumn avfyras på det NYA namnet.
--     Historiktabellen behåller det GAMLA namnet -> blir föräldralös.
CREATE TABLE sk2_kba_test.rename_src_y (
    info text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h'
    ) THEN
        RAISE NOTICE 'TEST D5a PASSED: Historiktabellen rename_src_y_h finns innan namnbyte';
    ELSE
        RAISE WARNING 'TEST D5a FAILED: Ingen historiktabell inför namnbytestestet';
    END IF;
END $$;

ALTER TABLE sk2_kba_test.rename_src_y RENAME TO rename_dst_y;

DO $$
DECLARE
    dst_finns   boolean;
    src_borta   boolean;
    gammal_hist boolean;
    ny_hist     boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y')  INTO dst_finns;
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y') INTO src_borta;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h') INTO gammal_hist;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y_h') INTO ny_hist;

    IF dst_finns AND src_borta AND gammal_hist AND NOT ny_hist THEN
        RAISE WARNING 'TEST D5b BUG CONFIRMED: Efter RENAME TO är historiktabellen rename_src_y_h FÖRÄLDRALÖS. Föräldern rename_src_y finns inte längre. DROP TABLE rename_dst_y kommer INTE att städa bort rename_src_y_h.';
    ELSIF dst_finns AND src_borta AND NOT gammal_hist AND NOT ny_hist THEN
        RAISE NOTICE 'TEST D5b INFO: Namnbytet lyckades, ingen föräldralös historiktabell (ingen kba-historik skapades)';
    ELSIF dst_finns AND src_borta AND ny_hist THEN
        RAISE NOTICE 'TEST D5b PASSED: Efter namnbyte döptes historiktabellen också om (oväntad bonus)';
    ELSE
        RAISE WARNING 'TEST D5b UNEXPECTED STATE: dst=% src_borta=% gammal_hist=% ny_hist=%',
            dst_finns, src_borta, gammal_hist, ny_hist;
    END IF;
END $$;

-- Efter fixen: DROP TABLE på den omdöpta tabellen ska städa bort rename_dst_y_h via OID-slagning
DROP TABLE IF EXISTS sk2_kba_test.rename_dst_y;

DO $$
DECLARE
    gammal_h_borta boolean;
    ny_h_borta     boolean;
BEGIN
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h') INTO gammal_h_borta;
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y_h') INTO ny_h_borta;

    IF gammal_h_borta AND ny_h_borta THEN
        RAISE NOTICE 'TEST D5c PASSED: Båda historiktabellnamnen städades bort efter DROP TABLE rename_dst_y (hex_metadata OID-slagning fungerade)';
    ELSIF NOT gammal_h_borta THEN
        RAISE WARNING 'TEST D5c BUG: rename_src_y_h finns fortfarande kvar (döptes aldrig om - RENAME-hanteringen avfyrades inte)';
    ELSIF NOT ny_h_borta THEN
        RAISE WARNING 'TEST D5c BUG: rename_dst_y_h städades INTE bort vid DROP TABLE (OID-slagningen i hex_hantera_borttagen_tabell misslyckades)';
    END IF;
END $$;

-- D6: ALTER TABLE ADD COLUMN och sedan DROP COLUMN (användarkolumn) - inga föräldralösa temp-kolumner
CREATE TABLE sk2_kba_test.dropcol_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_kba_test.dropcol_test_y ADD COLUMN temp_col text;
ALTER TABLE sk2_kba_test.dropcol_test_y DROP COLUMN temp_col;

DO $$
DECLARE antal_foraldralosa integer;
BEGIN
    SELECT COUNT(*) INTO antal_foraldralosa
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'dropcol_test_y'
    AND column_name LIKE '%_temp0001';

    IF antal_foraldralosa = 0 THEN
        RAISE NOTICE 'TEST D6 PASSED: DROP COLUMN på användarkolumn lämnar inga föräldralösa _temp0001-kolumner';
    ELSE
        RAISE WARNING 'TEST D6 FAILED: % föräldralösa _temp0001-kolumn(er) efter DROP av användarkolumn', antal_foraldralosa;
    END IF;
END $$;

-- D7: DROP av en STANDARDKOLUMN - kolumnflyttaren lägger till temp och misslyckas sedan -> föräldralös _temp0001
--     Detta är buggen där hex_hantera_ny_kolumn saknar en existenskontroll.
ALTER TABLE sk2_kba_test.dropcol_test_y DROP COLUMN IF EXISTS andrad_tidpunkt;

DO $$
DECLARE antal_foraldralosa integer;
BEGIN
    SELECT COUNT(*) INTO antal_foraldralosa
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'dropcol_test_y'
    AND column_name LIKE '%_temp0001';

    IF antal_foraldralosa > 0 THEN
        RAISE WARNING 'TEST D7 BUG CONFIRMED: Att ta bort en standardkolumn (andrad_tidpunkt) lämnar % föräldralösa _temp0001-kolumn(er) i tabellen. Kolumnflyttaren saknar existenskontroll: den lägger till temp-kolumnen (steg 1 lyckas) innan den upptäcker att originalet är borta (steg 2 misslyckas). EXCEPTION-blocket fångar felet men rullar inte tillbaka den redan skapade temp-kolumnen.', antal_foraldralosa;
    ELSE
        RAISE NOTICE 'TEST D7 PASSED: Inga föräldralösa _temp0001-kolumner efter borttagning av standardkolumn (existenskontrollen fungerar)';
    END IF;
END $$;

-- D8: Flera ADD COLUMN i en ALTER TABLE-sats (en DDL-händelse, ett triggeranrop)
CREATE TABLE sk2_ext_test.multi_add_y (
    naam text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_ext_test.multi_add_y
    ADD COLUMN kolumn_a text,
    ADD COLUMN kolumn_b integer,
    ADD COLUMN kolumn_c boolean;

DO $$
DECLARE
    antal_kol  integer;
    geom_pos   integer;
    sista_pos  integer;
BEGIN
    SELECT COUNT(*) INTO antal_kol FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y'
    AND column_name IN ('kolumn_a', 'kolumn_b', 'kolumn_c');

    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO sista_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y';

    IF antal_kol = 3 AND geom_pos = sista_pos THEN
        RAISE NOTICE 'TEST D8 PASSED: Multi-ADD COLUMN: alla 3 nya kolumner finns, geom fortfarande sist (pos %/%)', geom_pos, sista_pos;
    ELSE
        RAISE WARNING 'TEST D8 FAILED: antal_kol=% (förväntade 3), geom_pos=% sista_pos=%',
            antal_kol, geom_pos, sista_pos;
    END IF;
END $$;

-- D9: 61-tecken tabellnamn -> Hex hex_validera_tabell tillåter max 54 tecken, så detta
--     avvisas innan PostgreSQLs 63-teckensgräns för identifierare ens nås.
DO $$
DECLARE
    tnamn text := repeat('a', 59) || '_y';   -- 61 tecken
BEGIN
    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tnamn
    );
    -- Om vi kommer hit tillät Hex det - kontrollera historiktabellen
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = tnamn || '_h'
    ) THEN
        RAISE NOTICE 'TEST D9 PASSED: 61-tecken tabellnamn tillåts och historiktabell skapas';
    ELSE
        RAISE WARNING 'TEST D9 FAILED: 61-tecken tabell tilläts men ingen historiktabell skapades';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%för långt%' OR SQLERRM LIKE '%too long%' THEN
            RAISE NOTICE 'TEST D9 INFO: 61-tecken tabellnamn avvisat av Hex längdkontroll (max 54 tecken). PostgreSQLs 63-teckensgräns för identifierare nås aldrig.';
        ELSE
            RAISE WARNING 'TEST D9 FAILED: Oväntat fel: %', SQLERRM;
        END IF;
END $$;

-- D10: 62-tecken tabellnamn -> samma Hex-gräns gäller (max 54 tecken).
DO $$
DECLARE
    tnamn text := repeat('b', 60) || '_y';  -- 62 tecken
BEGIN
    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tnamn
    );
    -- Om det tillåts, kontrollera om PostgreSQL trunkerade det 64-tecken historiknamnet till 63
    DECLARE
        avsett_hnamn    text := tnamn || '_h';        -- 64 tecken
        trunkerat_hnamn text := left(tnamn || '_h', 63); -- 63 tecken
    BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'sk2_kba_test' AND table_name = trunkerat_hnamn)
           AND trunkerat_hnamn != avsett_hnamn THEN
            RAISE WARNING 'TEST D10 BUG CONFIRMED: 62-tecken namn orsakar trunkering av historiktabellnamnet. Avsett "%" -> faktiskt "%" (avslutande h tappas -> föräldralös vid DROP TABLE).', avsett_hnamn, trunkerat_hnamn;
        ELSE
            RAISE NOTICE 'TEST D10 PASSED: 62-tecken historiktabellnamn trunkerades inte';
        END IF;
    END;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%för långt%' OR SQLERRM LIKE '%too long%' THEN
            RAISE NOTICE 'TEST D10 INFO: 62-tecken tabellnamn avvisat av Hex längdkontroll (max 54 tecken). PostgreSQLs trunkering av identifierare nås aldrig.';
        ELSE
            RAISE WARNING 'TEST D10 FAILED: Oväntat fel: %', SQLERRM;
        END IF;
END $$;

-- D11: _h-undantag - listigt namngiven tabell för att hoppa över omstrukturering
--      En tabell som slutar på _h där föräldern (namnet utan _h) INTE finns blockeras.
--      En tabell som slutar på _h där föräldern FINNS passerar oförändrad.
--      Det innebär att _h-tabeller alltid går förbi Hex helt - avsiktligt men värt att bekräfta.
CREATE TABLE sk2_ext_test.sneaky_bypass_y (
    naam text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    -- En tabell som heter parent_y_h (inte sneaky_h) blockeras inte eftersom parent_y finns
    EXECUTE 'CREATE TABLE sk2_ext_test.sneaky_bypass_y_h (
        h_typ char(1), h_tidpunkt timestamptz, gid integer, naam text, geom geometry
    )';
    -- _h-tabeller går förbi omstrukturering - denna tabell har inga Hex-standardkolumner tillagda
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'sneaky_bypass_y_h'
        AND column_name = 'skapad_tidpunkt'
    ) THEN
        RAISE NOTICE 'TEST D11 PASSED: _h-tabeller går förbi Hex-omstrukturering (inga standardkolumner tillagda). Detta är avsiktligt - historiktabeller behåller sitt eget schema.';
    ELSE
        RAISE WARNING 'TEST D11 UNEXPECTED: _h-tabellen fick standardkolumner tillagda (omstrukturering gicks inte förbi)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST D11: Skapande av _h-tabell gav undantag: %', left(SQLERRM, 80);
END $$;

-- D12: CREATE SCHEMA IF NOT EXISTS på redan existerande schema - måste vara säker no-op
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS sk2_ext_test';
    RAISE NOTICE 'TEST D12 PASSED: CREATE SCHEMA IF NOT EXISTS på befintligt schema är säker no-op';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D12 FAILED: CREATE SCHEMA IF NOT EXISTS orsakade fel: %', SQLERRM;
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

\echo ''
\echo 'HEX UTÖKAD C & D KLAR'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
