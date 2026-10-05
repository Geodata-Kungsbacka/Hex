-- ============================================================
-- TEST: ALTER TABLE ... RENAME TO på Hex-tabeller
--
-- Täcker två fel i RENAME TO-grenen i hex_hantera_ny_kolumn():
--
--   #176  Objekt som Hex namnger efter tabellen (identitetssekvens,
--         historikindex, GiST-index, geometrivalidering, QA-trigger och
--         triggerfunktioner) blev kvar under det gamla namnet. En ny tabell
--         med det gamla namnet gick då inte att skapa, och gick det ändå
--         skrevs den omdöpta tabellens QA-triggerfunktion över.
--   #177  Namnbytet avgjordes på satstexten (current_query()), så vanliga
--         ALTER TABLE vars text innehöll "rename to" togs för namnbyten och
--         avbröts med "relation <tabell>_h already exists".
--
-- Schema som används: sk1_kba_tnamnbyte
-- Konvention: PASS / FAIL
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: ALTER TABLE ... RENAME TO'
\echo '============================================================'

DROP TABLE IF EXISTS _tnb_results;
CREATE TEMP TABLE _tnb_results (
    nr       int,
    namn     text,
    status   text,  -- PASS / FAIL
    notering text
);

CREATE OR REPLACE FUNCTION _tnb(nr int, namn text, ok boolean, notering text DEFAULT '') RETURNS void AS $$
BEGIN
    INSERT INTO _tnb_results
    VALUES (nr, namn, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN ok THEN '' ELSE coalesce(notering, '') END);
END $$ LANGUAGE plpgsql;

DROP SCHEMA IF EXISTS sk1_kba_tnamnbyte CASCADE;
CREATE SCHEMA sk1_kba_tnamnbyte;

-- ============================================================
-- T1–T4 (#176): namnbyte och ny tabell med det gamla namnet
-- ============================================================
CREATE TABLE sk1_kba_tnamnbyte.alfa_y (namn text, geom geometry(Polygon, 3007));
INSERT INTO sk1_kba_tnamnbyte.alfa_y (namn, geom)
VALUES ('a', 'SRID=3007;POLYGON((0 0,0 10,10 10,10 0,0 0))');

ALTER TABLE sk1_kba_tnamnbyte.alfa_y RENAME TO beta_y;

-- T1: alla härledda objekt bär det nya namnet
DO $$
DECLARE
    saknas text[] := '{}';
    kvar   text[] := '{}';
    n      text;
    oid_b  oid := 'sk1_kba_tnamnbyte.beta_y'::regclass;
BEGIN
    FOREACH n IN ARRAY ARRAY['beta_y_gid_seq', 'beta_y_h_idx', 'beta_y_geom_gidx'] LOOP
        IF to_regclass('sk1_kba_tnamnbyte.' || n) IS NULL THEN saknas := saknas || n; END IF;
    END LOOP;
    FOREACH n IN ARRAY ARRAY['alfa_y_gid_seq', 'alfa_y_h_idx', 'alfa_y_geom_gidx'] LOOP
        IF to_regclass('sk1_kba_tnamnbyte.' || n) IS NOT NULL THEN kvar := kvar || n; END IF;
    END LOOP;
    FOREACH n IN ARRAY ARRAY['trg_fn_beta_y_qa', 'trg_fn_beta_y_insert_audit'] LOOP
        IF to_regprocedure('sk1_kba_tnamnbyte.' || n || '()') IS NULL THEN saknas := saknas || n; END IF;
    END LOOP;
    FOREACH n IN ARRAY ARRAY['trg_fn_alfa_y_qa', 'trg_fn_alfa_y_insert_audit'] LOOP
        IF to_regprocedure('sk1_kba_tnamnbyte.' || n || '()') IS NOT NULL THEN kvar := kvar || n; END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = oid_b AND tgname = 'trg_beta_y_qa') THEN
        saknas := saknas || 'trg_beta_y_qa'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = oid_b AND conname = 'validera_geom_beta_y') THEN
        saknas := saknas || 'validera_geom_beta_y'::text;
    END IF;
    IF (SELECT trigger_funktion FROM hex_metadata WHERE parent_oid = oid_b) IS DISTINCT FROM 'trg_fn_beta_y_qa' THEN
        saknas := saknas || 'hex_metadata.trigger_funktion'::text;
    END IF;

    PERFORM _tnb(1, 'Härledda objekt följer med RENAME TO',
                 saknas = '{}' AND kvar = '{}',
                 format('saknas: %s, kvar: %s', saknas, kvar));
