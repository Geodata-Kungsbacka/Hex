-- ============================================================
-- TEST: hex_tillampa_grupprattigheter() och hex_grupprattigheter
--
-- Täcker mappningen mellan AD-synkade grupproller och Hex schemaroller.
-- Både tabellen och funktionen installeras av Hex men saknade
-- testtäckning helt.
--
-- Funktionen är SECURITY DEFINER och beviljar r_/w_-roller vidare till
-- AD-grupproller. Den förutsätter att den ägs av hex_systemagare(), som
-- är den enda roll som får ADMIN OPTION på schemarollerna (beviljas i
-- hex_hantera_std_roller vid CREATE SCHEMA).
--
-- Schema som används: sk1_kba_gruppratt
-- Roller som används: ad_gruppratt_test, ad_gruppratt_saknad
-- Konvention: PASS / XFAIL / FAIL
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: Grupprättigheter (AD-grupproll -> Hex-schemaroll)'
\echo '============================================================'

-- ============================================================
-- Resultattabell och hjälpare
-- ============================================================
CREATE TEMP TABLE _gr_results (
    nr       int,
    namn     text,
    status   text,  -- PASS / FAIL / XFAIL
    notering text
);

CREATE OR REPLACE FUNCTION _gr_pass(nr int, namn text, notering text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _gr_results VALUES (nr, namn, 'PASS', notering); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _gr_fail(nr int, namn text, notering text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _gr_results VALUES (nr, namn, 'FAIL', notering); END $$ LANGUAGE plpgsql;

-- ============================================================
-- Isolering av testdata
--
-- hex_tillampa_grupprattigheter() bearbetar ALLA rader i tabellen, så
-- räknarna (beviljade/hoppade_over) går bara att göra deterministiska
-- påståenden om ifall tabellen bara innehåller sviternas egna rader.
-- Befintlig DBA-konfiguration sparas undan och läggs tillbaka på slutet.
-- ============================================================
CREATE TEMP TABLE _gr_sparad AS
SELECT ad_grupproll, hex_roll, beskrivning FROM public.hex_grupprattigheter;

DELETE FROM public.hex_grupprattigheter;

DROP SCHEMA IF EXISTS sk1_kba_gruppratt CASCADE;
DROP ROLE IF EXISTS ad_gruppratt_test;

-- ============================================================
-- Förberedelse
-- ============================================================
CREATE SCHEMA sk1_kba_gruppratt;
CREATE ROLE ad_gruppratt_test NOLOGIN;

-- ============================================================
-- G1: Ägarskapsinvariant
--
-- hex_tillampa_grupprattigheter är SECURITY DEFINER och måste ägas av
-- hex_systemagare(). Ägs den av någon annan roll saknar den både
-- ADMIN OPTION på schemarollerna och rättigheter på hex_grupprattigheter,
-- och varje GRANT misslyckas.
--
-- REGRESSIONSVAKT: hex_tillampa_grupprattigheter.sql har 'OWNER TO gis_admin'
-- hårdkodat, och process_sql() i install_hex.py skriver INTE om OWNER TO i
-- filer som innehåller SECURITY DEFINER. Med ett annat owner_role än
-- 'gis_admin' hamnar ägarskapet därför fel.
-- ============================================================
DO $$
DECLARE
    v_agare     text;
    v_forvantad text := public.hex_systemagare();
BEGIN
    SELECT pg_get_userbyid(p.proowner) INTO v_agare
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'hex_tillampa_grupprattigheter';

    IF v_agare = v_forvantad THEN
        PERFORM _gr_pass(1, 'Funktionen ägs av hex_systemagare()',
                         'ägare: ' || v_agare);
    ELSE
        PERFORM _gr_fail(1, 'Funktionen ägs av hex_systemagare()',
                         format('ägare är %s men hex_systemagare() är %s – '
                                'GRANT kommer att misslyckas', v_agare, v_forvantad));
    END IF;
END $$;

-- ============================================================
-- G2: Giltig mappning beviljas
-- ============================================================
INSERT INTO public.hex_grupprattigheter (ad_grupproll, hex_roll, beskrivning)
VALUES ('ad_gruppratt_test', 'r_sk1_kba_gruppratt', 'Testmappning: läsroll');

DO $$
DECLARE
    v_beviljade integer;
    v_fel       integer;
BEGIN
    SELECT beviljade, fel INTO v_beviljade, v_fel
    FROM public.hex_tillampa_grupprattigheter();

    IF v_beviljade = 1 AND v_fel = 0 THEN
        PERFORM _gr_pass(2, 'Giltig mappning beviljas');
    ELSE
        PERFORM _gr_fail(2, 'Giltig mappning beviljas',
                         format('beviljade=%s fel=%s (förväntade 1 respektive 0)',
                                v_beviljade, v_fel));
    END IF;
END $$;

-- ============================================================
-- G3: Medlemskapet finns faktiskt i pg_auth_members
-- ============================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_auth_members m
        JOIN pg_roles beviljad ON beviljad.oid = m.roleid
        JOIN pg_roles medlem   ON medlem.oid   = m.member
        WHERE beviljad.rolname = 'r_sk1_kba_gruppratt'
          AND medlem.rolname   = 'ad_gruppratt_test'
    ) THEN
        PERFORM _gr_pass(3, 'Medlemskap registrerat i pg_auth_members');
    ELSE
        PERFORM _gr_fail(3, 'Medlemskap registrerat i pg_auth_members',
                         'ad_gruppratt_test är inte medlem i r_sk1_kba_gruppratt');
    END IF;
END $$;

-- ============================================================
-- G4: AD-roll som inte finns i pg_roles hoppas över, inte fel
-- ============================================================
INSERT INTO public.hex_grupprattigheter (ad_grupproll, hex_roll, beskrivning)
VALUES ('ad_gruppratt_saknad', 'r_sk1_kba_gruppratt', 'Testmappning: AD-roll saknas');

DO $$
DECLARE
    v_hoppade integer;
    v_fel     integer;
BEGIN
    SELECT hoppade_over, fel INTO v_hoppade, v_fel
    FROM public.hex_tillampa_grupprattigheter();

    IF v_hoppade >= 1 AND v_fel = 0 THEN
        PERFORM _gr_pass(4, 'Saknad AD-roll hoppas över utan fel',
                         format('hoppade_over=%s', v_hoppade));
    ELSE
        PERFORM _gr_fail(4, 'Saknad AD-roll hoppas över utan fel',
                         format('hoppade_over=%s fel=%s (förväntade >=1 respektive 0)',
                                v_hoppade, v_fel));
    END IF;
END $$;

-- ============================================================
-- G5: Hex-roll som inte finns hoppas över, inte fel
-- ============================================================
DELETE FROM public.hex_grupprattigheter WHERE ad_grupproll = 'ad_gruppratt_saknad';

INSERT INTO public.hex_grupprattigheter (ad_grupproll, hex_roll, beskrivning)
VALUES ('ad_gruppratt_test', 'r_sk1_kba_finns_inte', 'Testmappning: Hex-roll saknas');

DO $$
DECLARE
    v_hoppade integer;
    v_fel     integer;
BEGIN
    SELECT hoppade_over, fel INTO v_hoppade, v_fel
    FROM public.hex_tillampa_grupprattigheter();

    IF v_hoppade >= 1 AND v_fel = 0 THEN
        PERFORM _gr_pass(5, 'Saknad Hex-roll hoppas över utan fel',
                         format('hoppade_over=%s', v_hoppade));
    ELSE
        PERFORM _gr_fail(5, 'Saknad Hex-roll hoppas över utan fel',
                         format('hoppade_over=%s fel=%s (förväntade >=1 respektive 0)',
                                v_hoppade, v_fel));
    END IF;
END $$;

DELETE FROM public.hex_grupprattigheter WHERE hex_roll = 'r_sk1_kba_finns_inte';

-- ============================================================
-- G6: Idempotens – en andra körning ska ge samma resultat utan fel
-- ============================================================
DO $$
DECLARE
    v_beviljade integer;
    v_fel       integer;
BEGIN
    SELECT beviljade, fel INTO v_beviljade, v_fel
    FROM public.hex_tillampa_grupprattigheter();

    IF v_beviljade = 1 AND v_fel = 0 THEN
        PERFORM _gr_pass(6, 'Idempotent vid upprepad körning');
    ELSE
        PERFORM _gr_fail(6, 'Idempotent vid upprepad körning',
                         format('beviljade=%s fel=%s vid andra körningen',
                                v_beviljade, v_fel));
    END IF;
END $$;

-- ============================================================
-- G7: Mappningen städas inte bort av DROP SCHEMA
--
-- hex_grupprattigheter är DBA-underhållen konfiguration. Raderna ska
-- överleva att schemat tas bort, så att en återskapad schemaversion får
-- tillbaka sina rättigheter vid nästa körning.
-- ============================================================
DROP SCHEMA sk1_kba_gruppratt CASCADE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_grupprattigheter
        WHERE ad_grupproll = 'ad_gruppratt_test'
          AND hex_roll = 'r_sk1_kba_gruppratt'
    ) THEN
        PERFORM _gr_pass(7, 'Mappningen överlever DROP SCHEMA');
    ELSE
        PERFORM _gr_fail(7, 'Mappningen överlever DROP SCHEMA',
                         'Raden försvann när schemat togs bort');
    END IF;
END $$;

-- ============================================================
-- Resultat
-- ============================================================
\echo ''
\echo '--- Resultat: grupprättigheter ---'
SELECT nr, namn, status, notering FROM _gr_results ORDER BY nr;

SELECT
    count(*) FILTER (WHERE status = 'PASS')  AS pass,
    count(*) FILTER (WHERE status = 'XFAIL') AS xfail,
    count(*) FILTER (WHERE status = 'FAIL')  AS fail
FROM _gr_results;

-- ============================================================
-- Städning – återställ DBA-konfigurationen som sparades i början
-- ============================================================
DELETE FROM public.hex_grupprattigheter;

INSERT INTO public.hex_grupprattigheter (ad_grupproll, hex_roll, beskrivning)
SELECT ad_grupproll, hex_roll, beskrivning FROM _gr_sparad;

DROP TABLE _gr_sparad;

DROP SCHEMA IF EXISTS sk1_kba_gruppratt CASCADE;
DROP ROLE IF EXISTS ad_gruppratt_test;
DROP FUNCTION IF EXISTS _gr_pass(int, text, text);
DROP FUNCTION IF EXISTS _gr_fail(int, text, text);
