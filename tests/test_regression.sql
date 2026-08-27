/******************************************************************************
 * REGRESSIONSTESTSVIT FÖR HEX-BUGGFIXAR
 *
 * Testerna täcker:
 *   1. Geometrivalidering tillämpad på _kba_-scheman
 *   2. Spatiala (GiST-)index skapas för geometritabeller
 *   3. Svenska tecken (åäö) i tabell-/schemanamn
 *   4. Schemavalideringens felmeddelanden, och att CREATE SCHEMA rullas
 *      tillbaka atomärt (schema + roller) trots att rollerna skapas innan
 *      namnet valideras (event-triggers körs i alfabetisk ordning)
 *   5. Tabeller utan geometri (regressionskontroll)
 *   6. DROP TABLE städar bort historiktabeller och triggerfunktioner
 *   7. Kolumnordningen är ren efter CREATE TABLE (inga luckor i ordinal)
 *   8. Standardkolumner läggs till korrekt
 *   9. DROP SCHEMA städar bort roller; ägarrollen har ADMIN OPTION på r_/w_
 *      så att den kan GRANT:a dem vidare utan superuser; hex_underhall()
 *      uppgraderar befintliga tilldelningar som föregår ADMIN OPTION-fixen
 *  10. Specialfall: _h-genväg, felaktiga suffix, namnkollisioner, CTAS,
 *      ADD COLUMN
 *  11. Beräknade kolumner (GENERATED ALWAYS AS ... STORED) överlever
 *      omstruktureringen – även funktionsbaserade uttryck och uttryck över
 *      geometrikolumnen – och typmodifierare (numeric(10,2), varchar(50))
 *      bevaras på både beräknade och vanliga kolumner
 *  12. Kolumntyper rekonstrueras med hex_kolumntyp() i hela kedjan:
 *      arraykolumner fungerar, historiktabellen speglar modertabellens typer
 *      exakt, och ADD COLUMN synkar rätt typ till historiken
 *
 * FÖRUTSÄTTNINGAR:
 *   - Hex måste vara installerat i måldatabasen (alla funktioner utplacerade)
 *   - PostGIS-tillägget måste vara tillgängligt
 *   - Kör som superuser eller Hex-systemägaren
 *
 * ANVÄNDNING:
 *   psql -d din_databas -f test_regression.sql
 *   Eller kör satserna i PgAdmins fråge-verktyg.
 *
 * Testet städar upp efter sig med DROP SCHEMA ... CASCADE på slutet.
 * Testet är idempotent - säkert att köra flera gånger.
 ******************************************************************************/

\echo '============================================================'
\echo 'HEX REGRESSIONSTESTSVIT'
\echo '============================================================'

------------------------------------------------------------------------
-- INLEDANDE STÄDNING (idempotent - säkert även om scheman inte finns)
------------------------------------------------------------------------
\echo ''
\echo '--- Inledande städning av tidigare testkörningar ---'
DROP SCHEMA IF EXISTS sk1_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_test CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_rolltest CASCADE;

------------------------------------------------------------------------
-- FÖRBEREDELSE: Skapa testscheman
------------------------------------------------------------------------
\echo ''
\echo '--- Skapar testscheman ---'
CREATE SCHEMA sk1_kba_test;
CREATE SCHEMA sk0_ext_test;

------------------------------------------------------------------------
-- TEST 1: Geometrivalidering tillämpas på _kba_-scheman
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 1: Geometrivalidering på _kba_-scheman ---'

-- Skapa en geometritabell i _kba_-schema
CREATE TABLE sk1_kba_test.test_validering_y (
    namn text,
    geom geometry(Polygon, 3007)
);

-- Verifiera att CHECK-villkoret finns
DO $$
DECLARE
    constraint_count integer;
BEGIN
    SELECT COUNT(*) INTO constraint_count
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'sk1_kba_test'
    AND c.conname LIKE 'validera_geom_%'
    AND c.contype = 'c';

    IF constraint_count > 0 THEN
        RAISE NOTICE 'TEST 1a PASSED: Geometrivalideringsvillkor hittat på _kba_-tabell';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: Inget geometrivalideringsvillkor på _kba_-tabell';
    END IF;
END $$;

-- Verifiera att ogiltig geometri blockeras (tom geometri).
-- hex_kontrollera_geom (en BEFORE INSERT-trigger) körs innan CHECK-villkoret
-- och avvisar den först med en enkel RAISE EXCEPTION (SQLSTATE P0001), så
-- detta fångas normalt som hex_kontrollera_geoms eget meddelande, inte som
-- check_violation (23514) -- CHECK-villkoret är ett andra försvarsled som
-- bara skulle utlösas om triggern på något sätt saknades.
DO $$
BEGIN
    INSERT INTO sk1_kba_test.test_validering_y (namn, geom)
    VALUES ('tom', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST 1b FAILED: Tom geometri accepterades (skulle blockerats)';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'TEST 1b PASSED: Tom geometri korrekt blockerad av CHECK-villkor';
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri%' THEN
            RAISE NOTICE 'TEST 1b PASSED: Tom geometri korrekt blockerad av hex_kontrollera_geom';
        ELSE
            RAISE WARNING 'TEST 1b FAILED: Tom geometri avvisad, men av ett oväntat fel: %', SQLERRM;
        END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk1_kba_test.test_validering_y;

------------------------------------------------------------------------
-- TEST 2: Spatiala (GiST-)index skapas
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 2: Skapande av spatialt GiST-index ---'

CREATE TABLE sk0_ext_test.test_index_y (
    data text,
    geom geometry(Polygon, 3007)
);

-- Verifiera att GiST-index finns
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'test_index_y'
    AND indexname = 'test_index_y_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 2a PASSED: GiST-index skapat på ext-schematabell';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: GiST-index INTE funnet på ext-schematabell';
    END IF;
END $$;

-- Verifiera även GiST-index på _kba_-schematabell
CREATE TABLE sk1_kba_test.test_index_p (
    data text,
    geom geometry(Point, 3007)
);

DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk1_kba_test'
    AND tablename = 'test_index_p'
    AND indexname = 'test_index_p_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 2b PASSED: GiST-index skapat på kba-schematabell';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: GiST-index INTE funnet på kba-schematabell';
    END IF;
END $$;

-- Verifiera att INGET villkor finns på ext-tabellen (endast _kba_ ska ha validering)
DO $$
DECLARE
    constraint_count integer;
BEGIN
    SELECT COUNT(*) INTO constraint_count
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'sk0_ext_test'
    AND c.conname LIKE 'validera_geom_%'
    AND c.contype = 'c';

    IF constraint_count = 0 THEN
        RAISE NOTICE 'TEST 2c PASSED: Ingen geometrivalidering på ext-schema (korrekt)';
    ELSE
        RAISE WARNING 'TEST 2c FAILED: Geometrivalidering oväntat på ext-schema';
    END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk0_ext_test.test_index_y;
DROP TABLE IF EXISTS sk1_kba_test.test_index_p;

------------------------------------------------------------------------
-- TEST 3: Svenska tecken (åäö) i tabellnamn
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 3: Stöd för svenska tecken ---'

-- Testa tabell med svenska tecken
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.rör_l (
        diameter integer,
        geom geometry(LineString, 3007)
    );
    RAISE NOTICE 'TEST 3a PASSED: Tabell med svenska tecken (rör_l) skapad korrekt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3a FAILED: Kunde inte skapa tabell med svenska tecken: %', SQLERRM;
END $$;

-- Verifiera att tabellen omstrukturerades (har gid-kolumn)
DO $$
DECLARE
    has_gid boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'rör_l'
        AND column_name = 'gid'
    ) INTO has_gid;

    IF has_gid THEN
        RAISE NOTICE 'TEST 3b PASSED: Tabell med svenska tecken har standard gid-kolumn';
    ELSE
        RAISE WARNING 'TEST 3b FAILED: Tabell med svenska tecken saknar gid-kolumn';
    END IF;
