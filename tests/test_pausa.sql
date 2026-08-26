-- =============================================================================
-- TESTSVIT: hex_pausa() / hex_ateruppta() / hex_pausstatus()
--
-- Täcker pauslägets mekanik: att event-triggers och radtriggers stängs av, att
-- lägena från före pausen läggs tillbaka exakt, att avvikelser mellan
-- hex_paus och katalogerna upptäcks, samt regressionsvakten för det som gjorde
-- pausen nödvändig från början – geometrivalideringens search_path.
--
-- Körs som: sudo -u postgres psql -d hex_test -f tests/test_pausa.sql
-- Kräver superanvändare (ALTER EVENT TRIGGER).
-- =============================================================================

\set ON_ERROR_STOP off
SET client_min_messages = WARNING;

CREATE TABLE IF NOT EXISTS _test_results (
    nr      int,
    name    text,
    status  text,
    note    text
);
TRUNCATE _test_results;

CREATE OR REPLACE FUNCTION _pass(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'PASS', note); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _xfail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'XFAIL', note); END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _fail(nr int, name text, note text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO _test_results VALUES (nr, name, 'FAIL', note); END $$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP
-- Sviten förutsätter att Hex INTE är pausat när den startar. Är det pausat är
-- databasen mitt i en återläsning och sviten ska inte köra alls.
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.hex_paus) THEN
        RAISE EXCEPTION 'Hex är pausat – kör hex_ateruppta() innan testsviten körs';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS sk0_kba_paus;
CREATE TABLE IF NOT EXISTS sk0_kba_paus.stigar_l (
    namn text,
    geom geometry(LineString, 3006)
);
INSERT INTO sk0_kba_paus.stigar_l (namn, geom)
SELECT 'stig' || i, ST_GeomFromText('LINESTRING(0 0,' || i || ' ' || i || ')', 3006)
FROM   generate_series(1, 3) i;

-- =============================================================================
-- GRUPP 1: PAUSA
-- =============================================================================

-- TEST 01: hex_pausa stänger av samtliga Hex event-triggers
DO $$ DECLARE
    kvar integer;
BEGIN
    PERFORM count(*) FROM public.hex_pausa('testsvit 01', 1);

    SELECT count(*) INTO kvar
    FROM   pg_event_trigger et
    JOIN   pg_proc          p ON p.oid = et.evtfoid
    JOIN   pg_namespace     n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname LIKE 'hex\_%'
      AND  et.evtenabled <> 'D';

    IF kvar = 0 THEN
        PERFORM _pass(01, 'hex_pausa: alla event-triggers avstängda');
    ELSE
        PERFORM _fail(01, 'hex_pausa: alla event-triggers avstängda',
            format('%s fortfarande påslagna', kvar));
    END IF;
END $$;

-- TEST 02: hex_pausa stänger av radtriggers på Hex-tabeller
DO $$ DECLARE
    kvar integer;
BEGIN
    SELECT count(*) INTO kvar
    FROM   pg_trigger   tg
    JOIN   pg_class     c ON c.oid = tg.tgrelid
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  NOT tg.tgisinternal
      AND  n.nspname = 'sk0_kba_paus'
      AND  tg.tgenabled <> 'D';

    IF kvar = 0 THEN
        PERFORM _pass(02, 'hex_pausa: radtriggers avstängda');
    ELSE
        PERFORM _fail(02, 'hex_pausa: radtriggers avstängda',
            format('%s fortfarande påslagna', kvar));
    END IF;
END $$;

-- TEST 03: DDL går igenom orörd under paus
-- Detta är hela poängen: CREATE TABLE ska INTE omstruktureras, få gid-kolumn,
-- historiktabell eller triggers medan Hex är pausat.
DO $$ DECLARE
    har_gid       boolean;
    har_historik  boolean;
    antal_trigg   integer;
