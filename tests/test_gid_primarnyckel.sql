-- ============================================================
-- HEX GID PRIMÄRNYCKEL TEST SUITE
--
-- Testar:
--   1  Nya tabeller får PRIMARY KEY (gid) via hantera_ny_tabell
--   2  QGIS-villkoren för att hitta gid-sekvensen är uppfyllda
--   3  sakerstall_gid_primarnyckel() på äldre tabeller (migrering)
--   4  Sekvenssynkronisering mot max(gid)
--   5  Dubbletter blockerar nyckeln och rapporteras
--   6  reparera_gid_dubbletter() torrkörning och skarp körning
--   7  Historiktabeller får INTE unikt gid
--   8  Nyckeln bryter inte hex_tvinga_gid
--
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX GID PRIMÄRNYCKEL TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_gidtest CASCADE;

CREATE SCHEMA sk1_kba_gidtest;

-- ============================================================
-- 1: Nya tabeller får PRIMARY KEY (gid)
-- ============================================================
\echo ''
\echo '--- GROUP 1: New tables get PRIMARY KEY (gid) ---'

CREATE TABLE sk1_kba_gidtest.nyckeltabell (namn text, vikt integer);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM   pg_index     i
        JOIN   pg_attribute a ON a.attrelid = i.indrelid
                             AND a.attnum::text = i.indkey::text
        WHERE  i.indrelid = 'sk1_kba_gidtest.nyckeltabell'::regclass
          AND  i.indisprimary
          AND  a.attname = 'gid'
    ) THEN
        RAISE NOTICE 'TEST 1a PASSED: hantera_ny_tabell created PRIMARY KEY (gid)';
    ELSE
        RAISE WARNING 'TEST 1a FAILED: no PRIMARY KEY on gid';
    END IF;
END $$;

-- ============================================================
-- 2: QGIS hittar gid-sekvensen
--    QGIS slår bara upp pg_get_serial_sequence() för en IDENTITY-kolumn
--    som är NOT NULL, har ett unikt index och saknar pg_attrdef-default.
--    Är villkoret inte uppfyllt får gid inget defaultvärde i QGIS och
--    presenteras som ett tomt obligatoriskt fält.
-- ============================================================
\echo ''
\echo '--- GROUP 2: QGIS sequence-detection preconditions ---'

DO $$
DECLARE
    ar_notnull  boolean;
    ar_unik     boolean;
    ar_identity boolean;
    har_attrdef boolean;
BEGIN
    SELECT a.attnotnull,
           u.indisunique IS NOT NULL,
           a.attidentity <> '',
           d.adbin IS NOT NULL
    INTO   ar_notnull, ar_unik, ar_identity, har_attrdef
    FROM   pg_attribute a
    LEFT   JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    LEFT   JOIN (SELECT DISTINCT indrelid, indkey, indisunique
                 FROM pg_index WHERE indisunique) u
           ON u.indrelid = a.attrelid AND a.attnum::text = u.indkey::text
    WHERE  a.attrelid = 'sk1_kba_gidtest.nyckeltabell'::regclass
      AND  a.attname  = 'gid';

    IF ar_notnull AND ar_unik AND ar_identity AND NOT har_attrdef THEN
        RAISE NOTICE 'TEST 2a PASSED: gid is NOT NULL + unique + identity without attrdef';
    ELSE
        RAISE WARNING 'TEST 2a FAILED: notnull=% unique=% identity=% attrdef=%',
            ar_notnull, ar_unik, ar_identity, har_attrdef;
    END IF;

    IF pg_get_serial_sequence('sk1_kba_gidtest.nyckeltabell', 'gid') IS NOT NULL THEN
        RAISE NOTICE 'TEST 2b PASSED: pg_get_serial_sequence resolves the gid sequence';
    ELSE
        RAISE WARNING 'TEST 2b FAILED: pg_get_serial_sequence returned NULL';
    END IF;
END $$;

-- ============================================================
-- 3: Migrering av äldre tabeller utan nyckel
-- ============================================================
\echo ''
\echo '--- GROUP 3: Migrating legacy tables without a key ---'

-- Simulera en tabell skapad av äldre Hex: ta bort nyckeln utan att
-- event-triggern startar en omstrukturering.
ALTER EVENT TRIGGER hantera_kolumntillagg_trigger DISABLE;
ALTER TABLE sk1_kba_gidtest.nyckeltabell DROP CONSTRAINT nyckeltabell_pkey;
ALTER EVENT TRIGGER hantera_kolumntillagg_trigger ENABLE;

DO $$
DECLARE resultat text;
BEGIN
    resultat := public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'nyckeltabell');
    IF resultat = 'skapad' THEN
        RAISE NOTICE 'TEST 3a PASSED: key restored on a legacy table (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 3a FAILED: expected "skapad", got "%"', resultat;
    END IF;

    -- Idempotens: andra körningen ska inte röra tabellen
    resultat := public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'nyckeltabell');
    IF resultat = 'redan finns' THEN
        RAISE NOTICE 'TEST 3b PASSED: second run is a no-op (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 3b FAILED: expected "redan finns", got "%"', resultat;
    END IF;