END $$;

-- T2: en ny tabell med det gamla namnet går att skapa
DO $$
BEGIN
    CREATE TABLE sk1_kba_tnamnbyte.alfa_y (namn text, geom geometry(Polygon, 3007));
    INSERT INTO sk1_kba_tnamnbyte.alfa_y (namn, geom)
    VALUES ('x', 'SRID=3007;POLYGON((0 0,0 5,5 5,5 0,0 0))');
    PERFORM _tnb(2, 'CREATE TABLE med det gamla namnet efter RENAME TO', true);
EXCEPTION WHEN OTHERS THEN
    PERFORM _tnb(2, 'CREATE TABLE med det gamla namnet efter RENAME TO', false, SQLERRM);
END $$;

-- T3: UPDATE på båda tabellerna skriver till respektive historik
DISCARD PLANS;
DO $$
BEGIN
    UPDATE sk1_kba_tnamnbyte.beta_y SET namn = 'b';
    UPDATE sk1_kba_tnamnbyte.alfa_y SET namn = 'y';
    PERFORM _tnb(3, 'UPDATE på omdöpt och ny tabell skriver rätt historik',
        (SELECT string_agg(namn, ',') FROM sk1_kba_tnamnbyte.beta_y_h) = 'a'
        AND (SELECT string_agg(namn, ',') FROM sk1_kba_tnamnbyte.alfa_y_h) = 'x',
        format('beta_y_h: %s, alfa_y_h: %s',
            (SELECT string_agg(namn, ',') FROM sk1_kba_tnamnbyte.beta_y_h),
            (SELECT string_agg(namn, ',') FROM sk1_kba_tnamnbyte.alfa_y_h)));
EXCEPTION WHEN OTHERS THEN
    PERFORM _tnb(3, 'UPDATE på omdöpt och ny tabell skriver rätt historik', false, SQLERRM);
END $$;

-- T4: den nya tabellen fick sitt GiST-index (CREATE INDEX IF NOT EXISTS
-- hoppade tidigare över det när den omdöpta tabellen bar namnet)
DO $$
BEGIN
    PERFORM _tnb(4, 'Ny tabell med det gamla namnet får eget GiST-index',
        EXISTS (SELECT 1 FROM pg_index i
                JOIN pg_class c ON c.oid = i.indexrelid
                WHERE i.indrelid = to_regclass('sk1_kba_tnamnbyte.alfa_y')
                  AND c.relname = 'alfa_y_geom_gidx'));
END $$;

-- T5: DROP TABLE på den omdöpta tabellen tar dess triggerfunktion och
-- lämnar den nya tabellens i fred
DROP TABLE sk1_kba_tnamnbyte.beta_y;
DO $$
BEGIN
    UPDATE sk1_kba_tnamnbyte.alfa_y SET namn = 'z';
    PERFORM _tnb(5, 'DROP TABLE på omdöpt tabell rör inte den nya',
        to_regprocedure('sk1_kba_tnamnbyte.trg_fn_beta_y_qa()') IS NULL
        AND to_regprocedure('sk1_kba_tnamnbyte.trg_fn_alfa_y_qa()') IS NOT NULL
        AND (SELECT count(*) FROM sk1_kba_tnamnbyte.alfa_y_h WHERE h_typ = 'U') = 2,
        format('trg_fn_beta_y_qa: %s, trg_fn_alfa_y_qa: %s, rader i alfa_y_h: %s',
            to_regprocedure('sk1_kba_tnamnbyte.trg_fn_beta_y_qa()'),
            to_regprocedure('sk1_kba_tnamnbyte.trg_fn_alfa_y_qa()'),
            (SELECT count(*) FROM sk1_kba_tnamnbyte.alfa_y_h WHERE h_typ = 'U')));