END $$;

-- Verifiera GiST-index på tabell med svenska tecken
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'rör_l'
    AND indexname = 'rör_l_geom_gidx';

    IF index_count > 0 THEN
        RAISE NOTICE 'TEST 3c PASSED: GiST-index skapat på tabell med svenska tecken';
    ELSE
        RAISE WARNING 'TEST 3c FAILED: GiST-index INTE funnet på tabell med svenska tecken';
    END IF;
END $$;

-- Testa fler tabellnamn med svenska tecken
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.vägar_l (
        bredd numeric,
        geom geometry(LineString, 3007)
    );
    RAISE NOTICE 'TEST 3d PASSED: Tabell vägar_l skapad korrekt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3d FAILED: Kunde inte skapa tabell vägar_l: %', SQLERRM;
END $$;

DO $$
BEGIN
    CREATE TABLE sk0_ext_test.åkrar_y (
        areal numeric,
        geom geometry(Polygon, 3007)
    );
    RAISE NOTICE 'TEST 3e PASSED: Tabell åkrar_y skapad korrekt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 3e FAILED: Kunde inte skapa tabell åkrar_y: %', SQLERRM;
END $$;

-- Städning
DROP TABLE IF EXISTS sk0_ext_test.rör_l;
DROP TABLE IF EXISTS sk0_ext_test.vägar_l;
DROP TABLE IF EXISTS sk0_ext_test.åkrar_y;

------------------------------------------------------------------------
-- TEST 4: Schemavalideringens felmeddelanden
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 4: Schemavalideringens felmeddelanden ---'

-- Testa att ogiltigt schemanamn avvisas med hjälpsamt meddelande
DO $$
BEGIN
    CREATE SCHEMA invalid_schema_name;
    RAISE WARNING 'TEST 4a FAILED: Ogiltigt schemanamn accepterades';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%hex_validera_schemanamn%' AND (SQLERRM LIKE '%sk0%' OR SQLERRM LIKE '%sk1%' OR SQLERRM LIKE '%sk2%') THEN
            RAISE NOTICE 'TEST 4a PASSED: Ogiltigt schema avvisat med hjälpsamt fel';
        ELSE
            RAISE WARNING 'TEST 4a PARTIAL: Schema avvisat men meddelandet oklart: %', SQLERRM;
        END IF;
END $$;

-- 4b: PostgreSQL kör Hex tre CREATE SCHEMA-event-triggers i alfabetisk
-- ordning efter triggernamn (hex_hantera_std_roller_trigger,
-- hex_notifiera_gs_trigger, hex_validera_schemanamn_trigger) -- så för det
-- ogiltiga namnet ovan hade r_/w_/gs_r_/gs_w_-rollerna redan skapats när
-- valideringen avvisade det. Bekräfta att hela transaktionen rullades
-- tillbaka tillsammans och inte lämnade några övergivna roller.
DO $$
DECLARE
    orphans text[];
BEGIN
    SELECT array_agg(rolname) INTO orphans
    FROM pg_roles
    WHERE rolname LIKE '%invalid_schema_name%';

    IF orphans IS NULL THEN
        RAISE NOTICE 'TEST 4b PASSED: Inga övergivna roller kvarstår efter återställning av ogiltigt schemanamn';
    ELSE
        RAISE WARNING 'TEST 4b FAILED: Övergivna roller kvarstod efter återställning: %', array_to_string(orphans, ', ');
    END IF;
END $$;

------------------------------------------------------------------------
-- TEST 5: Tabeller utan geometri fungerar fortfarande (ingen regression)
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 5: Tabeller utan geometri (regressionskontroll) ---'

DO $$
BEGIN
    CREATE TABLE sk0_ext_test.metadata (
        nyckel text,
        varde text
    );
    RAISE NOTICE 'TEST 5a PASSED: Tabell utan geometri skapad korrekt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 5a FAILED: Kunde inte skapa tabell utan geometri: %', SQLERRM;
END $$;

-- Verifiera att inget GiST-index finns på tabell utan geometri
DO $$
DECLARE
    index_count integer;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_test'
    AND tablename = 'metadata'
    AND indexdef LIKE '%GIST%';

    IF index_count = 0 THEN
        RAISE NOTICE 'TEST 5b PASSED: Inget GiST-index på tabell utan geometri (korrekt)';
    ELSE
        RAISE WARNING 'TEST 5b FAILED: Oväntat GiST-index på tabell utan geometri';
    END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk0_ext_test.metadata;

------------------------------------------------------------------------
-- TEST 6: DROP TABLE städar bort historiktabeller och triggerfunktioner
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 6: DROP TABLE-städning av historik ---'

-- Skapa en _kba_-tabell som får en historiktabell
CREATE TABLE sk1_kba_test.historiktest_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- Verifiera att historiktabellen skapades
DO $$
DECLARE
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'historiktest_y_h'
    ) INTO has_history;

    IF has_history THEN
        RAISE NOTICE 'TEST 6a PASSED: Historiktabell skapad för _kba_-tabell';
    ELSE
        RAISE WARNING 'TEST 6a FAILED: Ingen historiktabell skapad för _kba_-tabell';
    END IF;
END $$;

-- Verifiera att triggerfunktionen skapades
DO $$
DECLARE
    has_trigger_fn boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'sk1_kba_test'
        AND p.proname = 'trg_fn_historiktest_y_qa'
    ) INTO has_trigger_fn;

    IF has_trigger_fn THEN
        RAISE NOTICE 'TEST 6b PASSED: QA-triggerfunktion skapad för _kba_-tabell';
    ELSE
        RAISE WARNING 'TEST 6b FAILED: Ingen QA-triggerfunktion skapad för _kba_-tabell';
    END IF;
END $$;

-- Kör nu DROP på huvudtabellen - detta ska kaskadera till historik + triggerfunktion
DROP TABLE sk1_kba_test.historiktest_y;

-- Verifiera att historiktabellen togs bort
DO $$
DECLARE
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'historiktest_y_h'
    ) INTO has_history;

    IF NOT has_history THEN
        RAISE NOTICE 'TEST 6c PASSED: Historiktabell borttagen när huvudtabellen togs bort';
    ELSE
        RAISE WARNING 'TEST 6c FAILED: Historiktabell finns kvar efter att huvudtabellen togs bort';
    END IF;