END $$;

-- Tabeller utan gid IDENTITY ska hoppas över. Testtabellen läggs i public,
-- eftersom Hex lägger till gid på allt som skapas i ett Hex-schema.
CREATE TABLE public.hex_gidtest_utan_gid (id integer, namn text);

DO $$
DECLARE resultat text;
BEGIN
    resultat := public.sakerstall_gid_primarnyckel('public', 'hex_gidtest_utan_gid');
    IF resultat = 'saknar gid' THEN
        RAISE NOTICE 'TEST 3c PASSED: table without gid identity is skipped (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 3c FAILED: expected "saknar gid", got "%"', resultat;
    END IF;

    resultat := public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'finns_inte');
    IF resultat = 'saknar gid' THEN
        RAISE NOTICE 'TEST 3d PASSED: missing table is skipped (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 3d FAILED: expected "saknar gid", got "%"', resultat;
    END IF;
END $$;

DROP TABLE public.hex_gidtest_utan_gid;

-- ============================================================
-- 4: Sekvenssynkronisering
--    Data som lästs in med OVERRIDING SYSTEM VALUE kan ligga ovanför
--    sekvensen. Utan framflyttning skulle nyckeln göra nästa INSERT till
--    ett dubblettfel.
-- ============================================================
\echo ''
\echo '--- GROUP 4: Sequence resync against max(gid) ---'

DO $$
DECLARE
    seq_namn  text;
    seq_last  bigint;
    nytt_gid  integer;
BEGIN
    ALTER EVENT TRIGGER hantera_kolumntillagg_trigger DISABLE;
    ALTER TABLE sk1_kba_gidtest.nyckeltabell DROP CONSTRAINT nyckeltabell_pkey;
    ALTER TABLE sk1_kba_gidtest.nyckeltabell DISABLE TRIGGER hex_tvinga_gid;
    ALTER EVENT TRIGGER hantera_kolumntillagg_trigger ENABLE;

    INSERT INTO sk1_kba_gidtest.nyckeltabell (gid, namn)
    OVERRIDING SYSTEM VALUE VALUES (5000, 'inläst');

    ALTER TABLE sk1_kba_gidtest.nyckeltabell ENABLE TRIGGER hex_tvinga_gid;

    PERFORM public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'nyckeltabell');

    seq_namn := pg_get_serial_sequence('sk1_kba_gidtest.nyckeltabell', 'gid');
    EXECUTE format('SELECT last_value FROM %s', seq_namn) INTO seq_last;

    IF seq_last >= 5000 THEN
        RAISE NOTICE 'TEST 4a PASSED: sequence moved up to % (max gid 5000)', seq_last;
    ELSE
        RAISE WARNING 'TEST 4a FAILED: sequence still at %, expected >= 5000', seq_last;
    END IF;

    INSERT INTO sk1_kba_gidtest.nyckeltabell (namn) VALUES ('efter migrering')
    RETURNING gid INTO nytt_gid;

    IF nytt_gid > 5000 THEN
        RAISE NOTICE 'TEST 4b PASSED: insert after migration got gid % (no collision)', nytt_gid;
    ELSE
        RAISE WARNING 'TEST 4b FAILED: insert got gid %, expected > 5000', nytt_gid;
    END IF;
END $$;

-- ============================================================
-- 5: Dubbletter blockerar nyckeln
-- ============================================================
\echo ''
\echo '--- GROUP 5: Duplicates block the key instead of changing data ---'

DO $$
DECLARE
    resultat  text;
    antal_fore bigint;
    antal_efter bigint;
BEGIN
    CREATE TABLE sk1_kba_gidtest.dubblett (namn text);

    ALTER EVENT TRIGGER hantera_kolumntillagg_trigger DISABLE;
    ALTER TABLE sk1_kba_gidtest.dubblett DROP CONSTRAINT dubblett_pkey;
    ALTER TABLE sk1_kba_gidtest.dubblett DISABLE TRIGGER hex_tvinga_gid;
    ALTER EVENT TRIGGER hantera_kolumntillagg_trigger ENABLE;

    INSERT INTO sk1_kba_gidtest.dubblett (gid, namn)
    OVERRIDING SYSTEM VALUE VALUES (1, 'a'), (1, 'b'), (2, 'c');

    ALTER TABLE sk1_kba_gidtest.dubblett ENABLE TRIGGER hex_tvinga_gid;

    SELECT count(*) INTO antal_fore FROM sk1_kba_gidtest.dubblett;
    resultat := public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'dubblett');
    SELECT count(*) INTO antal_efter FROM sk1_kba_gidtest.dubblett;

    IF resultat LIKE 'dubbletter:%' THEN
        RAISE NOTICE 'TEST 5a PASSED: duplicates reported, key skipped (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 5a FAILED: expected "dubbletter: N", got "%"', resultat;
    END IF;

    IF antal_fore = antal_efter THEN
        RAISE NOTICE 'TEST 5b PASSED: no rows were touched (% rows)', antal_efter;
    ELSE
        RAISE WARNING 'TEST 5b FAILED: row count changed from % to %', antal_fore, antal_efter;
    END IF;
