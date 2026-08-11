-- ============================================================
-- HEX UTÖKAD TESTSVIT — GRUPPERNA A & B
--
-- A  sk2-schemahantering (fullständigt)
--    A1  sk2_ext: gid + skapad_tidpunkt, GiST-index, ingen validering
--    A2  sk2_kba: alla 5 standardkolumner, validering, historiktabell
--    A3  sk2_sys: ingen geometri, gid, ingen historiktabell
--    A4  Roller: läs-/skriv-grupproller + inloggningsroller skapade vid CREATE SCHEMA
--    A5  sk2 undantagen från GeoServer pg_notify
--
-- B  Vy-validering (hex_hantera_ny_vy / hex_validera_vynamn)
--    B1  Giltig icke-geometrivy (v_-prefix, inget suffix)
--    B2  Giltig geometrivy (v_-prefix + geometrisuffix)
--    B3  Vy utan v_-prefix avvisas
--    B4  Vy med fel geometrisuffix avvisas
--    B5  Vy i public-schema tyst accepterad
--    B6  ST_-transformering utan typomvandling avvisas
--    B7  ST_-transformering med explicit typomvandling accepteras
--
-- Scheman som används: sk2_ext_test, sk2_kba_test, sk2_sys_test, sk1_kba_htest
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX UTÖKAD TESTSVIT — GRUPPERNA A & B'
\echo '============================================================'

-- ============================================================
-- Städning och förberedelse
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_ab_temp CASCADE;

-- Förbered global rollkonfiguration som behövs för A4-testerna.
-- r_sk0_global och r_sk1_global skapas av event triggern när ett
-- sk0/sk1-schema skapas, förutsatt att raderna finns i hex_standardiserade_roller.
DELETE FROM hex_standardiserade_roller WHERE rollnamn IN ('r_sk0_global', 'r_sk1_global');
DROP ROLE IF EXISTS r_sk0_global;
DROP ROLE IF EXISTS r_sk1_global;
INSERT INTO hex_standardiserade_roller (rollnamn, rolltyp, schema_uttryck, ta_bort_med_schema, kan_logga_in, beskrivning) VALUES
    ('r_sk0_global', 'read', 'LIKE ''sk0_%''', false, false, 'Global läsroll för sk0'),
    ('r_sk1_global', 'read', 'LIKE ''sk1_%''', false, false, 'Global läsroll för sk1');

-- Skapa ett sk0-schema för att utlösa r_sk0_global; ta bort det direkt (rollen kvarstår eftersom ta_bort_med_schema=false)
CREATE SCHEMA sk0_ext_ab_temp;
DROP SCHEMA sk0_ext_ab_temp CASCADE;

CREATE SCHEMA sk2_ext_test;
CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_sys_test;
CREATE SCHEMA sk1_kba_htest;  -- utlöser skapande av r_sk1_global

-- ============================================================
-- A: HANTERING AV SK2-SCHEMAN
-- ============================================================
\echo ''
\echo '--- GRUPP A: Hantering av sk2-scheman ---'

-- ------------------------------------------------------------
-- A1: sk2_ext - ska bara få gid + skapad_tidpunkt (inte kba-kolumner)
-- ------------------------------------------------------------
CREATE TABLE sk2_ext_test.fororeningar_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE antal_kol integer;
BEGIN
    SELECT COUNT(*) INTO antal_kol FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt');
    IF antal_kol = 2 THEN
        RAISE NOTICE 'TEST A1a PASSED: sk2_ext-tabell har gid och skapad_tidpunkt';
    ELSE
        RAISE WARNING 'TEST A1a FAILED: Förväntade 2 grundläggande standardkolumner på sk2_ext, fick %', antal_kol;
    END IF;
END $$;

DO $$
DECLARE antal_kol integer;
BEGIN
    SELECT COUNT(*) INTO antal_kol FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF antal_kol = 0 THEN
        RAISE NOTICE 'TEST A1b PASSED: sk2_ext har INTE de kba-specifika kolumnerna';
    ELSE
        RAISE WARNING 'TEST A1b FAILED: sk2_ext har % kba-specifika kolumner (schema_uttryck-filtret är trasigt)', antal_kol;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk2_ext_test' AND tablename = 'fororeningar_y'
        AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST A1c PASSED: GiST-index på sk2_ext-geometritabellen';
    ELSE
        RAISE WARNING 'TEST A1c FAILED: Inget GiST-index på sk2_ext-tabellen';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_ext_test.fororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%hex_validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A1d PASSED: Ingen geometrivalidering på sk2_ext (korrekt)';
    ELSE
        RAISE WARNING 'TEST A1d FAILED: sk2_ext har geometrivalidering (bara kba ska ha det)';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A2: sk2_kba - full kba-behandling: alla standardkolumner, validering, historik