END $$;

-- Verifiera att triggerfunktionen togs bort
DO $$
DECLARE
    has_trigger_fn boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'sk1_kba_test'
        AND p.proname = 'trg_fn_historiktest_y_qa'
    ) INTO has_trigger_fn;

    IF NOT has_trigger_fn THEN
        RAISE NOTICE 'TEST 6d PASSED: QA-triggerfunktion borttagen när huvudtabellen togs bort';
    ELSE
        RAISE WARNING 'TEST 6d FAILED: QA-triggerfunktion finns kvar efter att huvudtabellen togs bort';
    END IF;
END $$;

-- Testa att tabellomstrukturering fortfarande fungerar (DROP TABLE under
-- hex_byt_ut_tabell ska INTE kaskadera till historiken tack vare rekursionsspärren)
CREATE TABLE sk1_kba_test.omstrukt_test_y (
    data text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE
    has_gid boolean;
    has_history boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'omstrukt_test_y'
        AND column_name = 'gid'
    ) INTO has_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'omstrukt_test_y_h'
    ) INTO has_history;

    IF has_gid AND has_history THEN
        RAISE NOTICE 'TEST 6e PASSED: Tabellomstrukturering fungerar fortfarande med DROP TABLE-triggern aktiv';
    ELSIF NOT has_gid THEN
        RAISE WARNING 'TEST 6e FAILED: Tabellen omstrukturerades inte (saknar gid)';
    ELSE
        RAISE WARNING 'TEST 6e FAILED: Historiktabell skapades inte vid omstrukturering';
    END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk1_kba_test.omstrukt_test_y;

------------------------------------------------------------------------
-- TEST 7: Kolumnordningen är ren (inga luckor i ordinalposition)
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 7: Kolumnordning efter CREATE TABLE ---'

CREATE TABLE sk1_kba_test.kolumnordning_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- Om hex_hantera_ny_kolumn körs under CREATE TABLE tas kolumner bort och
-- läggs till igen, vilket ger luckor i ordinal_position (t.ex. 1,2,13,14,
-- 15,16,17). Med fixen ska max(ordinal_position) vara lika med count(*).
DO $$
DECLARE
    col_count integer;
    max_pos integer;
BEGIN
    SELECT COUNT(*), MAX(ordinal_position)
    INTO col_count, max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk1_kba_test'
    AND table_name = 'kolumnordning_y';

    IF col_count = max_pos THEN
        RAISE NOTICE 'TEST 7a PASSED: Kolumnpositioner är sekventiella (% kolumner, max position %)', col_count, max_pos;
    ELSE
        RAISE WARNING 'TEST 7a FAILED: Luckor i kolumnposition upptäckta (% kolumner men max position %)', col_count, max_pos;
    END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk1_kba_test.kolumnordning_y;

------------------------------------------------------------------------
-- TEST 8: Standardkolumner läggs till korrekt
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 8: Standardkolumner ---'

CREATE TABLE sk0_ext_test.standardkol_y (
    data text,
    geom geometry(Polygon, 3007)
);

-- Verifiera standardkolumner på _ext_-schema (endast gid + skapad_tidpunkt)
DO $$
DECLARE
    missing text[];
BEGIN
    SELECT array_agg(expected) INTO missing
    FROM unnest(ARRAY['gid', 'skapad_tidpunkt']) AS expected
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'standardkol_y'
        AND column_name = expected
    );

    IF missing IS NULL THEN
        RAISE NOTICE 'TEST 8a PASSED: Standardkolumner finns på ext-tabell (gid, skapad_tidpunkt)';
    ELSE
        RAISE WARNING 'TEST 8a FAILED: Standardkolumner saknas på ext-tabell: %', array_to_string(missing, ', ');
    END IF;
END $$;

-- Verifiera att _kba_-tabell får ALLA standardkolumner (gid + skapad_tidpunkt + skapad_av + andrad_tidpunkt + andrad_av)
CREATE TABLE sk1_kba_test.standardkol_kba_y (
    data text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE
    missing text[];
BEGIN
    SELECT array_agg(expected) INTO missing
    FROM unnest(ARRAY['gid', 'skapad_tidpunkt', 'skapad_av', 'andrad_tidpunkt', 'andrad_av']) AS expected
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_test'
        AND table_name = 'standardkol_kba_y'
        AND column_name = expected
    );

    IF missing IS NULL THEN
        RAISE NOTICE 'TEST 8b PASSED: Alla standardkolumner finns på kba-tabell';
    ELSE
        RAISE WARNING 'TEST 8b FAILED: Standardkolumner saknas på kba-tabell: %', array_to_string(missing, ', ');
    END IF;
END $$;

-- Verifiera att gid är första kolumnen
DO $$
DECLARE
    gid_pos integer;
BEGIN
    SELECT ordinal_position INTO gid_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y'
    AND column_name = 'gid';

    IF gid_pos = 1 THEN
        RAISE NOTICE 'TEST 8c PASSED: gid är första kolumnen (position 1)';
    ELSE
        RAISE WARNING 'TEST 8c FAILED: gid på position % (förväntade 1)', gid_pos;
    END IF;
END $$;

-- Verifiera att geom är sista kolumnen
DO $$
DECLARE
    geom_pos integer;
    max_pos integer;
BEGIN
    SELECT ordinal_position INTO geom_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'standardkol_y';

    IF geom_pos = max_pos THEN
        RAISE NOTICE 'TEST 8d PASSED: geom är sista kolumnen (position %)', geom_pos;
    ELSE
        RAISE WARNING 'TEST 8d FAILED: geom på position % men max är %', geom_pos, max_pos;
    END IF;
END $$;

-- Städning
DROP TABLE IF EXISTS sk0_ext_test.standardkol_y;
DROP TABLE IF EXISTS sk1_kba_test.standardkol_kba_y;

------------------------------------------------------------------------
-- TEST 9: Rollstruktur och DROP SCHEMA-rensning
--
-- Verifierar att alla fyra roller skapas korrekt vid CREATE SCHEMA:
--   r_*/w_*     NOLOGIN behörighetsgrupper (ej i hex_geoserver_roller)
--   gs_r_*/gs_w_* LOGIN tjänstekonton (i hex_geoserver_roller, i hex_rolluppgifter)
-- Verifierar att alla fyra roller och credentials rensas vid DROP SCHEMA.
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 9: Rollstruktur (4 roller per schema) och DROP SCHEMA-rensning ---'

DROP SCHEMA IF EXISTS sk2_ext_rolltest CASCADE;
CREATE SCHEMA sk2_ext_rolltest;

-- 9k: Schemat ska ägas av hex_systemagare(), inte av superuser som körde CREATE SCHEMA
DO $$
DECLARE
    schema_agare text;
    forvantad_agare text;
