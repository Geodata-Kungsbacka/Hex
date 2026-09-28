/******************************************************************************
 * TESTSVIT FÖR hex_underhall()
 *
 * hex_underhall() är Hex reparations-/underhållsfunktion, körs automatiskt
 * av installeraren efter varje installation/uppgradering. Den är tänkt att
 * vara det en DBA alltid kan falla tillbaka på för att återställa en
 * Hex-installation till ett känt gott skick -- så den här svit fungerar
 * genom att medvetet skada ett schema (fel ägarskap, borttagna triggers,
 * trasigt rolltillstånd) och sedan verifiera att ett enda hex_underhall()-
 * anrop reparerar allt, även funktionellt (inte bara "triggerobjektet
 * finns" utan "triggern avvisar faktiskt felaktig indata igen").
 *
 * Testerna täcker:
 *   A. Ägarskapsöverföring: schema, tabell, historiktabell, sekvens, vy
 *      och funktion får alla ägarskapet överfört till ägarrollen.
 *   B. Återkoppling av rad-nivå-triggers, var och en verifierad funktionellt:
 *      hex_tvinga_gid, hex_tvinga_anvandarvarden, hex_kontrollera_geom,
 *      trg_<tabell>_qa (historik), hex_ta_bort_dummy.
 *   C. hex_dummy_geometrier-specialfall: en föråldrad post som pekar på en
 *      tabell som inte längre finns ska hoppas över, inte ge fel.
 *   D. Reparation av rollstruktur: en roll som saknas helt (Fall a), en
 *      r_/w_-roll som felaktigt står som LOGIN och ska tvingas tillbaka
 *      till NOLOGIN (Fall b), avvikande hex_geoserver_roller-
 *      medlemskap, samt avvikande arvs_fran-arv för ett GeoServer-
 *      tjänstekonto.
 *
 * Ett enda hex_underhall()-anrop används för att reparera allt på en gång
 * (motsvarar verklig felåterställning i praktiken), och sedan verifieras
 * varje område för sig.
 *
 * FÖRUTSÄTTNINGAR:
 *   - Hex måste vara installerat i måldatabasen (alla funktioner utrullade)
 *   - PostGIS-tillägget måste vara tillgängligt
 *   - Kör som en superanvändare eller Hex systemägare
 *
 * ANVÄNDNING:
 *   psql -d din_databas -f test_underhall.sql
 *
 * Testet städar upp efter sig med DROP SCHEMA ... CASCADE på slutet.
 * Testet är idempotent -- säkert att köra flera gånger.
 ******************************************************************************/

\echo '============================================================'
\echo 'HEX hex_underhall() TESTSVIT'
\echo '============================================================'

------------------------------------------------------------------------
-- FÖRBEREDELSE: en _kba_-tabell med geometri får hela Hex-behandlingen --
-- historiktabell, QA-trigger, audit-trigger, geometritrigger, gid-
-- trigger och en dummy-rad -- i en enda CREATE TABLE. En beroende vy
-- läggs också till, eftersom vyer är en normal del av ett Hex-schema och
-- ägarskapsöverföringen behöver nå dem också.
------------------------------------------------------------------------
\echo ''
\echo '--- Förberedelse ---'

SET client_min_messages = 'warning';

DROP SCHEMA IF EXISTS sk1_kba_underhalltest CASCADE;
DELETE FROM hex_dummy_geometrier WHERE schema_namn = 'sk1_kba_underhalltest';

CREATE SCHEMA sk1_kba_underhalltest;

CREATE TABLE sk1_kba_underhalltest.testobj_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

CREATE VIEW sk1_kba_underhalltest.v_testobj_y AS
    SELECT * FROM sk1_kba_underhalltest.testobj_y;