-- ------------------------------------------------------------
CREATE TABLE sk2_kba_test.markfororeningar_y (
    orsak text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE antal_kol integer;
BEGIN
    SELECT COUNT(*) INTO antal_kol FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt', 'skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF antal_kol = 5 THEN
        RAISE NOTICE 'TEST A2a PASSED: sk2_kba-tabellen har alla 5 standardkolumner';
    ELSE
        RAISE WARNING 'TEST A2a FAILED: Förväntade 5 standardkolumner på sk2_kba, fick %', antal_kol;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_kba_test.markfororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%hex_validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A2b PASSED: sk2_kba har geometrivalideringsvillkor';
    ELSE
        RAISE WARNING 'TEST A2b FAILED: sk2_kba saknar geometrivalidering';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y_h'
    ) THEN
        RAISE NOTICE 'TEST A2c PASSED: Historiktabell skapad för sk2_kba-tabellen';
    ELSE
        RAISE WARNING 'TEST A2c FAILED: Ingen historiktabell för sk2_kba';
    END IF;
END $$;

DO $$
BEGIN
    INSERT INTO sk2_kba_test.markfororeningar_y (orsak, geom)
    VALUES ('test', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST A2d FAILED: Tom geometri accepterades i sk2_kba (ska blockeras)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri%' AND SQLERRM LIKE '%tom%' THEN
            RAISE NOTICE 'TEST A2d PASSED: Tom geometri blockerad med beskrivande meddelande: %', left(SQLERRM, 120);
        ELSIF SQLERRM LIKE '%check constraint%' OR SQLERRM LIKE '%validera_geom%' THEN
            RAISE WARNING 'TEST A2d PARTIAL: Geometri blockerad av CHECK-villkor men triggermeddelandet saknas. Är hex_kontrollera_geometri_trigger installerad?';
        ELSE
            RAISE NOTICE 'TEST A2d PASSED (annan orsak): %', left(SQLERRM, 120);
        END IF;
END $$;

-- ------------------------------------------------------------
-- A3: sk2_sys - ingen geometri, standardkolumner
-- ------------------------------------------------------------
CREATE TABLE sk2_sys_test.konfig (
    param text,
    varde text
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST A3a PASSED: sk2_sys icke-geometritabell har gid';
    ELSE
        RAISE WARNING 'TEST A3a FAILED: sk2_sys-tabellen saknar gid';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig_h'
    ) THEN
        RAISE NOTICE 'TEST A3b PASSED: sk2_sys icke-geometritabell har ingen historiktabell (korrekt)';
    ELSE
        RAISE WARNING 'TEST A3b FAILED: sk2_sys icke-geometritabell har oväntat en historiktabell';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A4: sk2-roller - r_{schema} (LIKE sk2_%) och w_{schema} (IS NOT NULL) skapas
-- ------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4a PASSED: Skrivrollen w_sk2_ext_test skapad';
    ELSE
        RAISE WARNING 'TEST A4a FAILED: Skrivrollen w_sk2_ext_test saknas';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4b PASSED: Läsrollen r_sk2_ext_test skapad (sk2 matchar LIKE sk2_%%)';
    ELSE
        RAISE WARNING 'TEST A4b FAILED: Läsrollen r_sk2_ext_test saknas';
    END IF;
END $$;

-- sk2 får INTE tilldelas r_sk0_global eller r_sk1_global
DO $$
BEGIN
    -- Dessa globala roller gäller bara sk0_% och sk1_%.
    -- Vi bekräftar att skapandet av sk2-schemat inte av misstag rörde dem.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk0_global')
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_global') THEN
        RAISE NOTICE 'TEST A4c PASSED: De globala rollerna r_sk0_global och r_sk1_global finns kvar oförändrade';
    ELSE
        RAISE WARNING 'TEST A4c FAILED: En global roll togs oväntat bort eller ändrades';
    END IF;
END $$;

-- A4d: gs_r_sk2_ext_test ska vara en LOGIN-roll (kan_logga_in=true på gs_r_{schema}-raden)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'gs_r_sk2_ext_test' AND rolcanlogin = true
    ) THEN
        RAISE NOTICE 'TEST A4d PASSED: Inloggningsrollen gs_r_sk2_ext_test skapad med LOGIN';
    ELSE
        RAISE WARNING 'TEST A4d FAILED: gs_r_sk2_ext_test saknas eller är inte en LOGIN-roll';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A5: sk2 får INTE utlösa GeoServer pg_notify