BEGIN
    SELECT rolname INTO schema_agare
    FROM pg_namespace n
    JOIN pg_roles r ON r.oid = n.nspowner
    WHERE n.nspname = 'sk2_ext_rolltest';

    forvantad_agare := public.hex_systemagare();

    IF schema_agare = forvantad_agare THEN
        RAISE NOTICE 'TEST 9k PASSED: Schema sk2_ext_rolltest ägs av % (hex_systemagare)', schema_agare;
    ELSE
        RAISE WARNING 'TEST 9k FAILED: Schema ägs av % – förväntade %', schema_agare, forvantad_agare;
    END IF;
END $$;

-- 9a: r_ och w_ ska vara NOLOGIN
DO $$
DECLARE
    r_login boolean;
    w_login boolean;
BEGIN
    SELECT rolcanlogin INTO r_login FROM pg_roles WHERE rolname = 'r_sk2_ext_rolltest';
    SELECT rolcanlogin INTO w_login FROM pg_roles WHERE rolname = 'w_sk2_ext_rolltest';

    IF r_login IS DISTINCT FROM true AND w_login IS DISTINCT FROM true THEN
        RAISE NOTICE 'TEST 9a PASSED: r_ och w_ skapade som NOLOGIN';
    ELSE
        RAISE WARNING 'TEST 9a FAILED: r_login=%, w_login=% (båda ska vara false/NULL)', r_login, w_login;
    END IF;
END $$;

-- 9b: gs_r_ och gs_w_ ska vara LOGIN
DO $$
DECLARE
    gsr_login boolean;
    gsw_login boolean;
BEGIN
    SELECT rolcanlogin INTO gsr_login FROM pg_roles WHERE rolname = 'gs_r_sk2_ext_rolltest';
    SELECT rolcanlogin INTO gsw_login FROM pg_roles WHERE rolname = 'gs_w_sk2_ext_rolltest';

    IF gsr_login = true AND gsw_login = true THEN
        RAISE NOTICE 'TEST 9b PASSED: gs_r_ och gs_w_ skapade som LOGIN';
    ELSE
        RAISE WARNING 'TEST 9b FAILED: gs_r_login=%, gs_w_login=% (båda ska vara true)', gsr_login, gsw_login;
    END IF;
END $$;

-- 9c: r_ och w_ ska INTE vara i hex_geoserver_roller
DO $$
DECLARE
    r_in_grp boolean;
    w_in_grp boolean;
BEGIN
    SELECT pg_has_role('r_sk2_ext_rolltest', 'hex_geoserver_roller', 'member') INTO r_in_grp;
    SELECT pg_has_role('w_sk2_ext_rolltest', 'hex_geoserver_roller', 'member') INTO w_in_grp;

    IF NOT r_in_grp AND NOT w_in_grp THEN
        RAISE NOTICE 'TEST 9c PASSED: r_ och w_ är INTE i hex_geoserver_roller';
    ELSE
        RAISE WARNING 'TEST 9c FAILED: r_in_grp=%, w_in_grp=% (båda ska vara false)', r_in_grp, w_in_grp;
    END IF;
END $$;

-- 9d: gs_r_ och gs_w_ ska vara i hex_geoserver_roller
DO $$
DECLARE
    gsr_in_grp boolean;
    gsw_in_grp boolean;
BEGIN
    SELECT pg_has_role('gs_r_sk2_ext_rolltest', 'hex_geoserver_roller', 'member') INTO gsr_in_grp;
    SELECT pg_has_role('gs_w_sk2_ext_rolltest', 'hex_geoserver_roller', 'member') INTO gsw_in_grp;

    IF gsr_in_grp AND gsw_in_grp THEN
        RAISE NOTICE 'TEST 9d PASSED: gs_r_ och gs_w_ är i hex_geoserver_roller';
    ELSE
        RAISE WARNING 'TEST 9d FAILED: gsr_in_grp=%, gsw_in_grp=% (båda ska vara true)', gsr_in_grp, gsw_in_grp;
    END IF;
END $$;

-- 9e: gs_r_ och gs_w_ ska ha uppgifter i hex_rolluppgifter (kan_logga_in=true)
DO $$
DECLARE
    gsr_creds boolean;
    gsw_creds boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM public.hex_rolluppgifter WHERE rollnamn='gs_r_sk2_ext_rolltest' AND kan_logga_in=true AND losenord IS NOT NULL) INTO gsr_creds;
    SELECT EXISTS(SELECT 1 FROM public.hex_rolluppgifter WHERE rollnamn='gs_w_sk2_ext_rolltest' AND kan_logga_in=true AND losenord IS NOT NULL) INTO gsw_creds;

    IF gsr_creds AND gsw_creds THEN
        RAISE NOTICE 'TEST 9e PASSED: gs_r_ och gs_w_ har lösenord i hex_rolluppgifter';
    ELSE
        RAISE WARNING 'TEST 9e FAILED: gsr_creds=%, gsw_creds=%', gsr_creds, gsw_creds;
    END IF;
END $$;

-- 9f: r_ och w_ ska finnas i hex_rolluppgifter med kan_logga_in=false
DO $$
DECLARE
    r_entry boolean;
    w_entry boolean;
BEGIN
    SELECT EXISTS(SELECT 1 FROM public.hex_rolluppgifter WHERE rollnamn='r_sk2_ext_rolltest' AND kan_logga_in=false AND losenord IS NULL) INTO r_entry;
    SELECT EXISTS(SELECT 1 FROM public.hex_rolluppgifter WHERE rollnamn='w_sk2_ext_rolltest' AND kan_logga_in=false AND losenord IS NULL) INTO w_entry;

    IF r_entry AND w_entry THEN
        RAISE NOTICE 'TEST 9f PASSED: r_ och w_ registrerade i hex_rolluppgifter (NOLOGIN)';
    ELSE
        RAISE WARNING 'TEST 9f FAILED: r_entry=%, w_entry=%', r_entry, w_entry;
    END IF;
END $$;

-- 9g: gs_r_ ska ärva behörigheter från r_ (transitiv membership)
DO $$
DECLARE
    inherits boolean;
BEGIN
    SELECT pg_has_role('gs_r_sk2_ext_rolltest', 'r_sk2_ext_rolltest', 'member') INTO inherits;

    IF inherits THEN
        RAISE NOTICE 'TEST 9g PASSED: gs_r_ ärver från r_ via gruppmedlemskap';
    ELSE
        RAISE WARNING 'TEST 9g FAILED: gs_r_ är inte medlem i r_';
    END IF;
END $$;

-- 9h: AD-användare som tilldelas r_ ska INTE hamna i hex_geoserver_roller
--     (simuleras: skapa en testroll, tilldela r_, kontrollera transitivitet)
DO $$
DECLARE
    in_geoserver_roller boolean;