-- En föråldrad hex_dummy_geometrier-rad som pekar på en tabell som aldrig
-- skapades. hex_underhall()'s reparationsloop för dummy-triggern ska hoppa
-- över den tyst (se dess egen kommentar "hoppar over om tabellen inte
-- langre existerar") snarare än att ge fel.
INSERT INTO hex_dummy_geometrier (schema_namn, tabell_namn, gid)
VALUES ('sk1_kba_underhalltest', 'ghost_table_xyz', 999999);

RESET client_min_messages;

------------------------------------------------------------------------
-- SKADA: allt nedan görs i en enda omgång, för att efterlikna ett
-- verkligt "något är trasigt, kör underhåll"-scenario snarare än att
-- testa varje skada isolerat med ett eget reparationsanrop.
------------------------------------------------------------------------
\echo ''
\echo '--- Skadar schemat ---'

SET client_min_messages = 'warning';

-- A. Ägarskapsskada: simulerar objekt som skapats/rörts av en
-- superanvändarsession (t.ex. FME eller en DBA som ansluter direkt som postgres).
ALTER SCHEMA sk1_kba_underhalltest OWNER TO postgres;
ALTER TABLE sk1_kba_underhalltest.testobj_y OWNER TO postgres;
ALTER TABLE sk1_kba_underhalltest.testobj_y_h OWNER TO postgres;
ALTER SEQUENCE sk1_kba_underhalltest.testobj_y_gid_seq OWNER TO postgres;
ALTER VIEW sk1_kba_underhalltest.v_testobj_y OWNER TO postgres;
ALTER FUNCTION sk1_kba_underhalltest.trg_fn_testobj_y_qa() OWNER TO postgres;

-- B. Triggerskada: ta bort varje rad-nivå-trigger Hex kopplade vid CREATE TABLE.
DROP TRIGGER IF EXISTS hex_tvinga_gid          ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_tvinga_anvandarvarden ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_kontrollera_geom    ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS trg_testobj_y_qa        ON sk1_kba_underhalltest.testobj_y;
DROP TRIGGER IF EXISTS hex_ta_bort_dummy       ON sk1_kba_underhalltest.testobj_y;

-- D. Rollskada, spridd över de fyra rollerna så att varje scenario är isolerat:
--   r_    -- saknas helt (Fall a: DROP OWNED BY + DROP ROLE, som en roll
--            som tagits bort manuellt eller inte överlevt en återställning)
--   w_    -- föråldrad pre-4-rolls installation: var LOGIN, felaktigt i
--            hex_geoserver_roller (Fall b: exakt det scenario commit
--            95ead68 fixade)
--   gs_r_ -- hex_geoserver_roller-medlemskap återkallat (bryter
--            pg_hba.conf-matchning för GeoServers läskonto)
--   gs_w_ -- arvs_fran-arv trasigt (ärver inte längre från w_, så
--            skrivåtkomsten skulle tyst gå förlorad)
DROP OWNED BY r_sk1_kba_underhalltest;
DROP ROLE r_sk1_kba_underhalltest;

ALTER ROLE w_sk1_kba_underhalltest WITH LOGIN PASSWORD 'temp_pre_fix_password';
GRANT hex_geoserver_roller TO w_sk1_kba_underhalltest;

REVOKE hex_geoserver_roller FROM gs_r_sk1_kba_underhalltest;

REVOKE w_sk1_kba_underhalltest FROM gs_w_sk1_kba_underhalltest;

RESET client_min_messages;

------------------------------------------------------------------------
-- REPARATION: ett hex_underhall()-anrop fixar allt ovanstående.
------------------------------------------------------------------------
\echo ''
\echo '--- Kör hex_underhall() ---'

SET client_min_messages = 'warning';
SELECT count(*) AS reparationsatgarder FROM hex_underhall();
RESET client_min_messages;

------------------------------------------------------------------------
-- A: Ägarskapsöverföring
------------------------------------------------------------------------
\echo ''
\echo '--- A: Ägarskapsöverföring ---'

DO $$
DECLARE
    fel_agare text[];
BEGIN
    SELECT array_agg(relname) INTO fel_agare
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname = 'sk1_kba_underhalltest'
      AND c.relkind IN ('r', 'v', 'S')
      AND r.rolname <> public.hex_systemagare();

    IF fel_agare IS NULL THEN
        RAISE NOTICE 'TEST A1 PASSED: alla tabeller/vyer/sekvenser ägs av %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST A1 FAILED: fortfarande felaktigt ägda: %', array_to_string(fel_agare, ', ');
    END IF;
END $$;

DO $$
DECLARE
    schema_agare text;
    fn_agare text;
BEGIN
    SELECT r.rolname INTO schema_agare
    FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
    WHERE n.nspname = 'sk1_kba_underhalltest';

    SELECT r.rolname INTO fn_agare
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles r ON r.oid = p.proowner
    WHERE n.nspname = 'sk1_kba_underhalltest' AND p.proname = 'trg_fn_testobj_y_qa';

    IF schema_agare = public.hex_systemagare() AND fn_agare = public.hex_systemagare() THEN
        RAISE NOTICE 'TEST A2 PASSED: schema och QA-triggerfunktion ägs av %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST A2 FAILED: schema_agare=%, fn_agare=% (båda ska vara %)',
            schema_agare, fn_agare, public.hex_systemagare();
    END IF;
END $$;

------------------------------------------------------------------------
-- B: Återkoppling av rad-nivå-triggers, verifierat funktionellt
------------------------------------------------------------------------
\echo ''
\echo '--- B: Triggeråterkoppling ---'

-- B1: hex_tvinga_gid -- klientangivet gid via OVERRIDING SYSTEM VALUE ska
-- fortfarande tyst ersättas med sekvensens nästa värde.
DO $$
DECLARE
    fatt_gid integer;
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (gid, beskrivning, geom)
        OVERRIDING SYSTEM VALUE
        VALUES (999999, 'test-b1-gid', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007))
        RETURNING gid INTO fatt_gid;

    IF fatt_gid IS DISTINCT FROM 999999 THEN
        RAISE NOTICE 'TEST B1 PASSED: hex_tvinga_gid återkopplad, klientens gid 999999 åsidosattes till %', fatt_gid;
    ELSE
        RAISE WARNING 'TEST B1 FAILED: klientangivet gid 999999 accepterades -- hex_tvinga_gid saknas';
    END IF;