EXCEPTION WHEN OTHERS THEN
    PERFORM _tnb(5, 'DROP TABLE på omdöpt tabell rör inte den nya', false, SQLERRM);
END $$;

-- ============================================================
-- T6–T8 (#177): "rename to" i satstexten utan namnbyte
-- ============================================================
CREATE TABLE sk1_kba_tnamnbyte.eta_y (namn text, geom geometry(Polygon, 3007));
CREATE TABLE sk1_kba_tnamnbyte.theta_y (namn text, geom geometry(Polygon, 3007));

-- T6: strängen "rename to" i ett DEFAULT-värde
DO $$
BEGIN
    ALTER TABLE sk1_kba_tnamnbyte.eta_y ADD COLUMN kommentar text DEFAULT 'rename to';
    PERFORM _tnb(6, 'ADD COLUMN med DEFAULT ''rename to''',
        EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'sk1_kba_tnamnbyte' AND table_name = 'eta_y_h'
                  AND column_name = 'kommentar'),
        'kolumnen saknas i historiken');
EXCEPTION WHEN OTHERS THEN
    PERFORM _tnb(6, 'ADD COLUMN med DEFAULT ''rename to''', false, SQLERRM);
END $$;

-- T7: RENAME TO följt av ADD COLUMN i samma DO-block
DO $$
BEGIN
    ALTER TABLE sk1_kba_tnamnbyte.theta_y RENAME TO iota_y;
    ALTER TABLE sk1_kba_tnamnbyte.iota_y ADD COLUMN antal integer;
    PERFORM _tnb(7, 'RENAME TO och ADD COLUMN i samma DO-block',
        to_regclass('sk1_kba_tnamnbyte.iota_y_h') IS NOT NULL
        AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'sk1_kba_tnamnbyte' AND table_name = 'iota_y_h'
                      AND column_name = 'antal'),
        'historiken döptes inte om eller fick inte kolumnen');
EXCEPTION WHEN OTHERS THEN
    PERFORM _tnb(7, 'RENAME TO och ADD COLUMN i samma DO-block', false, SQLERRM);
END $$;

-- T8: multisats – current_query() är hela strängen för båda kommandona
CREATE TABLE sk1_kba_tnamnbyte.kappa_y (namn text, geom geometry(Polygon, 3007));
ALTER TABLE sk1_kba_tnamnbyte.kappa_y RENAME TO lambda_y \; ALTER TABLE sk1_kba_tnamnbyte.eta_y ADD COLUMN x integer;
DO $$
BEGIN
    PERFORM _tnb(8, 'Multisats: RENAME TO följt av ADD COLUMN på annan tabell',
        to_regclass('sk1_kba_tnamnbyte.lambda_y_h') IS NOT NULL
        AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'sk1_kba_tnamnbyte' AND table_name = 'eta_y_h'
                      AND column_name = 'x'),
        'lambda_y_h saknas eller eta_y_h saknar kolumnen x');
END $$;

-- ============================================================
-- Resultat
-- ============================================================
\echo ''
\echo '--- Resultat: ALTER TABLE ... RENAME TO ---'
SELECT nr, namn, status, notering FROM _tnb_results ORDER BY nr;

SELECT
    count(*) FILTER (WHERE status = 'PASS') AS pass,
    count(*) FILTER (WHERE status = 'FAIL') AS fail
FROM _tnb_results;

DROP SCHEMA IF EXISTS sk1_kba_tnamnbyte CASCADE;
DROP FUNCTION IF EXISTS _tnb(int, text, boolean, text);