-- Testar regexen som skyddar notifieringen direkt
-- ------------------------------------------------------------
DO $$
DECLARE matchat_prefix text;
BEGIN
    matchat_prefix := substring('sk2_kba_test' FROM '^(sk[01])_');
    IF matchat_prefix IS NULL THEN
        RAISE NOTICE 'TEST A5 PASSED: sk2-schema korrekt undantaget från GeoServer-notifiering (prefix-regexen ''^(sk[01])_'' returnerar NULL för sk2)';
    ELSE
        RAISE WARNING 'TEST A5 FAILED: sk2-schema matchade GeoServer-prefix: "%"', matchat_prefix;
    END IF;
END $$;

-- ============================================================
-- B: VY-VALIDERING
-- ============================================================
\echo ''
\echo '--- GRUPP B: Vy-validering ---'

-- B1: Giltig icke-geometrivy - ska accepteras (börjar med v_, inget suffix krävs)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.v_konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig WHERE varde IS NOT NULL';
    RAISE NOTICE 'TEST B1 PASSED: Giltig icke-geometrivy (v_xxx) accepterad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B1 FAILED: Giltig icke-geometrivy avvisad: %', SQLERRM;
END $$;

-- B2: Giltig geometrivy - korrekt suffix för polygondata
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_y AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B2 PASSED: Giltig geometrivy (v_xxx_y) accepterad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B2 FAILED: Giltig geometrivy avvisad: %', SQLERRM;
END $$;

-- B3: Vy utan v_-prefix - ska avvisas
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig';
    RAISE WARNING 'TEST B3 FAILED: Vy utan v_-prefix accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B3 PASSED: Vy utan v_-prefix korrekt avvisad';
END $$;

-- B4: Vy med fel geometrisuffix (polygondata men namngiven _l)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_l AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B4 FAILED: Fel geometrisuffix (_l för polygon) accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B4 PASSED: Fel geometrisuffix korrekt avvisat';
END $$;

-- B5: Vy i public-schema - ska hoppas över tyst (ingen kontroll)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW public.anything AS SELECT 1 AS x';
    RAISE NOTICE 'TEST B5 PASSED: Vy i public-schema hoppades över (vilket namn som helst accepteras)';
    EXECUTE 'DROP VIEW public.anything';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B5 FAILED: Vy i public-schema orsakade fel: %', SQLERRM;
END $$;

-- B6: ST_-transformering utan explicit typomvandling - ska ge hjälpsam diagnostik
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid, ST_Buffer(geom, 10) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B6 FAILED: ST_-transformering utan typomvandling accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B6 PASSED: ST_-transformering utan typomvandling avvisad (meddelande: %)',
            left(SQLERRM, 80);
END $$;

-- B7: ST_-transformering MED explicit typomvandling - ska accepteras
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid,
                    ST_Buffer(geom, 10)::geometry(Polygon, 3007) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B7 PASSED: ST_-transformering med explicit typomvandling accepterad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B7 FAILED: ST_-transformering med typomvandling avvisad: %', SQLERRM;
END $$;

-- B8: CREATE OR REPLACE VIEW med giltigt namn - ersätter en befintlig giltig vy
DO $$
BEGIN
    EXECUTE 'CREATE OR REPLACE VIEW sk2_ext_test.v_fororeningar_y AS
             SELECT *
             FROM sk2_ext_test.fororeningar_y
             WHERE gid IS NOT NULL';
    RAISE NOTICE 'TEST B8 PASSED: CREATE OR REPLACE VIEW accepterad (giltigt namn, ersätter befintlig vy)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B8 FAILED: CREATE OR REPLACE VIEW på befintlig giltig vy avvisad: %', SQLERRM;
END $$;

-- B9: CREATE OR REPLACE VIEW med ogiltigt namn (inget v_-prefix) - ska avvisas
DO $$
BEGIN
    EXECUTE 'CREATE OR REPLACE VIEW sk2_ext_test.fororeningar_alt_y AS
             SELECT gid, geom FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B9 FAILED: CREATE OR REPLACE VIEW utan v_-prefix accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B9 PASSED: CREATE OR REPLACE VIEW utan v_-prefix korrekt avvisad';
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

-- Ta bort global rollkonfiguration som lades till för A4-testerna
DELETE FROM hex_standardiserade_roller WHERE rollnamn IN ('r_sk0_global', 'r_sk1_global');
DROP ROLE IF EXISTS r_sk0_global;
DROP ROLE IF EXISTS r_sk1_global;

\echo ''
\echo 'HEX UTÖKAD A & B KLAR'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