END $$;

-- B2: hex_tvinga_anvandarvarden -- klientangivet skapad_av ska fortfarande
-- tyst åsidosättas med sessionsanvändaren.
DO $$
DECLARE
    fatt_skapad_av text;
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (beskrivning, skapad_av, geom)
        VALUES ('test-b2-audit', 'fake_user', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007))
        RETURNING skapad_av INTO fatt_skapad_av;

    IF fatt_skapad_av IS DISTINCT FROM 'fake_user' THEN
        RAISE NOTICE 'TEST B2 PASSED: hex_tvinga_anvandarvarden återkopplad, skapad_av åsidosattes till %', fatt_skapad_av;
    ELSE
        RAISE WARNING 'TEST B2 FAILED: klientangivet skapad_av ''fake_user'' accepterades -- hex_tvinga_anvandarvarden saknas';
    END IF;
END $$;

-- B3: hex_kontrollera_geom -- en ogiltig (självkorsande) geometri ska
-- fortfarande avvisas med Hex eget meddelande, inte bara PostgreSQLs
-- generiska CHECK-brott (bevisar att TRIGGERN avfyrades, inte bara CHECK:en).
DO $$
BEGIN
    INSERT INTO sk1_kba_underhalltest.testobj_y (beskrivning, geom)
        VALUES ('test-b3-geom', ST_GeomFromText('POLYGON((0 0,10 10,10 0,0 10,0 0))', 3007));
    RAISE WARNING 'TEST B3 FAILED: självkorsande geometri accepterades';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri i tabellen%' THEN
            RAISE NOTICE 'TEST B3 PASSED: hex_kontrollera_geom återkopplad, avvisad med Hex-meddelande';
        ELSE
            RAISE WARNING 'TEST B3 PARTIAL: geometri avvisad, men inte av hex_kontrollera_geom (fick: %)', SQLERRM;
        END IF;
END $$;

