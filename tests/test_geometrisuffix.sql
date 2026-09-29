-- ============================================================
-- HEX GEOMETRISUFFIX TEST SUITE
--
-- Testar att geometrisuffixen styrs av hex_installningar
-- (suffix_punkt, suffix_linje, suffix_yta, suffix_ovrigt):
--   1  hex_geometrisuffix() och hex_tabellsuffix() med standardvärden
--   2  CHECK-villkoren på suffixkolumnerna
--   3  Exakt jämförelse av suffix och vyprefixet v_ (_ är inte ett jokertecken)
--   4  Egna suffix: tabeller, vyer och tvåstegsmönstret följer inställningen
--
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX GEOMETRISUFFIX TEST SUITE'
\echo '============================================================'

DROP SCHEMA IF EXISTS sk0_ext_suffixtest CASCADE;
CREATE SCHEMA sk0_ext_suffixtest;

-- Säkerställ standardvärden även om en tidigare körning avbröts
UPDATE public.hex_installningar
SET    suffix_punkt = '_p', suffix_linje = '_l', suffix_yta = '_y', suffix_ovrigt = '_g';

-- ============================================================
-- 1: Hjälpfunktioner med standardvärden
-- ============================================================
\echo ''
\echo '--- GRUPP 1: hex_geometrisuffix() och hex_tabellsuffix() ---'

DO $$
BEGIN
    IF public.hex_geometrisuffix('POINT') = '_p'
       AND public.hex_geometrisuffix('MultiPointZ') = '_p'
       AND public.hex_geometrisuffix('LINESTRINGM') = '_l'
       AND public.hex_geometrisuffix('MULTIPOLYGONZM') = '_y'
       AND public.hex_geometrisuffix('GEOMETRYCOLLECTION') = '_g'
       AND public.hex_geometrisuffix(NULL) = '_g' THEN
        RAISE NOTICE 'TEST 1a PASSED: hex_geometrisuffix() ger standardsuffixen, oberoende av Z/M och skiftläge';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: POINT=% MultiPointZ=% LINESTRINGM=% MULTIPOLYGONZM=% GC=% NULL=%',
            public.hex_geometrisuffix('POINT'), public.hex_geometrisuffix('MultiPointZ'),
            public.hex_geometrisuffix('LINESTRINGM'), public.hex_geometrisuffix('MULTIPOLYGONZM'),
            public.hex_geometrisuffix('GEOMETRYCOLLECTION'), public.hex_geometrisuffix(NULL);
    END IF;

    IF public.hex_tabellsuffix('hus_p') = '_p'
       AND public.hex_tabellsuffix('vag_l') = '_l'
       AND public.hex_tabellsuffix('kartap') IS NULL
       AND public.hex_tabellsuffix('register') IS NULL
       AND public.hex_tabellsuffix('_p') IS NULL THEN
        RAISE NOTICE 'TEST 1b PASSED: hex_tabellsuffix() känner igen suffix exakt';
    ELSE
        RAISE WARNING 'TEST 1b FAILED: hus_p=% vag_l=% kartap=% register=% _p=%',
            public.hex_tabellsuffix('hus_p'), public.hex_tabellsuffix('vag_l'),
            public.hex_tabellsuffix('kartap'), public.hex_tabellsuffix('register'),
            public.hex_tabellsuffix('_p');
    END IF;
END $$;

-- ============================================================
-- 2: CHECK-villkor
-- ============================================================
\echo ''
\echo '--- GRUPP 2: CHECK-villkor på suffixkolumnerna ---'

DO $$
BEGIN
    BEGIN
        UPDATE public.hex_installningar SET suffix_punkt = 'pkt';
        RAISE WARNING 'TEST 2a FAILED: suffix utan inledande understreck accepterades';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'TEST 2a PASSED: suffix utan inledande understreck avvisas';
    END;
    BEGIN
        UPDATE public.hex_installningar SET suffix_punkt = '_p_x';
        RAISE WARNING 'TEST 2b FAILED: suffix med ett andra understreck accepterades';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'TEST 2b PASSED: suffix med ett andra understreck avvisas';
    END;
    BEGIN
        UPDATE public.hex_installningar SET suffix_linje = '_p';
        RAISE WARNING 'TEST 2c FAILED: två lika suffix accepterades';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'TEST 2c PASSED: två lika suffix avvisas';
    END;
    BEGIN
        UPDATE public.hex_installningar SET suffix_ovrigt = '_h';
        RAISE WARNING 'TEST 2d FAILED: _h (historiktabeller) accepterades som geometrisuffix';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'TEST 2d PASSED: _h avvisas som geometrisuffix';
    END;
END $$;

-- ============================================================
-- 3: Exakt jämförelse – tidigare godtog LIKE '%_p' även "kartap"
-- ============================================================
\echo ''
\echo '--- GRUPP 3: _ är inte ett jokertecken ---'

