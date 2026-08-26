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
-- GRUPP 5: TOMMA OCH OVANLIGA KONFIGURATIONER
-- =============================================================================

-- TEST 19: tom hex_standardiserade_skyddsnivaer stoppar pausen i stället för
-- att tyst hoppa över radtriggarna.
--
-- hex_schema_regex() ger NULL när tabellen är tom, och "nspname ~ NULL" matchar
-- ingenting. Utan kontrollen rapporterar hex_pausa() bara sina event-triggers
-- och lämnar varenda radtrigger påslagen under återläsningen.
--
-- Den inre BEGIN/EXCEPTION-blocket är en subtransaktion: när RAISE i slutet
-- propagerar rullas DELETE tillbaka och skyddsnivåerna är intakta igen.
-- PL/pgSQL-variabler är inte transaktionella, så resultatet överlever.
DO $$ DECLARE
    resultat  text;
    ev_kvar   integer;
BEGIN
    BEGIN
        DELETE FROM public.hex_standardiserade_skyddsnivaer;

        BEGIN
            PERFORM count(*) FROM public.hex_pausa('testsvit 19');
            resultat := 'pausen gick igenom trots NULL-regex';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM LIKE '%gav NULL%' THEN
                resultat := 'OK';
            ELSE
                resultat := SQLERRM;
            END IF;
        END;

        -- Samma subtransaktion ska ha rullat tillbaka hex_pausa:s
        -- ALTER EVENT TRIGGER-satser.
        SELECT count(*) INTO ev_kvar
        FROM   pg_event_trigger et
        JOIN   pg_proc          p ON p.oid = et.evtfoid
        JOIN   pg_namespace     n ON n.oid = p.pronamespace
        WHERE  n.nspname = 'public'
          AND  p.proname LIKE 'hex\_%'
          AND  et.evtenabled = 'D';

        RAISE EXCEPTION 'ROLLBACK_MARKER';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'ROLLBACK_MARKER' THEN
            resultat := coalesce(resultat, SQLERRM);
        END IF;
    END;

    IF resultat = 'OK' AND coalesce(ev_kvar, -1) = 0 THEN
        PERFORM _xfail(19, 'hex_pausa: tom skyddsnivåtabell blockerar pausen',
            'fel kastat, event-triggers återställda');
    ELSE
        PERFORM _fail(19, 'hex_pausa: tom skyddsnivåtabell blockerar pausen',
            format('resultat=%s avstängda_kvar=%s', resultat, coalesce(ev_kvar::text, 'NULL')));
    END IF;
END $$;

-- TEST 20: skyddsnivåerna är oskadda efter test 19
-- Vakt mot att subtransaktionsmönstret ovan slutar rulla tillbaka.
DO $$ DECLARE
    antal integer;
BEGIN
    SELECT count(*) INTO antal FROM public.hex_standardiserade_skyddsnivaer;

    IF antal > 0 AND public.hex_schema_regex() IS NOT NULL THEN
        PERFORM _pass(20, 'testsvit: skyddsnivåerna återställda efter test 19',
            format('%s prefix', antal));
    ELSE
        PERFORM _fail(20, 'testsvit: skyddsnivåerna återställda efter test 19',
            format('%s rader kvar – sviten har skadat konfigurationen', antal));
    END IF;
END $$;

-- TEST 21: hex_pausstatus skiljer "räknade till noll" från "kunde inte räkna"
DO $$ DECLARE
    rad_av    integer;
    avvikelse text;
    resultat  text;