-- B4: trg_testobj_y_qa -- en UPDATE ska fortfarande skriva en historikrad.
DO $$
DECLARE
    historikrader_fore integer;
    historikrader_efter integer;
BEGIN
    SELECT count(*) INTO historikrader_fore FROM sk1_kba_underhalltest.testobj_y_h;

    UPDATE sk1_kba_underhalltest.testobj_y SET beskrivning = 'test-b4-uppdaterad' WHERE beskrivning = 'test-b1-gid';

    SELECT count(*) INTO historikrader_efter FROM sk1_kba_underhalltest.testobj_y_h;

    IF historikrader_efter > historikrader_fore THEN
        RAISE NOTICE 'TEST B4 PASSED: trg_testobj_y_qa återkopplad, UPDATE skrev en historikrad (% -> %)',
            historikrader_fore, historikrader_efter;
    ELSE
        RAISE WARNING 'TEST B4 FAILED: UPDATE skrev ingen historikrad -- trg_testobj_y_qa saknas';
    END IF;
END $$;

-- B5: hex_ta_bort_dummy -- den ursprungliga dummy-raden (registrerad vid
-- CREATE TABLE) ska fortfarande tas bort automatiskt av första riktiga
-- INSERT. Alla insättningar i B1/B2/B3 ovan var "riktiga" rader, så vid
-- det här laget bör dummyn redan vara borta.
DO $$
DECLARE
    dummy_borta boolean;
BEGIN
    SELECT NOT EXISTS (
        SELECT 1 FROM hex_dummy_geometrier
        WHERE schema_namn = 'sk1_kba_underhalltest' AND tabell_namn = 'testobj_y'
    ) INTO dummy_borta;

    IF dummy_borta THEN
        RAISE NOTICE 'TEST B5 PASSED: hex_ta_bort_dummy återkopplad, dummy-raden städades bort vid första riktiga INSERT';
    ELSE
        RAISE WARNING 'TEST B5 FAILED: dummy-raden är fortfarande registrerad efter riktiga insättningar -- hex_ta_bort_dummy saknas';
    END IF;
END $$;

------------------------------------------------------------------------
-- C: hex_dummy_geometrier-specialfall -- föråldrad post för obefintlig tabell
------------------------------------------------------------------------
\echo ''
\echo '--- C: Föråldrad dummy-geometripost ---'

DO $$
DECLARE
    finns_kvar boolean;
BEGIN
    -- Att vi över huvud taget kommit hit (förbi hex_underhall() ovan) utan
    -- ett ohanterat undantag bevisar redan att den föråldrade posten inte
    -- kraschade reparationskörningen. Bekräfta även att den bara lämnas ifred.
    SELECT EXISTS (
        SELECT 1 FROM hex_dummy_geometrier
        WHERE schema_namn = 'sk1_kba_underhalltest' AND tabell_namn = 'ghost_table_xyz'
    ) INTO finns_kvar;

    IF finns_kvar THEN
        RAISE NOTICE 'TEST C1 PASSED: föråldrad hex_dummy_geometrier-post för en obefintlig tabell hoppades över utan fel';
    ELSE
        RAISE WARNING 'TEST C1 NOTE: den föråldrade posten togs bort i stället för att hoppas över (inte nödvändigtvis fel, bara oväntat)';
    END IF;
END $$;

------------------------------------------------------------------------
-- D: Reparation av rollstruktur
------------------------------------------------------------------------
\echo ''
\echo '--- D: Reparation av rollstruktur ---'