END $$;

-- ============================================================
-- 6: reparera_gid_dubbletter()
-- ============================================================
\echo ''
\echo '--- GROUP 6: reparera_gid_dubbletter dry run and execution ---'

DO $$
DECLARE
    antal_dubbl bigint;
    resultat    text;
BEGIN
    -- Torrkörning får inte ändra något
    PERFORM * FROM public.reparera_gid_dubbletter('sk1_kba_gidtest', 'dubblett');

    SELECT count(*) INTO antal_dubbl
    FROM  (SELECT gid FROM sk1_kba_gidtest.dubblett
           GROUP BY gid HAVING count(*) > 1) d;

    IF antal_dubbl = 1 THEN
        RAISE NOTICE 'TEST 6a PASSED: dry run left the duplicates in place';
    ELSE
        RAISE WARNING 'TEST 6a FAILED: expected 1 duplicate group, found %', antal_dubbl;
    END IF;

    -- Skarp körning
    PERFORM * FROM public.reparera_gid_dubbletter('sk1_kba_gidtest', 'dubblett', true);

    SELECT count(*) INTO antal_dubbl
    FROM  (SELECT gid FROM sk1_kba_gidtest.dubblett
           GROUP BY gid HAVING count(*) > 1) d;

    IF antal_dubbl = 0 THEN
        RAISE NOTICE 'TEST 6b PASSED: duplicates renumbered';
    ELSE
        RAISE WARNING 'TEST 6b FAILED: % duplicate groups remain', antal_dubbl;
    END IF;

    IF (SELECT count(*) FROM sk1_kba_gidtest.dubblett) = 3 THEN
        RAISE NOTICE 'TEST 6c PASSED: renumbering kept all 3 rows';
    ELSE
        RAISE WARNING 'TEST 6c FAILED: row count is %, expected 3',
            (SELECT count(*) FROM sk1_kba_gidtest.dubblett);
    END IF;

    resultat := public.sakerstall_gid_primarnyckel('sk1_kba_gidtest', 'dubblett');
    IF resultat = 'skapad' THEN
        RAISE NOTICE 'TEST 6d PASSED: key created after repair (%)', resultat;
    ELSE
        RAISE WARNING 'TEST 6d FAILED: expected "skapad", got "%"', resultat;
    END IF;
END $$;

-- ============================================================
-- 7: Historiktabeller ska INTE få unikt gid
--    En historiktabell innehåller flera versioner av samma gid.
--    Urvalet bygger på attidentity, som historiktabellens kopierade
--    gid-kolumn saknar.
-- ============================================================
\echo ''
\echo '--- GROUP 7: History tables must not get a unique gid ---'

DO $$
DECLARE antal integer;
BEGIN
    SELECT count(*) INTO antal
    FROM   pg_indexes
    WHERE  schemaname = 'sk1_kba_gidtest'
      AND  tablename LIKE '%\_h'
      AND  indexdef LIKE '%UNIQUE%';

    IF antal = 0 THEN
        RAISE NOTICE 'TEST 7a PASSED: no unique index on any history table';
    ELSE
        RAISE WARNING 'TEST 7a FAILED: % unique index(es) on history tables', antal;
    END IF;
END $$;

-- ============================================================
-- 8: hex_tvinga_gid fungerar fortfarande
-- ============================================================
\echo ''
\echo '--- GROUP 8: hex_tvinga_gid still overrides client values ---'

DO $$
DECLARE nytt_gid integer;
BEGIN
    INSERT INTO sk1_kba_gidtest.nyckeltabell (gid, namn)
    OVERRIDING SYSTEM VALUE VALUES (999999, 'klientvärde')
    RETURNING gid INTO nytt_gid;

    IF nytt_gid <> 999999 THEN
        RAISE NOTICE 'TEST 8a PASSED: client gid 999999 replaced by % ', nytt_gid;
    ELSE
        RAISE WARNING 'TEST 8a FAILED: client gid 999999 was stored';
    END IF;
END $$;

-- gid får aldrig ändras till ett litteralt värde – bara till DEFAULT.
-- Detta är PostgreSQL:s IDENTITY-regel och gäller även med nyckeln på plats.
DO $$
BEGIN
    BEGIN
        UPDATE sk1_kba_gidtest.nyckeltabell SET gid = gid WHERE namn = 'klientvärde';
        RAISE WARNING 'TEST 8b FAILED: UPDATE SET gid = gid was accepted';
    EXCEPTION WHEN generated_always THEN
        RAISE NOTICE 'TEST 8b PASSED: UPDATE of gid rejected (only DEFAULT allowed)';
    END;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_gidtest CASCADE;

\echo ''
\echo '============================================================'
\echo 'GID PRIMÄRNYCKEL TEST SUITE COMPLETE'
\echo '============================================================'