BEGIN
    BEGIN
        DELETE FROM public.hex_standardiserade_skyddsnivaer;
        SELECT st.radtriggers_av, st.avvikelse
        INTO   rad_av, avvikelse
        FROM   public.hex_pausstatus() st;
        RAISE EXCEPTION 'ROLLBACK_MARKER';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'ROLLBACK_MARKER' THEN
            resultat := SQLERRM;
        END IF;
    END;

    IF resultat IS NOT NULL THEN
        PERFORM _fail(21, 'hex_pausstatus: NULL-regex ger NULL, inte noll', resultat);
    ELSIF rad_av IS NULL AND avvikelse LIKE '%gav NULL%' THEN
        PERFORM _pass(21, 'hex_pausstatus: NULL-regex ger NULL, inte noll');
    ELSE
        PERFORM _fail(21, 'hex_pausstatus: NULL-regex ger NULL, inte noll',
            format('radtriggers_av=%s avvikelse=%s',
                coalesce(rad_av::text, 'NULL'), coalesce(avvikelse, 'NULL')));
    END IF;
END $$;

-- TEST 22: hex_pausa täcker partitionerade tabeller och deras partitioner
--
-- Tabellerna skapas UNDER pausen med flit. hex_hantera_ny_tabell() bygger om
-- en partitionerad tabell till en vanlig ("matning is not partitioned" vid
-- nästa PARTITION OF), så partitioneringen överlever bara när event-triggarna
-- är avstängda. Sedan pausas igen för att se att bägge triggarna fångas.
DO $$ DECLARE
    antal integer;
BEGIN
    PERFORM count(*) FROM public.hex_pausa('testsvit 22 - uppsättning');

    CREATE TABLE sk0_kba_paus.matning (gid int, dag date) PARTITION BY RANGE (dag);
    CREATE TABLE sk0_kba_paus.matning_2026 PARTITION OF sk0_kba_paus.matning
        FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
    CREATE FUNCTION sk0_kba_paus.part_fn() RETURNS trigger
        AS $f$ BEGIN RETURN NEW; END $f$ LANGUAGE plpgsql;
    CREATE TRIGGER part_trg BEFORE INSERT ON sk0_kba_paus.matning
        FOR EACH ROW EXECUTE FUNCTION sk0_kba_paus.part_fn();

    -- Ur pausen igen. Triggarna skapades efter pausen och står som påslagna.
    PERFORM count(*) FROM public.hex_ateruppta(false);

    PERFORM count(*) FROM public.hex_pausa('testsvit 22');

    SELECT count(*) INTO antal
    FROM   pg_trigger   tg
    JOIN   pg_class     c ON c.oid = tg.tgrelid
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  NOT tg.tgisinternal
      AND  c.relname IN ('matning', 'matning_2026')
      AND  n.nspname = 'sk0_kba_paus'
      AND  tg.tgenabled = 'D';

    PERFORM count(*) FROM public.hex_ateruppta(false);

    IF antal = 2 THEN
        PERFORM _pass(22, 'hex_pausa: partitionerad tabell och partition');
    ELSE
        PERFORM _fail(22, 'hex_pausa: partitionerad tabell och partition',
            format('%s av 2 avstängda', antal));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(22, 'hex_pausa: partitionerad tabell och partition', SQLERRM);
END $$;