-- D1 (Fall a): r_ togs bort helt med DROP ROLE -- ska återskapas som
-- NOLOGIN med schemarättigheter och ADMIN OPTION för ägarrollen.
DO $$
DECLARE
    r_finns boolean;
    r_login boolean;
    r_admin_option boolean;
    r_har_select boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_kba_underhalltest') INTO r_finns;

    IF NOT r_finns THEN
        RAISE WARNING 'TEST D1 FAILED: r_sk1_kba_underhalltest återskapades inte efter DROP ROLE';
        RETURN;
    END IF;

    SELECT rolcanlogin INTO r_login FROM pg_roles WHERE rolname = 'r_sk1_kba_underhalltest';
    SELECT has_table_privilege('r_sk1_kba_underhalltest', 'sk1_kba_underhalltest.testobj_y', 'SELECT') INTO r_har_select;
    SELECT am.admin_option INTO r_admin_option
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'r_sk1_kba_underhalltest' AND mem.rolname = public.hex_systemagare();

    IF r_login IS DISTINCT FROM true AND r_har_select AND r_admin_option THEN
        RAISE NOTICE 'TEST D1 PASSED: r_ återskapad som NOLOGIN med SELECT-rättigheter och ADMIN OPTION för %', public.hex_systemagare();
    ELSE
        RAISE WARNING 'TEST D1 FAILED: r_login=%, r_har_select=%, r_admin_option=%', r_login, r_har_select, r_admin_option;
    END IF;
END $$;

-- D2 (Fall b): w_ står som LOGIN och ligger felaktigt i hex_geoserver_roller
-- -- ska tvingas tillbaka till NOLOGIN och tas bort ur hex_geoserver_roller.
-- Invarianten gäller oavsett hur värdet blev fel (jfr buggen 95ead68 stängde).
DO $$
DECLARE
    w_login boolean;
    w_i_geoserver_roller boolean;
BEGIN
    SELECT rolcanlogin INTO w_login FROM pg_roles WHERE rolname = 'w_sk1_kba_underhalltest';
    SELECT pg_has_role('w_sk1_kba_underhalltest', 'hex_geoserver_roller', 'member') INTO w_i_geoserver_roller;

    IF w_login IS DISTINCT FROM true AND NOT w_i_geoserver_roller THEN
        RAISE NOTICE 'TEST D2 PASSED: w_ tvingad tillbaka till NOLOGIN och borttagen ur hex_geoserver_roller';
    ELSE
        RAISE WARNING 'TEST D2 FAILED: w_login=%, w_i_geoserver_roller=% (förväntade false, false)', w_login, w_i_geoserver_roller;
    END IF;
END $$;

-- D3: gs_r_ hade fått hex_geoserver_roller-medlemskapet återkallat -- ska
-- återställas (detta är det som gör att pg_hba.conf-matchning fungerar
-- för GeoServer-kontot).
DO $$
DECLARE
    gsr_i_geoserver_roller boolean;
BEGIN
    SELECT pg_has_role('gs_r_sk1_kba_underhalltest', 'hex_geoserver_roller', 'member') INTO gsr_i_geoserver_roller;

    IF gsr_i_geoserver_roller THEN
        RAISE NOTICE 'TEST D3 PASSED: gs_r_ medlemskap i hex_geoserver_roller återställt';
    ELSE
        RAISE WARNING 'TEST D3 FAILED: gs_r_ är inte medlem i hex_geoserver_roller';
    END IF;
END $$;

-- D4: gs_w_ hade fått sitt arvs_fran-arv från w_ trasigt -- ska återställas.
DO $$
DECLARE
    gsw_arver_w boolean;
BEGIN
    SELECT pg_has_role('gs_w_sk1_kba_underhalltest', 'w_sk1_kba_underhalltest', 'member') INTO gsw_arver_w;

    IF gsw_arver_w THEN
        RAISE NOTICE 'TEST D4 PASSED: gs_w_ arv från w_ (arvs_fran) återställt';
    ELSE
        RAISE WARNING 'TEST D4 FAILED: gs_w_ ärver inte från w_';
    END IF;
END $$;

------------------------------------------------------------------------
-- Städning
------------------------------------------------------------------------
\echo ''
\echo '--- Städning ---'

SET client_min_messages = 'warning';
DROP SCHEMA sk1_kba_underhalltest CASCADE;
DELETE FROM hex_dummy_geometrier WHERE schema_namn = 'sk1_kba_underhalltest';
RESET client_min_messages;

\echo ''
\echo '============================================================'
\echo 'hex_underhall()-tester klara.'
\echo '============================================================'
