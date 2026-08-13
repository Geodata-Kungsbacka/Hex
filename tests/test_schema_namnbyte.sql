-- ============================================================
-- TEST: hex_blockera_schema_namnbyte()
--
-- Täcker event-triggern hex_blockera_schema_namnbyte_trigger, som
-- installeras av Hex men saknade testtäckning helt.
--
-- Funktionen avgör om en ALTER SCHEMA-sats är ett namnbyte genom att
-- matcha current_query() mot mönstret '\mRENAME\s+TO\M'. Sviten täcker
-- både det avsedda beteendet och den heuristikens svaghet.
--
-- Scheman som används: sk0_ext_namnbyte, sk0_ext_namnbytedo
-- Konvention: PASS / XFAIL (Hex blockerade korrekt) / FAIL
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: Blockering av ALTER SCHEMA ... RENAME TO'
\echo '============================================================'

-- ============================================================
-- Resultattabell och hjälpare
-- ============================================================
DROP TABLE IF EXISTS _namnbyte_results;
CREATE TEMP TABLE _namnbyte_results (
    nr      int,
    namn    text,
    status  text,  -- PASS / FAIL / XFAIL
    notering text
);

CREATE OR REPLACE FUNCTION _nb_pass(nr int, namn text, notering text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _namnbyte_results VALUES (nr, namn, 'PASS', notering); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _nb_xfail(nr int, namn text, notering text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _namnbyte_results VALUES (nr, namn, 'XFAIL', notering); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _nb_fail(nr int, namn text, notering text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _namnbyte_results VALUES (nr, namn, 'FAIL', notering); END $$ LANGUAGE plpgsql;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_namnbyte CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_namnbytedo CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_namnbyte_nytt CASCADE;

-- ============================================================
-- N1: Event-triggern är installerad och aktiv
-- ============================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_event_trigger
        WHERE evtname = 'hex_blockera_schema_namnbyte_trigger'
          AND evtenabled <> 'D'
    ) THEN
        PERFORM _nb_pass(1, 'Event-trigger installerad och aktiverad');
    ELSE
        PERFORM _nb_fail(1, 'Event-trigger installerad och aktiverad',
                         'hex_blockera_schema_namnbyte_trigger saknas eller är avstängd');
    END IF;
END $$;

-- ============================================================
-- N2: ALTER SCHEMA ... RENAME TO ska blockeras
-- ============================================================
CREATE SCHEMA sk0_ext_namnbyte;

DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER SCHEMA sk0_ext_namnbyte RENAME TO sk0_ext_namnbyte_nytt';
        PERFORM _nb_fail(2, 'RENAME TO blockeras',
                         'Namnbytet gick igenom – blockeringen fungerade inte');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%RENAME TO är inte tillåtet%' THEN
            PERFORM _nb_xfail(2, 'RENAME TO blockeras', 'Hex blockerade namnbytet korrekt');
        ELSE
            PERFORM _nb_fail(2, 'RENAME TO blockeras',
                             'Blockerades men med oväntat fel: ' || SQLERRM);
        END IF;
    END;
END $$;

-- ============================================================
-- N3: Schemat ska vara oförändrat efter ett blockerat namnbyte
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sk0_ext_namnbyte')
       AND NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sk0_ext_namnbyte_nytt') THEN
        PERFORM _nb_pass(3, 'Schemat oförändrat efter blockerat namnbyte');
    ELSE
        PERFORM _nb_fail(3, 'Schemat oförändrat efter blockerat namnbyte',
                         'Schemat bytte namn trots blockering');
    END IF;
END $$;

-- ============================================================
-- N4: ALTER SCHEMA ... OWNER TO ska INTE blockeras
--
-- Hex kör själv ALTER SCHEMA ... OWNER TO inifrån hex_hantera_std_roller
-- vid CREATE SCHEMA. Blockeras den satsen går det inte att skapa scheman.
-- ============================================================
DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER SCHEMA sk0_ext_namnbyte OWNER TO postgres';
        PERFORM _nb_pass(4, 'OWNER TO tillåts');
    EXCEPTION WHEN OTHERS THEN
        PERFORM _nb_fail(4, 'OWNER TO tillåts',
                         'ALTER SCHEMA ... OWNER TO blockerades felaktigt: ' || SQLERRM);
    END;
END $$;

-- Återställ ägarskapet till Hex ägarroll
DO $$
BEGIN
    EXECUTE format('ALTER SCHEMA sk0_ext_namnbyte OWNER TO %I', public.hex_systemagare());
END $$;

-- ============================================================
-- N5: REGRESSION – falskt positivt utslag från current_query()
--
-- hex_blockera_schema_namnbyte matchar current_query(), inte den faktiska
-- DDL-satsen. current_query() returnerar den YTTERSTA satsen. Ett CREATE
-- SCHEMA inuti ett DO-block vars text råkar innehålla frasen "RENAME TO"
-- (även i en kommentar) gör därför att den ALTER SCHEMA ... OWNER TO som
-- hex_hantera_std_roller kör internt felaktigt tolkas som ett namnbyte.
--
-- Följden är att CREATE SCHEMA misslyckas – med det missvisande felet
-- 'record "rollkonfiguration" is not assigned yet', eftersom felet fångas
-- och maskeras av felhanteringen i hex_hantera_std_roller.
--
-- Samma sak händer när en klient skickar flera satser i EN simple query,
-- t.ex. 'ALTER TABLE ... RENAME TO ...; CREATE SCHEMA ...;' – ett mönster
-- migreringsverktyg och ETL-klienter använder rutinmässigt.
--
-- Rätt beteende: bara ett verkligt schemanamnbyte ska blockeras.
-- ============================================================
DO $$
BEGIN
    BEGIN
        -- Kommentaren nedan innehåller frasen, men satsen är ett CREATE SCHEMA
        EXECUTE 'DO $inner$ BEGIN /* RENAME TO */ EXECUTE ''CREATE SCHEMA sk0_ext_namnbytedo''; END $inner$;';

        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sk0_ext_namnbytedo') THEN
            PERFORM _nb_pass(5, 'CREATE SCHEMA blockeras inte av frasen RENAME TO i yttre sats');
        ELSE
            PERFORM _nb_fail(5, 'CREATE SCHEMA blockeras inte av frasen RENAME TO i yttre sats',
                             'Schemat skapades inte');
        END IF;
    EXCEPTION WHEN OTHERS THEN
        PERFORM _nb_fail(5, 'CREATE SCHEMA blockeras inte av frasen RENAME TO i yttre sats',
                         'FALSKT POSITIVT: CREATE SCHEMA stoppades av namnbytesblockeringen. Fel: ' || SQLERRM);
    END;
END $$;

-- ============================================================
-- N6: Blockeringen får inte gå på tabellnamnbyten
--
-- ALTER TABLE ... RENAME TO är tillåtet i Hex (se test_extended_cd.sql D5)
-- och ska aldrig fångas av schemablockeringen.
-- ============================================================
CREATE TABLE sk0_ext_namnbyte.namnbyte_a_p (
    namn text,
    geom geometry(Point, 3007)
);

DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER TABLE sk0_ext_namnbyte.namnbyte_a_p RENAME TO namnbyte_b_p';
        IF EXISTS (
            SELECT 1 FROM pg_tables
            WHERE schemaname = 'sk0_ext_namnbyte' AND tablename = 'namnbyte_b_p'
        ) THEN
            PERFORM _nb_pass(6, 'ALTER TABLE ... RENAME TO tillåts');
        ELSE
            PERFORM _nb_fail(6, 'ALTER TABLE ... RENAME TO tillåts', 'Tabellen bytte inte namn');
        END IF;
    EXCEPTION WHEN OTHERS THEN
        PERFORM _nb_fail(6, 'ALTER TABLE ... RENAME TO tillåts',
                         'Tabellnamnbyte blockerades felaktigt: ' || SQLERRM);
    END;
END $$;

-- ============================================================
-- Resultat
-- ============================================================
\echo ''
\echo '--- Resultat: blockering av schemanamnbyte ---'
SELECT nr, namn, status, notering FROM _namnbyte_results ORDER BY nr;

SELECT
    count(*) FILTER (WHERE status = 'PASS')  AS pass,
    count(*) FILTER (WHERE status = 'XFAIL') AS xfail,
    count(*) FILTER (WHERE status = 'FAIL')  AS fail
FROM _namnbyte_results;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk0_ext_namnbyte CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_namnbytedo CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_namnbyte_nytt CASCADE;
DROP FUNCTION IF EXISTS _nb_pass(int, text, text);
DROP FUNCTION IF EXISTS _nb_xfail(int, text, text);
DROP FUNCTION IF EXISTS _nb_fail(int, text, text);