BEGIN
    CREATE ROLE hex_test_ad_user_tmp WITH NOLOGIN;
    GRANT r_sk2_ext_rolltest TO hex_test_ad_user_tmp;
    SELECT pg_has_role('hex_test_ad_user_tmp', 'hex_geoserver_roller', 'member') INTO in_geoserver_roller;
    REVOKE r_sk2_ext_rolltest FROM hex_test_ad_user_tmp;
    DROP ROLE hex_test_ad_user_tmp;

    IF NOT in_geoserver_roller THEN
        RAISE NOTICE 'TEST 9h PASSED: AD-användare med r_-tilldelning hamnar INTE i hex_geoserver_roller';
    ELSE
        RAISE WARNING 'TEST 9h FAILED: AD-användare transitiv i hex_geoserver_roller via r_ – pg_hba.conf-problemet kvarstår!';
    END IF;
END $$;

-- 9l: hex_systemagare() (ägarrollen, t.ex. gis_admin) ska ha ADMIN OPTION på
-- r_ och w_ -- annars kan den inte GRANT:a rollerna vidare till AD-användare
-- utan en superuser (PostgreSQL 16+ kräver ADMIN OPTION, inte bara CREATEROLE).
DO $$
DECLARE
    r_admin boolean;
    w_admin boolean;
BEGIN
    SELECT am.admin_option INTO r_admin
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'r_sk2_ext_rolltest' AND mem.rolname = public.hex_systemagare();

    SELECT am.admin_option INTO w_admin
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'w_sk2_ext_rolltest' AND mem.rolname = public.hex_systemagare();

    IF r_admin AND w_admin THEN
        RAISE NOTICE 'TEST 9l PASSED: hex_systemagare() har ADMIN OPTION på r_ och w_';
    ELSE
        RAISE WARNING 'TEST 9l FAILED: r_admin=%, w_admin=% (båda ska vara true)', r_admin, w_admin;
    END IF;
END $$;

-- 9m: Beteendemässigt bevis för 9l -- SET ROLE till hex_systemagare() och
-- faktiskt GRANT:a r_ vidare till en engångsroll, helt utan superuser.
DO $$
DECLARE
    agare text := public.hex_systemagare();
    ok boolean := false;
BEGIN
    DROP ROLE IF EXISTS hex_test_ad_user_tmp2;
    CREATE ROLE hex_test_ad_user_tmp2 WITH NOLOGIN;

    BEGIN
        EXECUTE format('SET ROLE %I', agare);
        EXECUTE format('GRANT r_sk2_ext_rolltest TO %I', 'hex_test_ad_user_tmp2');
        ok := true;
    EXCEPTION WHEN OTHERS THEN
        ok := false;
    END;
    RESET ROLE;

    -- DROP ROLE ensamt räcker för att städa bort medlemskapet; en explicit
    -- REVOKE här skulle köras som fel grantor (GRANT ovan gjordes "av"
    -- agare, inte av sessionens egen roll) och bara ge en missvisande WARNING.
    DROP ROLE hex_test_ad_user_tmp2;

    IF ok THEN
        RAISE NOTICE 'TEST 9m PASSED: % kan GRANT:a r_ vidare utan superuser (ADMIN OPTION verifierad end-to-end)', agare;
    ELSE
        RAISE WARNING 'TEST 9m FAILED: % kunde INTE GRANT:a r_ vidare — saknar ADMIN OPTION', agare;
    END IF;
END $$;

-- DROP SCHEMA – alla fyra roller och credentials ska rensas
DROP SCHEMA sk2_ext_rolltest CASCADE;

-- 9i: Alla fyra roller borttagna
DO $$
DECLARE
    remaining text[];
BEGIN
    SELECT array_agg(rolname) INTO remaining
    FROM pg_roles
    WHERE rolname IN ('r_sk2_ext_rolltest','w_sk2_ext_rolltest',
                      'gs_r_sk2_ext_rolltest','gs_w_sk2_ext_rolltest');

    IF remaining IS NULL THEN
        RAISE NOTICE 'TEST 9i PASSED: Alla fyra roller borttagna efter DROP SCHEMA';
    ELSE
        RAISE WARNING 'TEST 9i FAILED: Följande roller finns kvar: %', array_to_string(remaining, ', ');
    END IF;
END $$;

-- 9j: Alla credentials borttagna
DO $$
DECLARE
    remaining text[];
BEGIN
    SELECT array_agg(rollnamn) INTO remaining
    FROM public.hex_rolluppgifter
    WHERE rollnamn IN ('r_sk2_ext_rolltest','w_sk2_ext_rolltest',
                       'gs_r_sk2_ext_rolltest','gs_w_sk2_ext_rolltest');

    IF remaining IS NULL THEN
        RAISE NOTICE 'TEST 9j PASSED: Alla hex_rolluppgifter-poster borttagna efter DROP SCHEMA';
    ELSE
        RAISE WARNING 'TEST 9j FAILED: Följande poster finns kvar i hex_rolluppgifter: %', array_to_string(remaining, ', ');
    END IF;
END $$;

-- 9n: hex_underhall() ska uppgradera ett befintligt r_/w_-medlemskap till
-- WITH ADMIN OPTION om det saknas (t.ex. ett schema skapat av en äldre
-- Hex-version, innan ADMIN OPTION lades till). Körs efter varje
-- install/uppgradering, så detta är vägen för att fixa befintliga scheman.
DO $$
DECLARE
    agare text := public.hex_systemagare();
    admin_before boolean;
    admin_after boolean;
BEGIN
    DROP SCHEMA IF EXISTS sk2_ext_underhalltest CASCADE;
    CREATE SCHEMA sk2_ext_underhalltest;

    -- Simulera en pre-fix installation: samma medlemskap men UTAN ADMIN OPTION.
    EXECUTE format('REVOKE %I FROM %I', 'r_sk2_ext_underhalltest', agare);
    EXECUTE format('GRANT %I TO %I', 'r_sk2_ext_underhalltest', agare);

    SELECT am.admin_option INTO admin_before
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'r_sk2_ext_underhalltest' AND mem.rolname = agare;

    PERFORM public.hex_underhall();

    SELECT am.admin_option INTO admin_after
    FROM pg_auth_members am
    JOIN pg_roles grp ON grp.oid = am.roleid
    JOIN pg_roles mem ON mem.oid = am.member
    WHERE grp.rolname = 'r_sk2_ext_underhalltest' AND mem.rolname = agare;

    IF admin_before IS DISTINCT FROM true AND admin_after = true THEN
        RAISE NOTICE 'TEST 9n PASSED: hex_underhall() uppgraderade befintligt r_-medlemskap till WITH ADMIN OPTION (before=%, after=%)', admin_before, admin_after;
    ELSE
        RAISE WARNING 'TEST 9n FAILED: admin_before=%, admin_after=% (förväntade false → true)', admin_before, admin_after;
    END IF;

    DROP SCHEMA sk2_ext_underhalltest CASCADE;
END $$;

------------------------------------------------------------------------
-- TEST 10: Specialfall och testfientliga indata
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 10: Specialfall ---'

-- 10a: Föräldralös _h-tabell (ingen förälder) ska BLOCKERAS (rullas tillbaka)
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.sneaky_h (data text);
    RAISE WARNING 'TEST 10a FAILED: Föräldralös _h-tabell accepterades (föräldern finns inte)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST 10a PASSED: Föräldralös _h-tabell blockerad: %', SQLERRM;
