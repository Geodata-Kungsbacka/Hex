-- ============================================================
-- TEST: Rollrättigheter på w_- och r_-roller
--
-- Verifierar att hex_tilldela_rollrattigheter() korrekt beviljar:
--   r_-roller: USAGE på schema, SELECT på tabeller (+ default privs)
--   w_-roller: USAGE på schema, ALL på tabeller (inkl. TRUNCATE),
--              USAGE+SELECT på sekvenser (+ default privs för båda)
--
-- Schema som används: sk1_kba_permtest
-- Konvention: NOTICE = PASSED, WARNING = FAILED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'TEST: Rollrättigheter (r_- och w_-roller)'
\echo '============================================================'

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_permtest CASCADE;
DROP ROLE IF EXISTS r_sk1_kba_permtest;
DROP ROLE IF EXISTS w_sk1_kba_permtest;

-- ============================================================
-- Förberedelse: CREATE SCHEMA utlöser hex_hantera_std_roller,
-- som anropar hex_tilldela_rollrattigheter för varje roll.
-- ============================================================
CREATE SCHEMA sk1_kba_permtest;

-- Låt Hex lägga till standardkolumner via event triggern (inget gid deklarerat).
-- Använd ett sk1_kba-schema + _y-suffix så att Hex bearbetar tabellen fullt ut.
CREATE TABLE sk1_kba_permtest.testobj_y (
    namn text,
    geom geometry(Polygon, 3007)
);

-- ============================================================
-- Verifiera att rollerna skapades
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_kba_permtest') THEN
        RAISE NOTICE 'SETUP: r_sk1_kba_permtest finns';
    ELSE
        RAISE WARNING 'SETUP FAILED: r_sk1_kba_permtest saknas — event triggern kanske inte avfyrades';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk1_kba_permtest') THEN
        RAISE NOTICE 'SETUP: w_sk1_kba_permtest finns';
    ELSE
        RAISE WARNING 'SETUP FAILED: w_sk1_kba_permtest saknas — event triggern kanske inte avfyrades';
    END IF;
END $$;

-- ============================================================
-- TESTER FÖR R_-ROLLEN
-- ============================================================
\echo ''
\echo '--- r_-roll (läs) ---'

-- R1: USAGE på schema
DO $$
BEGIN
    IF has_schema_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest', 'USAGE') THEN
        RAISE NOTICE 'TEST R1 PASSED: r_ har USAGE på schema';
    ELSE
        RAISE WARNING 'TEST R1 FAILED: r_ saknar USAGE på schema sk1_kba_permtest';
    END IF;
END $$;

-- R2: SELECT på befintlig tabell
DO $$
BEGIN
    IF has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'SELECT') THEN
        RAISE NOTICE 'TEST R2 PASSED: r_ har SELECT på befintlig tabell';
    ELSE
        RAISE WARNING 'TEST R2 FAILED: r_ saknar SELECT på sk1_kba_permtest.testobj_y';
    END IF;
END $$;

-- R3: ingen INSERT (rimlighetskontroll för läsroll)
DO $$
BEGIN
    IF NOT has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'INSERT') THEN
        RAISE NOTICE 'TEST R3 PASSED: r_ har korrekt ingen INSERT på tabellen';
    ELSE
        RAISE WARNING 'TEST R3 FAILED: r_ har INSERT — ska vara skrivskyddad';
    END IF;
END $$;

-- R4: ingen USAGE på sekvens (läsroller behöver inte anropa nextval)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST R4 SKIPPED: ingen sekvens hittades i sk1_kba_permtest';
        RETURN;
    END IF;

    IF NOT has_sequence_privilege('r_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST R4 PASSED: r_ har ingen USAGE på sekvens (korrekt för skrivskyddad roll)';
    ELSE
        RAISE WARNING 'TEST R4 NOTE: r_ har USAGE på sekvens (oväntat men inte blockerande)';
    END IF;
END $$;

-- R5: DEFAULT PRIVILEGES — skapa en andra tabell EFTER rolluppsättning, verifiera att SELECT sprids
CREATE TABLE sk1_kba_permtest.testobjb_p (
    kod text,
    geom geometry(Point, 3007)
);

DO $$
BEGIN
    IF has_table_privilege('r_sk1_kba_permtest', 'sk1_kba_permtest.testobjb_p', 'SELECT') THEN
        RAISE NOTICE 'TEST R5 PASSED: r_ har SELECT på tabell skapad efter rolluppsättning (DEFAULT PRIVILEGES fungerar)';
    ELSE
        RAISE WARNING 'TEST R5 FAILED: r_ saknar SELECT på testobjb_p — DEFAULT PRIVILEGES fungerar inte';
    END IF;
END $$;

-- ============================================================
-- TESTER FÖR W_-ROLLEN
-- ============================================================
\echo ''
\echo '--- w_-roll (skriv) ---'

-- W1: USAGE på schema
DO $$
BEGIN
    IF has_schema_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest', 'USAGE') THEN
        RAISE NOTICE 'TEST W1 PASSED: w_ har USAGE på schema';
    ELSE
        RAISE WARNING 'TEST W1 FAILED: w_ saknar USAGE på schema sk1_kba_permtest';
    END IF;
END $$;

-- W2: SELECT, INSERT, UPDATE, DELETE, TRUNCATE på befintlig tabell
DO $$
DECLARE saknas text := '';
BEGIN
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'SELECT')   THEN saknas := saknas || 'SELECT ';   END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'INSERT')   THEN saknas := saknas || 'INSERT ';   END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'UPDATE')   THEN saknas := saknas || 'UPDATE ';   END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'DELETE')   THEN saknas := saknas || 'DELETE ';   END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'TRUNCATE') THEN saknas := saknas || 'TRUNCATE '; END IF;

    IF saknas = '' THEN
        RAISE NOTICE 'TEST W2 PASSED: w_ har SELECT/INSERT/UPDATE/DELETE/TRUNCATE på befintlig tabell';
    ELSE
        RAISE WARNING 'TEST W2 FAILED: w_ saknar [%] på testobj_y', saknas;
    END IF;