BEGIN
    CREATE TABLE sk0_kba_paus.orord_p (namn text, geom geometry(Polygon, 3006));

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_kba_paus' AND table_name = 'orord_p'
          AND column_name = 'gid'
    ) INTO har_gid;

    SELECT to_regclass('sk0_kba_paus.orord_p_h') IS NOT NULL INTO har_historik;

    SELECT count(*) INTO antal_trigg
    FROM   pg_trigger tg
    WHERE  tg.tgrelid = 'sk0_kba_paus.orord_p'::regclass
      AND  NOT tg.tgisinternal;

    IF NOT har_gid AND NOT har_historik AND antal_trigg = 0 THEN
        PERFORM _pass(03, 'hex_pausa: CREATE TABLE lämnas orörd under paus');
    ELSE
        PERFORM _fail(03, 'hex_pausa: CREATE TABLE lämnas orörd under paus',
            format('gid=%s historik=%s triggers=%s', har_gid, har_historik, antal_trigg));
    END IF;
END $$;

-- TEST 04: DROP SCHEMA river inte rollerna under paus
-- Det är den destruktiva vägen vid pg_restore --clean.
DO $$ DECLARE
    antal_roller integer;
BEGIN
    CREATE SCHEMA sk0_kba_pausroll;

    -- Rollerna skapas inte av event-triggern nu (den är avstängd), så vi lägger
    -- upp en för hand som stand-in för en roll som redan fanns före pausen.
    CREATE ROLE r_sk0_kba_pausroll NOLOGIN;

    DROP SCHEMA sk0_kba_pausroll CASCADE;

    SELECT count(*) INTO antal_roller
    FROM   pg_roles WHERE rolname = 'r_sk0_kba_pausroll';

    IF antal_roller = 1 THEN
        PERFORM _pass(04, 'hex_pausa: DROP SCHEMA river inte roller under paus');
    ELSE
        PERFORM _fail(04, 'hex_pausa: DROP SCHEMA river inte roller under paus',
            'rollen togs bort trots pausen');
    END IF;

    DROP ROLE IF EXISTS r_sk0_kba_pausroll;
END $$;

-- TEST 05: dubbel paus avvisas
DO $$
BEGIN
    PERFORM count(*) FROM public.hex_pausa('testsvit 05');
    PERFORM _fail(05, 'hex_pausa: dubbel paus avvisas', 'andra pausen gick igenom');
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%redan pausat%' THEN
        PERFORM _xfail(05, 'hex_pausa: dubbel paus avvisas', 'korrekt blockerad');
    ELSE
        PERFORM _fail(05, 'hex_pausa: dubbel paus avvisas', SQLERRM);
    END IF;
END $$;

-- TEST 06: hex_pausstatus rapporterar pausat läge
DO $$ DECLARE
    st record;
BEGIN
    SELECT * INTO st FROM public.hex_pausstatus();

    IF st.pausad AND st.event_triggers_pa = 0 AND st.event_triggers_av > 0
       AND st.anledning = 'testsvit 01' AND st.pausad_till IS NOT NULL THEN
        PERFORM _pass(06, 'hex_pausstatus: rapporterar paus',
            format('%s event-triggers av', st.event_triggers_av));
    ELSE
        PERFORM _fail(06, 'hex_pausstatus: rapporterar paus',
            format('pausad=%s pa=%s av=%s anledning=%s',
                st.pausad, st.event_triggers_pa, st.event_triggers_av, st.anledning));
    END IF;
END $$;

-- =============================================================================
-- GRUPP 2: ÅTERUPPTA
-- =============================================================================

-- TEST 07: hex_ateruppta slår på event-triggers igen
DO $$ DECLARE
    kvar integer;
BEGIN
    DROP TABLE IF EXISTS sk0_kba_paus.orord_p;
    PERFORM count(*) FROM public.hex_ateruppta();

    SELECT count(*) INTO kvar
    FROM   pg_event_trigger et
    JOIN   pg_proc          p ON p.oid = et.evtfoid
    JOIN   pg_namespace     n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname LIKE 'hex\_%'
      AND  et.evtenabled = 'D';

    IF kvar = 0 THEN
        PERFORM _pass(07, 'hex_ateruppta: event-triggers påslagna');
    ELSE
        PERFORM _fail(07, 'hex_ateruppta: event-triggers påslagna',
            format('%s fortfarande avstängda', kvar));
    END IF;