END $$;

-- 10a2: Legitim _h-tabell (föräldern finns) ska HOPPAS ÖVER (släppas igenom)
CREATE TABLE sk0_ext_test.parent_y (
    data text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    CREATE TABLE sk0_ext_test.parent_y_h (data text);

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'parent_y_h'
    ) THEN
        RAISE NOTICE 'TEST 10a2 PASSED: _h-tabell med befintlig förälder tilläts';
    ELSE
        RAISE WARNING 'TEST 10a2 FAILED: _h-tabell med befintlig förälder blockerades';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 10a2 FAILED: _h-tabell med befintlig förälder avvisades: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.parent_y_h;
DROP TABLE IF EXISTS sk0_ext_test.parent_y;

-- 10b: Reserverat geometrisuffix utan geometri (ska avvisas)
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.trick_p (name text);
    RAISE WARNING 'TEST 10b FAILED: Tabell med geometrisuffix men utan geometri accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST 10b PASSED: Tabell med geometrisuffix men utan geometri avvisad: %', SQLERRM;
END $$;

-- 10c: Användarkolumn med namnet 'gid' (ska tyst ersättas av standard-gid)
CREATE TABLE sk0_ext_test.usergid_y (
    gid text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE
    gid_type text;
BEGIN
    SELECT data_type INTO gid_type
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'usergid_y'
    AND column_name = 'gid';

    IF gid_type = 'integer' THEN
        RAISE NOTICE 'TEST 10c PASSED: Användarens gid (text) ersatt av standard-gid (integer)';
    ELSE
        RAISE WARNING 'TEST 10c FAILED: gid är % istället för integer', gid_type;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.usergid_y;

-- 10d: CREATE TABLE AS SELECT (annan DDL-tagg - kan kringgå Hex)
CREATE TABLE sk0_ext_test.source_y (
    data text,
    geom geometry(Polygon, 3007)
);

CREATE TABLE sk0_ext_test.ctas_y AS SELECT * FROM sk0_ext_test.source_y;

DO $$
DECLARE
    has_gid boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'ctas_y'
        AND column_name = 'gid'
    ) INTO has_gid;

    IF has_gid THEN
        RAISE NOTICE 'TEST 10d INFO: CREATE TABLE AS SELECT omstrukturerades AV Hex';
    ELSE
        RAISE WARNING 'TEST 10d INFO: CREATE TABLE AS SELECT kringgår Hex (ingen omstrukturering). Använd INSERT INTO ... SELECT istället.';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.ctas_y;
DROP TABLE IF EXISTS sk0_ext_test.source_y;

-- 10e: Reserverat kolumnnamn på fel schema (skapad_av på _ext_-tabell)
-- skapad_av är en standardkolumn endast för _kba_, men filtret tar bort
-- den från ALLA scheman. På _ext_ tas den tyst bort.
CREATE TABLE sk0_ext_test.reserverat_y (
    skapad_av text,
    other_data text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE
    has_skapad_av boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'reserverat_y'
        AND column_name = 'skapad_av'
    ) INTO has_skapad_av;

    IF has_skapad_av THEN
        RAISE NOTICE 'TEST 10e INFO: Användarkolumnen skapad_av behölls på ext-tabell';
    ELSE
        RAISE WARNING 'TEST 10e INFO: Användarkolumnen skapad_av tyst borttagen på ext-tabell (reserverat namn). Undvik att använda standardkolumnnamn på icke-kba-scheman.';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.reserverat_y;

-- 10f: Geometrikolumn ej namngiven 'geom' (ska avvisas)
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.badgeom_y (
        data text,
        the_geom geometry(Polygon, 3007)
    );
    RAISE WARNING 'TEST 10f FAILED: Tabell med geometri ej namngiven geom accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST 10f PASSED: Geometrikolumn måste heta geom: %', SQLERRM;
END $$;

-- 10g: ALTER TABLE ADD COLUMN på befintlig tabell (hex_hantera_ny_kolumn)
CREATE TABLE sk0_ext_test.addcol_y (
    data text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk0_ext_test.addcol_y ADD COLUMN extra_info text;

DO $$
DECLARE
    geom_pos integer;
    max_pos integer;
    extra_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_test'
        AND table_name = 'addcol_y'
        AND column_name = 'extra_info'
    ) INTO extra_exists;

    SELECT ordinal_position INTO geom_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'addcol_y'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_test'
    AND table_name = 'addcol_y';

    IF extra_exists AND geom_pos = max_pos THEN
        RAISE NOTICE 'TEST 10g PASSED: ADD COLUMN fungerar och geom förblir sist';
    ELSIF NOT extra_exists THEN
        RAISE WARNING 'TEST 10g FAILED: Kolumnen extra_info hittades inte efter ADD COLUMN';
    ELSE
        RAISE WARNING 'TEST 10g FAILED: geom inte sist efter ADD COLUMN (pos % av %)', geom_pos, max_pos;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.addcol_y;

-- 10h: Flera geometrikolumner (ska avvisas)
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.multigeom_y (
        geom geometry(Polygon, 3007),
        geom2 geometry(Point, 3007)
    );
    RAISE WARNING 'TEST 10h FAILED: Tabell med flera geometrikolumner accepterades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST 10h PASSED: Flera geometrikolumner avvisade: %', SQLERRM;
END $$;

------------------------------------------------------------------------
-- TEST 11: Beräknade kolumner (GENERATED ALWAYS AS ... STORED)
--
-- Omstruktureringen byggde tidigare upp kolumnen som
--   "<typ> GENERATED ALWAYS AS <uttryck> STORED"
-- utan parenteser runt uttrycket. pg_get_expr sätter bara ut yttre
-- parenteser för operatoruttryck, så "(a * b)" råkade fungera medan varje
-- funktionsbaserat uttryck – upper(namn), st_area(geom) – gav syntaxfel och
-- fällde hela CREATE TABLE. Typen hämtades dessutom ur udt_name, som tappar
-- typmodifieraren (numeric(10,2) → numeric).
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 11: Beräknade kolumner (GENERATED ALWAYS AS ... STORED) ---'

-- 11a: Funktionsbaserat uttryck (regressionen: gav "syntax error at or near")
DO $$
BEGIN
    CREATE TABLE sk0_ext_test.gen_funktion (
        namn       text,
        namn_versal text GENERATED ALWAYS AS (upper(namn)) STORED
    );
    RAISE NOTICE 'TEST 11a PASSED: Funktionsbaserat GENERATED-uttryck accepterat';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 11a FAILED: Funktionsbaserat GENERATED-uttryck avvisat: %', SQLERRM;
END $$;

-- 11b: Kolumnen är fortfarande beräknad efter omstruktureringen och räknar rätt
DO $$
DECLARE
    ar_genererad boolean;
    varde        text;