END $$;

-- W2b: TRUNCATE explicit (kärnfixen — FMEs truncate-and-reload-mönster)
DO $$
BEGIN
    IF has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobj_y', 'TRUNCATE') THEN
        RAISE NOTICE 'TEST W2b PASSED: w_ har TRUNCATE på befintlig tabell';
    ELSE
        RAISE WARNING 'TEST W2b FAILED: w_ saknar TRUNCATE — FMEs truncate-and-reload kommer att misslyckas';
    END IF;
END $$;

-- W3: USAGE på sekvens — kärnfixen (INSERT med identity-kolumn kräver detta)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    ORDER BY s.relname LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE WARNING 'TEST W3 SKIPPED: ingen sekvens hittades i sk1_kba_permtest';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST W3 PASSED: w_ har USAGE på sekvens % (INSERT på identity-kolumner kommer att fungera)', seq_name;
    ELSE
        RAISE WARNING 'TEST W3 FAILED: w_ saknar USAGE på sekvens % — INSERT kommer att misslyckas', seq_name;
    END IF;
END $$;

-- W4: SELECT på sekvens
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    WHERE n.nspname = 'sk1_kba_permtest' AND s.relkind = 'S'
    ORDER BY s.relname LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST W4 SKIPPED: ingen sekvens hittades';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'SELECT') THEN
        RAISE NOTICE 'TEST W4 PASSED: w_ har SELECT på sekvens %', seq_name;
    ELSE
        RAISE WARNING 'TEST W4 FAILED: w_ saknar SELECT på sekvens %', seq_name;
    END IF;
END $$;

-- W5: DEFAULT PRIVILEGES på tabeller — INSERT + TRUNCATE på tabell skapad efter rolluppsättning
DO $$
DECLARE saknas text := '';
BEGIN
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobjb_p', 'INSERT')   THEN saknas := saknas || 'INSERT ';   END IF;
    IF NOT has_table_privilege('w_sk1_kba_permtest', 'sk1_kba_permtest.testobjb_p', 'TRUNCATE') THEN saknas := saknas || 'TRUNCATE '; END IF;

    IF saknas = '' THEN
        RAISE NOTICE 'TEST W5 PASSED: w_ har INSERT/TRUNCATE på tabell skapad efter rolluppsättning (DEFAULT PRIVILEGES på tabeller fungerar)';
    ELSE
        RAISE WARNING 'TEST W5 FAILED: w_ saknar [%] på testobjb_p — DEFAULT PRIVILEGES på tabeller fungerar inte', saknas;
    END IF;
END $$;

-- W6: DEFAULT PRIVILEGES på sekvenser — USAGE på sekvensen för testobjb_p (skapad efter rolluppsättning)
DO $$
DECLARE seq_name text;
BEGIN
    SELECT s.relname INTO seq_name
    FROM pg_class s
    JOIN pg_namespace n ON n.oid = s.relnamespace
    JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a', 'i')
    JOIN pg_class t ON t.oid = d.refobjid
    WHERE n.nspname = 'sk1_kba_permtest'
      AND s.relkind = 'S'
      AND t.relname = 'testobjb_p'
    LIMIT 1;

    IF seq_name IS NULL THEN
        RAISE NOTICE 'TEST W6 SKIPPED: ingen sekvens kopplad till testobjb_p hittades';
        RETURN;
    END IF;

    IF has_sequence_privilege('w_sk1_kba_permtest',
            'sk1_kba_permtest.' || seq_name, 'USAGE') THEN
        RAISE NOTICE 'TEST W6 PASSED: w_ har USAGE på sekvens % för tabell skapad efter rolluppsättning (DEFAULT PRIVILEGES på sekvenser fungerar)', seq_name;
    ELSE
        RAISE WARNING 'TEST W6 FAILED: w_ saknar USAGE på sekvens % — DEFAULT PRIVILEGES på sekvenser fungerar inte', seq_name;
    END IF;
END $$;

-- ============================================================
-- Städning
-- ============================================================
\echo ''
\echo '--- Städning ---'
DROP SCHEMA sk1_kba_permtest CASCADE;

\echo ''
\echo '============================================================'
\echo 'Rollrättighetstester klara.'
\echo '============================================================'