END $$;

-- TEST 08: hex_paus-raden är borta efter återupptagande
DO $$ DECLARE
    st record;
BEGIN
    SELECT * INTO st FROM public.hex_pausstatus();

    IF NOT st.pausad AND st.avvikelse IS NULL THEN
        PERFORM _pass(08, 'hex_ateruppta: bokföringen städad');
    ELSE
        PERFORM _fail(08, 'hex_ateruppta: bokföringen städad',
            format('pausad=%s avvikelse=%s', st.pausad, coalesce(st.avvikelse, '-')));
    END IF;
END $$;

-- TEST 09: historik och QA-kolumner fungerar igen efter återupptagande
-- Räknar bara U-rader. Tabellen har redan en D-rad: hex_ta_bort_dummy tog bort
-- dummy-raden vid första riktiga INSERT, och den borttagningen gick genom
-- QA-triggern.
DO $$ DECLARE
    fore   integer;
    efter  integer;
    andrad text;
BEGIN
    SELECT count(*) INTO fore FROM sk0_kba_paus.stigar_l_h WHERE h_typ = 'U';

    UPDATE sk0_kba_paus.stigar_l SET namn = 'stig1_andrad' WHERE namn = 'stig1';

    SELECT count(*) INTO efter FROM sk0_kba_paus.stigar_l_h WHERE h_typ = 'U';
    SELECT andrad_av INTO andrad FROM sk0_kba_paus.stigar_l WHERE namn = 'stig1_andrad';

    IF efter = fore + 1 AND andrad IS NOT NULL THEN
        PERFORM _pass(09, 'hex_ateruppta: historik/QA aktiv igen');
    ELSE
        PERFORM _fail(09, 'hex_ateruppta: historik/QA aktiv igen',
            format('U-rader %s -> %s, andrad_av=%s', fore, efter, coalesce(andrad, 'NULL')));
    END IF;
END $$;

-- TEST 10: hex_ateruppta är idempotent
DO $$ DECLARE
    rader integer;
BEGIN
    SELECT count(*) INTO rader FROM public.hex_ateruppta();

    IF rader = 0 THEN
        PERFORM _pass(10, 'hex_ateruppta: idempotent utan paus');
    ELSE
        PERFORM _fail(10, 'hex_ateruppta: idempotent utan paus',
            format('returnerade %s rader', rader));
    END IF;
END $$;

-- TEST 11: ett läge från före pausen läggs tillbaka, inte "allt på"
-- En event-trigger som en DBA stängt av med flit ska vara avstängd även
-- efter en paus-cykel.
DO $$ DECLARE
    lage "char";
BEGIN
    ALTER EVENT TRIGGER hex_notifiera_gs_trigger DISABLE;

    PERFORM count(*) FROM public.hex_pausa('testsvit 11');
    PERFORM count(*) FROM public.hex_ateruppta(false);

    SELECT evtenabled INTO lage
    FROM   pg_event_trigger WHERE evtname = 'hex_notifiera_gs_trigger';

    IF lage = 'D' THEN
        PERFORM _pass(11, 'hex_ateruppta: tidigare avstängd trigger förblir avstängd');
    ELSE
        PERFORM _fail(11, 'hex_ateruppta: tidigare avstängd trigger förblir avstängd',
            format('läge %s, väntade D', lage));
    END IF;

    ALTER EVENT TRIGGER hex_notifiera_gs_trigger ENABLE;
END $$;

-- =============================================================================
-- GRUPP 3: AVVIKELSER
-- =============================================================================

-- TEST 12: avstängd event-trigger utan paus flaggas
-- Det här är läget efter en dump tagen under paus: pg_dump skriver ut
-- ALTER EVENT TRIGGER ... DISABLE, och den återlästa databasen är avstängd
-- utan att någon pausat den.
DO $$ DECLARE
    st record;