BEGIN
    SELECT a.attgenerated = 's' INTO ar_genererad
    FROM pg_attribute a
    WHERE a.attrelid = 'sk0_ext_test.gen_funktion'::regclass
    AND a.attname = 'namn_versal';

    INSERT INTO sk0_ext_test.gen_funktion (namn) VALUES ('kungsbacka');
    SELECT namn_versal INTO varde FROM sk0_ext_test.gen_funktion WHERE namn = 'kungsbacka';

    IF ar_genererad AND varde = 'KUNGSBACKA' THEN
        RAISE NOTICE 'TEST 11b PASSED: Kolumnen är beräknad och ger rätt värde efter omstrukturering';
    ELSIF NOT ar_genererad THEN
        RAISE WARNING 'TEST 11b FAILED: GENERATED-markeringen gick förlorad vid omstruktureringen';
    ELSE
        RAISE WARNING 'TEST 11b FAILED: Beräknat värde blev "%" (förväntade "KUNGSBACKA")', varde;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- Utan den här hanteraren avbryts blocket med ett rått ERROR när 11a
        -- redan fällt tabellen, i stället för att rapportera ett läsbart FAILED.
        RAISE WARNING 'TEST 11b FAILED: Kunde inte läsa beräknad kolumn: %', SQLERRM;
END $$;

-- 11c: En beräknad kolumn ska fortfarande vara skrivskyddad
DO $$
BEGIN
    INSERT INTO sk0_ext_test.gen_funktion (namn, namn_versal) VALUES ('x', 'FEL');
    RAISE WARNING 'TEST 11c FAILED: Direkt skrivning till beräknad kolumn accepterades';
EXCEPTION
    WHEN generated_always THEN
        RAISE NOTICE 'TEST 11c PASSED: Direkt skrivning till beräknad kolumn korrekt avvisad';
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 11c FAILED: Avvisad, men av ett oväntat fel: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.gen_funktion;

-- 11d: Typmodifieraren på en beräknad kolumn bevaras (numeric(10,2) → numeric(10,2))
DO $$
DECLARE
    typ text;
BEGIN
    CREATE TABLE sk0_ext_test.gen_typmod (
        a     numeric,
        b     numeric,
        total numeric(10,2) GENERATED ALWAYS AS (a * b) STORED
    );

    SELECT format_type(a.atttypid, a.atttypmod) INTO typ
    FROM pg_attribute a
    WHERE a.attrelid = 'sk0_ext_test.gen_typmod'::regclass
    AND a.attname = 'total';

    IF typ = 'numeric(10,2)' THEN
        RAISE NOTICE 'TEST 11d PASSED: Typmodifierare bevarad på beräknad kolumn (%)', typ;
    ELSE
        RAISE WARNING 'TEST 11d FAILED: Beräknad kolumn fick typ % (förväntade numeric(10,2))', typ;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.gen_typmod;

-- 11e: Typmodifieraren bevaras även på vanliga kolumner (samma udt_name-brist)
DO $$
DECLARE
    typ text;
BEGIN
    CREATE TABLE sk0_ext_test.typmod_vanlig (namn varchar(50));

    SELECT format_type(a.atttypid, a.atttypmod) INTO typ
    FROM pg_attribute a
    WHERE a.attrelid = 'sk0_ext_test.typmod_vanlig'::regclass
    AND a.attname = 'namn';

    IF typ = 'character varying(50)' THEN
        RAISE NOTICE 'TEST 11e PASSED: Typmodifierare bevarad på vanlig kolumn (%)', typ;
    ELSE
        RAISE WARNING 'TEST 11e FAILED: Vanlig kolumn fick typ % (förväntade character varying(50))', typ;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.typmod_vanlig;

-- 11f: Beräknad kolumn ovanpå geometrikolumnen – det praktiska GIS-fallet.
-- Geometrin sorteras alltid sist, så uttrycket refererar en kolumn som i den
-- nya tabellen deklareras EFTER den beräknade kolumnen.
DO $$
DECLARE
    area numeric;
BEGIN
    CREATE TABLE sk0_ext_test.gen_area_y (
        namn   text,
        area_m2 numeric GENERATED ALWAYS AS (ST_Area(geom)) STORED,
        geom   geometry(Polygon, 3007)
    );

    INSERT INTO sk0_ext_test.gen_area_y (namn, geom)
    VALUES ('kvarter', ST_GeomFromText('POLYGON((0 0,0 10,10 10,10 0,0 0))', 3007));

    SELECT area_m2 INTO area FROM sk0_ext_test.gen_area_y WHERE namn = 'kvarter';

    IF area = 100 THEN
        RAISE NOTICE 'TEST 11f PASSED: ST_Area-baserad beräknad kolumn fungerar (area = %)', area;
    ELSE
        RAISE WARNING 'TEST 11f FAILED: ST_Area gav % (förväntade 100)', area;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 11f FAILED: Beräknad kolumn över geometri gav fel: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk0_ext_test.gen_area_y;

-- 11g: Historiktabellen speglar en beräknad kolumn som VANLIG kolumn.
-- Vore den beräknad även i historiken skulle QA-triggerns INSERT (som listar
-- alla kolumner explicit) avvisas med "cannot insert a non-DEFAULT value".
DO $$
DECLARE
    -- attgenerated har typen "char", vars "inte beräknad"-värde är nollbyten
    -- och alltså inte lika med ''. Jämförelsen måste därför göras i SQL (som i
    -- 11b) – en char(1)-variabel i plpgsql ger fel svar.
    h_genererad boolean;
    h_varde     text;
BEGIN
    CREATE TABLE sk1_kba_test.gen_historik (
        namn        text,
        namn_versal text GENERATED ALWAYS AS (upper(namn)) STORED
    );

    INSERT INTO sk1_kba_test.gen_historik (namn) VALUES ('fjaras');
    UPDATE sk1_kba_test.gen_historik SET namn = 'onsala' WHERE namn = 'fjaras';

    SELECT a.attgenerated = 's' INTO h_genererad
    FROM pg_attribute a
    WHERE a.attrelid = 'sk1_kba_test.gen_historik_h'::regclass
    AND a.attname = 'namn_versal';

    SELECT namn_versal INTO h_varde
    FROM sk1_kba_test.gen_historik_h WHERE h_typ = 'U';

    IF NOT h_genererad AND h_varde = 'FJARAS' THEN
        RAISE NOTICE 'TEST 11g PASSED: Historiken lagrar beräknad kolumn som vanlig kolumn (%)', h_varde;
    ELSIF h_genererad THEN
        RAISE WARNING 'TEST 11g FAILED: Historikkolumnen är beräknad – QA-triggern kan inte skriva till den';
    ELSE
        RAISE WARNING 'TEST 11g FAILED: Historiken lagrade "%" (förväntade FJARAS)', h_varde;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 11g FAILED: Historik med beräknad kolumn gav fel: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk1_kba_test.gen_historik;