DO $$
BEGIN
    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.kartap (namn text, geom geometry(Point, 3007))';
        RAISE WARNING 'TEST 3a FAILED: punkttabellen "kartap" (utan _p) accepterades';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 3a PASSED: punkttabellen "kartap" avvisas (%)', left(SQLERRM, 60);
    END;
    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.kartor_p (namn text, geom geometry(Point, 3007))';
        RAISE NOTICE 'TEST 3b PASSED: punkttabellen "kartor_p" accepteras';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST 3b FAILED: kartor_p avvisades: %', SQLERRM;
    END;
    -- Prefixet v_: LIKE 'v_%' godtog tidigare "vagar_p" (_ matchade "a")
    BEGIN
        EXECUTE 'CREATE VIEW sk0_ext_suffixtest.vagar_p AS SELECT gid, geom FROM sk0_ext_suffixtest.kartor_p';
        RAISE WARNING 'TEST 3c FAILED: vyn "vagar_p" (utan v_) accepterades';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 3c PASSED: vyn "vagar_p" avvisas';
    END;
    BEGIN
        EXECUTE 'CREATE VIEW sk0_ext_suffixtest.v_kartor_p AS SELECT gid, geom FROM sk0_ext_suffixtest.kartor_p';
        RAISE NOTICE 'TEST 3d PASSED: vyn "v_kartor_p" accepteras';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST 3d FAILED: v_kartor_p avvisades: %', SQLERRM;
    END;
END $$;

-- ============================================================
-- 4: Egna suffix
-- ============================================================
\echo ''
\echo '--- GRUPP 4: egna suffix från hex_installningar ---'

UPDATE public.hex_installningar
SET    suffix_punkt = '_pkt', suffix_linje = '_lin', suffix_yta = '_yta', suffix_ovrigt = '_geo';

DO $$
BEGIN
    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.hus_pkt (namn text, geom geometry(Point, 3007))';
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.omrade_yta (namn text, geom geometry(MultiPolygon, 3007))';
        RAISE NOTICE 'TEST 4a PASSED: tabeller med egna suffix (_pkt, _yta) accepteras';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST 4a FAILED: tabeller med egna suffix avvisades: %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.hus2_p (namn text, geom geometry(Point, 3007))';
        RAISE WARNING 'TEST 4b FAILED: standardsuffixet _p accepterades trots att suffix_punkt = _pkt';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 4b PASSED: _p avvisas när suffix_punkt = _pkt';
    END;

    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.lista_lin (namn text)';
        RAISE WARNING 'TEST 4c FAILED: tabell utan geometri med suffixet _lin accepterades';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 4c PASSED: tabell utan geometri får inte använda _lin';
    END;

    BEGIN
        EXECUTE 'CREATE TABLE sk0_ext_suffixtest.lista_p (namn text)';
        RAISE NOTICE 'TEST 4d PASSED: _p är ett vanligt namnslut när suffix_punkt = _pkt';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST 4d FAILED: lista_p avvisades: %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'CREATE VIEW sk0_ext_suffixtest.v_hus_pkt AS SELECT gid, geom FROM sk0_ext_suffixtest.hus_pkt';
        RAISE NOTICE 'TEST 4e PASSED: vy med eget suffix _pkt accepteras';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST 4e FAILED: v_hus_pkt avvisades: %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'CREATE VIEW sk0_ext_suffixtest.v_hus_p AS SELECT gid, geom FROM sk0_ext_suffixtest.hus_pkt';
        RAISE WARNING 'TEST 4f FAILED: vy med standardsuffixet _p accepterades trots suffix_punkt = _pkt';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 4f PASSED: vy med _p avvisas när suffix_punkt = _pkt';
    END;

    -- Tvåstegsmönstret (5c): geom läggs till på en tabell som inte har
    -- gått genom Hex-hanteringen med geometri. Fel suffix ska avvisas och
    -- namnförslaget ska byta ut det gamla suffixet mot det nya.
    BEGIN
        EXECUTE 'ALTER TABLE sk0_ext_suffixtest.lista_p ADD COLUMN geom geometry(Point, 3007)';
        RAISE WARNING 'TEST 4g FAILED: geom på lista_p accepterades (förväntar _pkt)';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%"lista_p_pkt"%' THEN
            RAISE NOTICE 'TEST 4g PASSED: geom på lista_p avvisas med förslaget lista_p_pkt';
        ELSE
            RAISE WARNING 'TEST 4g FAILED: oväntat felmeddelande: %', SQLERRM;
        END IF;
    END;
END $$;

-- Återställ standardvärdena. Körs oavsett utfall ovan.
UPDATE public.hex_installningar
SET    suffix_punkt = '_p', suffix_linje = '_l', suffix_yta = '_y', suffix_ovrigt = '_g';

-- 4h: Befintliga tabeller påverkas inte av bytet tillbaka
DO $$
BEGIN
    IF to_regclass('sk0_ext_suffixtest.hus_pkt') IS NOT NULL THEN
        RAISE NOTICE 'TEST 4h PASSED: hus_pkt finns kvar efter att suffixen återställts';
    ELSE
        RAISE WARNING 'TEST 4h FAILED: hus_pkt saknas';
    END IF;
END $$;

DROP SCHEMA IF EXISTS sk0_ext_suffixtest CASCADE;

\echo ''
\echo 'HEX GEOMETRISUFFIX TEST SUITE SLUTFÖRD'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED'