BEGIN
    ALTER EVENT TRIGGER hex_notifiera_gs_trigger DISABLE;

    SELECT * INTO st FROM public.hex_pausstatus();

    IF NOT st.pausad AND st.avvikelse LIKE '%avstängda utan att Hex är pausat%' THEN
        PERFORM _pass(12, 'hex_pausstatus: avvikelse utan paus flaggas');
    ELSE
        PERFORM _fail(12, 'hex_pausstatus: avvikelse utan paus flaggas',
            format('pausad=%s avvikelse=%s', st.pausad, coalesce(st.avvikelse, 'NULL')));
    END IF;

    ALTER EVENT TRIGGER hex_notifiera_gs_trigger ENABLE;
END $$;

-- TEST 13: förfallen paus flaggas
DO $$ DECLARE
    st record;
BEGIN
    PERFORM count(*) FROM public.hex_pausa('testsvit 13', 1);
    -- Backdatera gränsen i stället för att vänta ut den.
    UPDATE public.hex_paus SET pausad_till = now() - interval '1 hour';

    SELECT * INTO st FROM public.hex_pausstatus();

    IF st.forfallen AND st.avvikelse LIKE '%skulle ha hävts%' THEN
        PERFORM _pass(13, 'hex_pausstatus: förfallen paus flaggas');
    ELSE
        PERFORM _fail(13, 'hex_pausstatus: förfallen paus flaggas',
            format('forfallen=%s avvikelse=%s', st.forfallen, coalesce(st.avvikelse, 'NULL')));
    END IF;

    PERFORM count(*) FROM public.hex_ateruppta(false);
END $$;

-- TEST 14: hex_paus tål bara en rad
DO $$
BEGIN
    INSERT INTO public.hex_paus (tidigare_lage) VALUES ('{}'::jsonb);
    INSERT INTO public.hex_paus (tidigare_lage) VALUES ('{}'::jsonb);
    PERFORM _fail(14, 'hex_paus: enkelradsspärr', 'två rader accepterades');
    DELETE FROM public.hex_paus;
EXCEPTION WHEN unique_violation THEN
    DELETE FROM public.hex_paus;
    PERFORM _xfail(14, 'hex_paus: enkelradsspärr', 'andra raden blockerad');
WHEN OTHERS THEN
    DELETE FROM public.hex_paus;
    PERFORM _fail(14, 'hex_paus: enkelradsspärr', SQLERRM);
END $$;

-- TEST 15: okänd lägeskod avvisas av hex_triggerlage_sats
DO $$ DECLARE
    sats text;
BEGIN
    sats := public.hex_triggerlage_sats('X');
    PERFORM _fail(15, 'hex_triggerlage_sats: okänd kod avvisas',
        format('returnerade %s', sats));
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Okänd lägeskod%' THEN
        PERFORM _xfail(15, 'hex_triggerlage_sats: okänd kod avvisas', 'korrekt blockerad');
    ELSE
        PERFORM _fail(15, 'hex_triggerlage_sats: okänd kod avvisas', SQLERRM);
    END IF;
END $$;

-- TEST 16: alla fyra lägeskoder översätts
DO $$ DECLARE
    fel text := '';
BEGIN
    IF public.hex_triggerlage_sats('O') <> 'ENABLE'         THEN fel := fel || 'O '; END IF;
    IF public.hex_triggerlage_sats('D') <> 'DISABLE'        THEN fel := fel || 'D '; END IF;
    IF public.hex_triggerlage_sats('R') <> 'ENABLE REPLICA' THEN fel := fel || 'R '; END IF;
    IF public.hex_triggerlage_sats('A') <> 'ENABLE ALWAYS'  THEN fel := fel || 'A '; END IF;

    IF fel = '' THEN
        PERFORM _pass(16, 'hex_triggerlage_sats: O/D/R/A översätts');
    ELSE
        PERFORM _fail(16, 'hex_triggerlage_sats: O/D/R/A översätts', 'fel för: ' || fel);
    END IF;
END $$;