------------------------------------------------------------------------
-- TEST 12: Kolumntyper rekonstrueras med hex_kolumntyp() överallt
--
-- Typen byggdes tidigare upp för hand på tre ställen, med varsin CASE över
-- information_schema.columns. Ingen av kopiorna täckte arrayer: data_type ger
-- 'ARRAY', vilket blev syntaxfel, och udt_name ger internnamnet (_text).
-- Kopian som flyttar standardkolumner i historiktabellen saknade dessutom
-- numeric-grenen helt. Alla tre använder nu hex_kolumntyp().
------------------------------------------------------------------------
\echo ''
\echo '--- TEST 12: Kolumntyper via hex_kolumntyp() ---'

-- 12a: Arraykolumn fällde tidigare hela CREATE TABLE (via historiktabellen)
DO $$
BEGIN
    CREATE TABLE sk1_kba_test.typ_array (
        taggar text[],
        koder  integer[],
        belopp numeric(10,2),
        kod    varchar(50)
    );
    RAISE NOTICE 'TEST 12a PASSED: Tabell med arraykolumner skapad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 12a FAILED: Arraykolumn avvisad: %', SQLERRM;
END $$;

-- 12b: Historiktabellen speglar modertabellens typer exakt
DO $$
DECLARE
    avvikande text;
BEGIN
    -- LEFT JOIN så att en kolumn som saknas helt i historiktabellen fångas,
    -- inte bara en som finns men har fel typ.
    SELECT string_agg(format('%s (moder: %s, historik: %s)',
                             m.attname, m.typ, COALESCE(h.typ, 'SAKNAS')), ', ')
    INTO avvikande
    FROM (
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ
        FROM pg_attribute a
        WHERE a.attrelid = 'sk1_kba_test.typ_array'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped
    ) m
    LEFT JOIN (
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ
        FROM pg_attribute a
        WHERE a.attrelid = 'sk1_kba_test.typ_array_h'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped
    ) h ON h.attname = m.attname
    WHERE h.attname IS NULL OR h.typ IS DISTINCT FROM m.typ;

    IF avvikande IS NULL THEN
        RAISE NOTICE 'TEST 12b PASSED: Historiktabellens typer matchar modertabellen';
    ELSE
        RAISE WARNING 'TEST 12b FAILED: Typskillnad mot historiktabellen: %', avvikande;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 12b FAILED: Kunde inte jämföra typerna: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk1_kba_test.typ_array;

-- 12c: ALTER TABLE ADD COLUMN synkar nya kolumner till historiktabellen med
-- rätt typ (hex_hantera_ny_kolumn – kopia nummer två respektive tre)
DO $$
DECLARE
    avvikande text;
BEGIN
    CREATE TABLE sk1_kba_test.typ_alter_y (
        namn text,
        geom geometry(Polygon, 3007)
    );

    ALTER TABLE sk1_kba_test.typ_alter_y ADD COLUMN koder  integer[];
    ALTER TABLE sk1_kba_test.typ_alter_y ADD COLUMN belopp numeric(10,2);
    ALTER TABLE sk1_kba_test.typ_alter_y ADD COLUMN kod    varchar(50);

    -- LEFT JOIN, inte JOIN: när ADD COLUMN mot historiktabellen misslyckas
    -- fångas felet av en WARNING-hanterare i hex_hantera_ny_kolumn och
    -- kolumnen uteblir tyst. En inre join hade jämfört bara de kolumner som
    -- redan fanns i båda tabellerna och missat precis det fallet.
    SELECT string_agg(format('%s (moder: %s, historik: %s)',
                             m.attname, m.typ, COALESCE(h.typ, 'SAKNAS')), ', ')
    INTO avvikande
    FROM (
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ
        FROM pg_attribute a
        WHERE a.attrelid = 'sk1_kba_test.typ_alter_y'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped
    ) m
    LEFT JOIN (
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ
        FROM pg_attribute a
        WHERE a.attrelid = 'sk1_kba_test.typ_alter_y_h'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped
    ) h ON h.attname = m.attname
    WHERE h.attname IS NULL OR h.typ IS DISTINCT FROM m.typ;

    IF avvikande IS NULL THEN
        RAISE NOTICE 'TEST 12c PASSED: ADD COLUMN synkar rätt typer till historiktabellen';
    ELSE
        RAISE WARNING 'TEST 12c FAILED: Typskillnad efter ADD COLUMN: %', avvikande;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 12c FAILED: ADD COLUMN gav fel: %', SQLERRM;
END $$;

-- 12d: QA-triggern kan fortfarande skriva efter synkroniseringen
DO $$
DECLARE
    antal integer;
BEGIN
    INSERT INTO sk1_kba_test.typ_alter_y (namn, geom, koder, belopp, kod)
    VALUES ('rad', ST_GeomFromText('POLYGON((0 0,0 1,1 1,1 0,0 0))', 3007),
            '{1,2}', 3.25, 'abc');
    UPDATE sk1_kba_test.typ_alter_y SET belopp = 9.75 WHERE namn = 'rad';

    SELECT COUNT(*) INTO antal
    FROM sk1_kba_test.typ_alter_y_h
    WHERE h_typ = 'U' AND belopp = 3.25 AND koder = '{1,2}';

    IF antal = 1 THEN
        RAISE NOTICE 'TEST 12d PASSED: QA-triggern skriver array och numeric till historiken';
    ELSE
        RAISE WARNING 'TEST 12d FAILED: Historiken saknar den uppdaterade raden (% träffar)', antal;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 12d FAILED: QA-triggern gav fel: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk1_kba_test.typ_alter_y;

-- 12e: Geometrins fulla typ (inkl. Z) bevaras i historiktabellen
DO $$
DECLARE
    m_typ text;
    h_typ_ text;
BEGIN
    CREATE TABLE sk1_kba_test.typ_geomz_y (
        namn text,
        geom geometry(PolygonZ, 3007)
    );

    m_typ  := public.hex_kolumntyp('sk1_kba_test', 'typ_geomz_y', 'geom');
    h_typ_ := public.hex_kolumntyp('sk1_kba_test', 'typ_geomz_y_h', 'geom');

    IF m_typ = 'geometry(PolygonZ,3007)' AND h_typ_ = m_typ THEN
        RAISE NOTICE 'TEST 12e PASSED: Z-geometri bevarad i både moder- och historiktabell (%)', m_typ;
    ELSE
        RAISE WARNING 'TEST 12e FAILED: geom är % i modertabellen och % i historiken', m_typ, h_typ_;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST 12e FAILED: Z-geometri gav fel: %', SQLERRM;
END $$;

DROP TABLE IF EXISTS sk1_kba_test.typ_geomz_y;

------------------------------------------------------------------------
-- SLUTLIG STÄDNING
------------------------------------------------------------------------
\echo ''
\echo '--- Städar upp testscheman ---'
DROP SCHEMA IF EXISTS sk1_kba_test CASCADE;
DROP SCHEMA IF EXISTS sk0_ext_test CASCADE;

\echo ''
\echo '============================================================'
\echo 'REGRESSIONSTESTSVIT SLUTFÖRD'
\echo 'Granska NOTICE/WARNING-meddelandena ovan för resultat.'
\echo 'NOTICE = PASSED, WARNING = FAILED'
\echo '============================================================'
