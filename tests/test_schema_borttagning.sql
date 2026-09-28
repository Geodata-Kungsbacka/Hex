-- ============================================================
-- TEST: DROP SCHEMA ... CASCADE rensar Hex-metadata
--
-- Verifierar att hex_hantera_borttagen_tabell() (via
-- hex_hantera_borttagen_tabell_trigger) även körs vid DROP SCHEMA och
-- tar bort rader för schemats tabeller i:
--   hex_metadata, hex_avvikande_srid, hex_dummy_geometrier,
--   hex_afvaktande_geometri
--
-- Kvarlämnade hex_metadata-rader är farliga eftersom parent_oid kan
-- återanvändas av en ny tabell.
--
-- Scheman som används: sk0_kba_stale, sk0_kba_stale2
-- Konvention: NOTICE = PASSED, WARNING = FAILED
--
-- ANVÄNDNING:
--   psql -d hex_test -f tests/test_schema_borttagning.sql
--   eller: python3 tests/test_run_all.py --only sql
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: DROP SCHEMA CASCADE rensar Hex-metadata'
\echo '============================================================'

-- ============================================================
-- Städning från tidigare körningar
-- ============================================================
DROP SCHEMA IF EXISTS sk0_kba_stale CASCADE;
DROP SCHEMA IF EXISTS sk0_kba_stale2 CASCADE;
DELETE FROM public.hex_metadata WHERE parent_schema IN ('sk0_kba_stale', 'sk0_kba_stale2');
DELETE FROM public.hex_afvaktande_geometri WHERE schema_namn IN ('sk0_kba_stale', 'sk0_kba_stale2');
DELETE FROM public.hex_avvikande_srid WHERE schema_namn IN ('sk0_kba_stale', 'sk0_kba_stale2');
DELETE FROM public.hex_dummy_geometrier WHERE schema_namn IN ('sk0_kba_stale', 'sk0_kba_stale2');

-- ============================================================
-- Förberedelse
-- ============================================================
CREATE SCHEMA sk0_kba_stale;
CREATE SCHEMA sk0_kba_stale2;

-- Tabell med historik → rad i hex_metadata
CREATE TABLE sk0_kba_stale.t_y (namn text, geom geometry(Polygon, 3007));
-- Tabell med avvikande SRID → rad i hex_avvikande_srid
CREATE TABLE sk0_kba_stale.srid_y (namn text, geom geometry(Polygon, 3006));

-- Manuellt inlagda rader (simulerar FME-tvåstegsmönster och dummy-rad;
-- dummy-raden registreras normalt redan av Hex vid CREATE TABLE)
INSERT INTO public.hex_afvaktande_geometri (schema_namn, tabell_namn)
    VALUES ('sk0_kba_stale', 'vantar_y');
INSERT INTO public.hex_dummy_geometrier (schema_namn, tabell_namn, gid)
    VALUES ('sk0_kba_stale', 't_y', 1)
    ON CONFLICT DO NOTHING;

-- Kontrollschema som INTE ska påverkas
CREATE TABLE sk0_kba_stale2.kvar_y (namn text, geom geometry(Polygon, 3007));

-- ============================================================
-- Förutsättningar
-- ============================================================
DO $$
BEGIN
    IF (SELECT count(*) FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale') >= 1 THEN
        RAISE NOTICE 'TEST 1a PASSED: hex_metadata har rader för sk0_kba_stale före DROP';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: hex_metadata saknar rader för sk0_kba_stale före DROP';
    END IF;

    IF EXISTS (SELECT 1 FROM public.hex_avvikande_srid
               WHERE schema_namn = 'sk0_kba_stale' AND tabell_namn = 'srid_y') THEN
        RAISE NOTICE 'TEST 1b PASSED: hex_avvikande_srid har rad för sk0_kba_stale.srid_y före DROP';
    ELSE
        RAISE WARNING 'TEST 1b FAILED: hex_avvikande_srid saknar rad för sk0_kba_stale.srid_y före DROP';
    END IF;

    IF EXISTS (SELECT 1 FROM public.hex_dummy_geometrier WHERE schema_namn = 'sk0_kba_stale')
       AND EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri WHERE schema_namn = 'sk0_kba_stale') THEN
        RAISE NOTICE 'TEST 1c PASSED: hex_dummy_geometrier och hex_afvaktande_geometri har rader före DROP';
    ELSE
        RAISE WARNING 'TEST 1c FAILED: hex_dummy_geometrier/hex_afvaktande_geometri saknar rader före DROP';
    END IF;