-- =============================================================================
-- GRUPP 4: REGRESSIONSVAKT FÖR ÅTERLÄSNING
--
-- pg_dump och pg_restore kör varje sats med search_path = ''. Geometrikedjan
-- når INSERT via både CHECK-villkoret validera_geom_<tabell> och triggern
-- hex_kontrollera_geom, och båda leder till PostGIS-anrop. Utan låst
-- search_path i funktionerna hittas inte ST_IsValid, COPY-steget havererar –
-- och pg_restore avslutar ändå med kod 0. Tabellen finns då men är tom.
-- =============================================================================

-- TEST 17: geometrifunktionerna har låst search_path
DO $$ DECLARE
    saknar text;
BEGIN
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO   saknar
    FROM   pg_proc      p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('hex_validera_geometri', 'hex_forklara_geometrifel',
                         'hex_kontrollera_geometri_trigger')
      AND  (p.proconfig IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search\_path=%'
            ));

    IF saknar IS NULL THEN
        PERFORM _pass(17, 'geometrikedjan: search_path låst');
    ELSE
        PERFORM _fail(17, 'geometrikedjan: search_path låst', 'saknar: ' || saknar);
    END IF;
END $$;

-- TEST 18: INSERT med tom search_path går igenom
-- Simulerar exakt vad pg_restore gör vid COPY-steget.
DO $$ DECLARE
    fore  integer;
    efter integer;
BEGIN
    SELECT count(*) INTO fore FROM sk0_kba_paus.stigar_l;

    SET LOCAL search_path = '';
    INSERT INTO sk0_kba_paus.stigar_l (namn, geom)
    VALUES ('restore_sim', public.ST_GeomFromText('LINESTRING(0 0,9 9)', 3006));
    RESET search_path;

    SELECT count(*) INTO efter FROM sk0_kba_paus.stigar_l;

    IF efter = fore + 1 THEN
        PERFORM _pass(18, 'geometrikedjan: INSERT med tom search_path');
    ELSE
        PERFORM _fail(18, 'geometrikedjan: INSERT med tom search_path',
            format('%s rader före, %s efter', fore, efter));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(18, 'geometrikedjan: INSERT med tom search_path', SQLERRM);
END $$;

-- =============================================================================
-- TEARDOWN
-- =============================================================================

DROP SCHEMA IF EXISTS sk0_kba_paus CASCADE;
DROP SCHEMA IF EXISTS sk0_kba_pausroll CASCADE;

DELETE FROM public.hex_metadata WHERE parent_schema IN ('sk0_kba_paus', 'sk0_kba_pausroll');

-- Explicit rollstädning ifall ta_bort_schemaroller_trigger inte hann köra
DROP ROLE IF EXISTS r_sk0_kba_paus;
DROP ROLE IF EXISTS w_sk0_kba_paus;
DROP ROLE IF EXISTS gs_r_sk0_kba_paus;
DROP ROLE IF EXISTS gs_w_sk0_kba_paus;
DROP ROLE IF EXISTS r_sk0_kba_pausroll;
DROP ROLE IF EXISTS w_sk0_kba_pausroll;
DROP ROLE IF EXISTS gs_r_sk0_kba_pausroll;
DROP ROLE IF EXISTS gs_w_sk0_kba_pausroll;

DELETE FROM public.hex_rolluppgifter WHERE rollnamn LIKE '%\_sk0\_kba\_paus%';

-- Sviten får aldrig lämna databasen pausad.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.hex_paus) THEN
        PERFORM count(*) FROM public.hex_ateruppta(false);
        RAISE WARNING 'Testsviten lämnade en paus kvar – återupptagen i teardown';
    END IF;
END $$;

-- =============================================================================
-- RESULTAT
-- =============================================================================

SELECT
    nr,
    name,
    status,
    CASE WHEN note != '' THEN note ELSE '-' END AS note
FROM _test_results
ORDER BY nr;

SELECT
    count(*) FILTER (WHERE status = 'PASS')  AS passed,
    count(*) FILTER (WHERE status = 'FAIL')  AS failed,
    count(*) FILTER (WHERE status = 'XFAIL') AS xfailed
FROM _test_results;