-- TEST 23: hex_pausa täcker triggers på främmande tabeller (relkind f)
--
-- Kräver postgres_fdw. Saknas modulen körs testet inte, och noten säger det –
-- relkind-filtret är då overifierat i den här miljön, inte trasigt.
-- CREATE SERVER OPTIONS tar bara literaler, därav EXECUTE format().
DO $$ DECLARE
    lage "char";
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'postgres_fdw') THEN
        PERFORM _pass(23, 'hex_pausa: främmande tabell (relkind f)',
            'EJ KÖRT - postgres_fdw saknas i den här miljön');
        RETURN;
    END IF;

    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
    EXECUTE format(
        'CREATE SERVER hex_paus_testsrv FOREIGN DATA WRAPPER postgres_fdw'
        ' OPTIONS (host %L, dbname %L)',
        'localhost', current_database()
    );
    CREATE FOREIGN TABLE sk0_kba_paus.extern (a int) SERVER hex_paus_testsrv;
    CREATE FUNCTION sk0_kba_paus.fdw_fn() RETURNS trigger
        AS $f$ BEGIN RETURN NEW; END $f$ LANGUAGE plpgsql;
    CREATE TRIGGER fdw_trg BEFORE INSERT ON sk0_kba_paus.extern
        FOR EACH ROW EXECUTE FUNCTION sk0_kba_paus.fdw_fn();

    PERFORM count(*) FROM public.hex_pausa('testsvit 23');

    SELECT tg.tgenabled INTO lage
    FROM   pg_trigger tg
    WHERE  tg.tgrelid = 'sk0_kba_paus.extern'::regclass
      AND  NOT tg.tgisinternal;

    PERFORM count(*) FROM public.hex_ateruppta(false);

    IF lage = 'D' THEN
        PERFORM _pass(23, 'hex_pausa: främmande tabell (relkind f)');
    ELSE
        PERFORM _fail(23, 'hex_pausa: främmande tabell (relkind f)',
            format('läge %s, väntade D', coalesce(lage::text, 'NULL')));
    END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM _fail(23, 'hex_pausa: främmande tabell (relkind f)', SQLERRM);
END $$;

-- TEST 24: hex_pausa är atomisk – ett ROLLBACK lämnar ingenting halvpausat
DO $$ DECLARE
    i_transaktionen integer;
    efter_rollback  integer;
    paus_rader      integer;
BEGIN
    BEGIN
        PERFORM count(*) FROM public.hex_pausa('testsvit 24');

        SELECT count(*) INTO i_transaktionen
        FROM pg_event_trigger et
        JOIN pg_proc      p ON p.oid = et.evtfoid
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname LIKE 'hex\_%'
          AND et.evtenabled = 'D';

        RAISE EXCEPTION 'ROLLBACK_MARKER';
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    SELECT count(*) INTO efter_rollback
    FROM pg_event_trigger et
    JOIN pg_proc      p ON p.oid = et.evtfoid
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'hex\_%'
      AND et.evtenabled = 'D';

    SELECT count(*) INTO paus_rader FROM public.hex_paus;

    IF i_transaktionen > 0 AND efter_rollback = 0 AND paus_rader = 0 THEN
        PERFORM _pass(24, 'hex_pausa: atomisk – ROLLBACK återställer allt',
            format('%s avstängda i transaktionen, 0 efter', i_transaktionen));
    ELSE
        PERFORM _fail(24, 'hex_pausa: atomisk – ROLLBACK återställer allt',
            format('i_transaktionen=%s efter=%s paus_rader=%s',
                i_transaktionen, efter_rollback, paus_rader));
    END IF;
END $$;

-- =============================================================================
-- TEARDOWN
-- =============================================================================

DROP SCHEMA IF EXISTS sk0_kba_paus CASCADE;
DROP SCHEMA IF EXISTS sk0_kba_pausroll CASCADE;
DROP SERVER IF EXISTS hex_paus_testsrv CASCADE;

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
-- FULLSTÄNDIGHETSVAKT
--
-- Ett DO-block som kastar ett ohanterat fel skriver ingen rad i _test_results
-- och försvinner tyst ur resultattabellen. Med ON_ERROR_STOP off går sviten
-- vidare och rapporterar "alla godkända" fast ett test aldrig kördes. Vakten
-- jämför mot den förväntade serien i stället.
-- =============================================================================

DO $$ DECLARE
    saknade text;
BEGIN
    SELECT string_agg(n::text, ', ' ORDER BY n)
    INTO   saknade
    FROM   generate_series(1, 24) n
    WHERE  n NOT IN (SELECT nr FROM _test_results);

    IF saknade IS NULL THEN
        PERFORM _pass(99, 'testsvit: alla 24 test registrerade ett resultat');
    ELSE
        PERFORM _fail(99, 'testsvit: alla 24 test registrerade ett resultat',
            'saknas: ' || saknade);
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