END $$;

-- ============================================================
-- DROP SCHEMA ... CASCADE
-- ============================================================
-- Spara OID:erna så att vi kan kontrollera att de inte finns kvar
CREATE TEMP TABLE _stale_oider AS
    SELECT parent_oid FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale';

DROP SCHEMA sk0_kba_stale CASCADE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale') THEN
        RAISE NOTICE 'TEST 2a PASSED: hex_metadata-rader för sk0_kba_stale borttagna';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: % rad(er) kvar i hex_metadata för sk0_kba_stale',
            (SELECT count(*) FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.hex_metadata m
                   JOIN _stale_oider o ON o.parent_oid = m.parent_oid) THEN
        RAISE NOTICE 'TEST 2b PASSED: Inga inaktuella parent_oid kvar i hex_metadata';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: Inaktuella parent_oid kvar i hex_metadata';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.hex_avvikande_srid WHERE schema_namn = 'sk0_kba_stale') THEN
        RAISE NOTICE 'TEST 2c PASSED: hex_avvikande_srid-rader för sk0_kba_stale borttagna';
    ELSE
        RAISE WARNING 'TEST 2c FAILED: Rader kvar i hex_avvikande_srid för sk0_kba_stale';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.hex_dummy_geometrier WHERE schema_namn = 'sk0_kba_stale') THEN
        RAISE NOTICE 'TEST 2d PASSED: hex_dummy_geometrier-rader för sk0_kba_stale borttagna';
    ELSE
        RAISE WARNING 'TEST 2d FAILED: Rader kvar i hex_dummy_geometrier för sk0_kba_stale';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri WHERE schema_namn = 'sk0_kba_stale') THEN
        RAISE NOTICE 'TEST 2e PASSED: hex_afvaktande_geometri-rader för sk0_kba_stale borttagna';
    ELSE
        RAISE WARNING 'TEST 2e FAILED: Rader kvar i hex_afvaktande_geometri för sk0_kba_stale';
    END IF;

    -- Kontrollschemat ska vara orört
    IF EXISTS (SELECT 1 FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale2') THEN
        RAISE NOTICE 'TEST 2f PASSED: hex_metadata för orelaterat schema sk0_kba_stale2 bevarad';
    ELSE
        RAISE WARNING 'TEST 2f FAILED: hex_metadata för sk0_kba_stale2 felaktigt borttagen';
    END IF;
END $$;

-- ============================================================
-- Återskapa schema med samma namn: ny tabell ska få exakt en rad
-- ============================================================
CREATE SCHEMA sk0_kba_stale;
CREATE TABLE sk0_kba_stale.t_y (namn text, geom geometry(Polygon, 3007));

DO $$
BEGIN
    IF (SELECT count(*) FROM public.hex_metadata WHERE parent_schema = 'sk0_kba_stale') = 1
       AND EXISTS (SELECT 1 FROM public.hex_metadata
                   WHERE parent_oid = 'sk0_kba_stale.t_y'::regclass) THEN
        RAISE NOTICE 'TEST 3 PASSED: Återskapat schema har exakt en korrekt hex_metadata-rad';
    ELSE
        RAISE WARNING 'TEST 3 FAILED: Fel antal/innehåll i hex_metadata efter återskapande';
    END IF;
END $$;

-- ============================================================
-- Slutstädning
-- ============================================================
DROP TABLE _stale_oider;
DROP SCHEMA sk0_kba_stale CASCADE;
DROP SCHEMA sk0_kba_stale2 CASCADE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hex_metadata
                   WHERE parent_schema IN ('sk0_kba_stale', 'sk0_kba_stale2')) THEN
        RAISE NOTICE 'TEST 4 PASSED: Slutstädning lämnade inga hex_metadata-rader';
    ELSE
        RAISE WARNING 'TEST 4 FAILED: hex_metadata-rader kvar efter slutstädning';
    END IF;
END $$;
