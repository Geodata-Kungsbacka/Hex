-- ============================================================
-- HEX EXTENDED TEST SUITE — GROUPS C & D
--
-- C  Klient-simulering (GeoServer, QGIS, FME)
--    C1  GeoServer application_name: full restructuring still runs
--    C2  QGIS application_name: full kba treatment (andrad_tidpunkt + history)
--    C3  FME application_name: restructuring still runs
--    C4  GeoServer/QGIS-style metadata queries are safe
--    C5  QGIS-style EXPLAIN on geometry query works
--
-- D  Strukturella kantfall och adversariella tester
--    D1  CREATE UNLOGGED TABLE: UNLOGGED silently dropped during restructuring
--    D2  CREATE TABLE IF NOT EXISTS (new table): restructured normally
--    D3  CREATE TABLE IF NOT EXISTS (existing table): safe no-op
--    D4  CREATE TABLE LIKE: copies structure, Hex adds gid + GiST index
--    D5  ALTER TABLE RENAME TO: history table rename tracked via OID
--    D6  ADD COLUMN then DROP user column: no orphaned _temp0001
--    D7  DROP standard column: no orphaned _temp0001 (pre-existence guard)
--    D8  Multiple ADD COLUMNs in one ALTER TABLE: all present, geom last
--    D9  61-char table name: 63-char history name created correctly
--    D10 62-char table name: 64-char name truncated to 63 (trailing h dropped)
--    D11 _h table bypass: _h tables skip Hex restructuring
--    D12 CREATE SCHEMA IF NOT EXISTS on existing schema: safe no-op
--
-- Schemas used: sk2_ext_test, sk2_kba_test, sk2_sys_test, sk1_kba_htest
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX EXTENDED TEST SUITE — GROUPS C & D'
\echo '============================================================'

-- ============================================================
-- Cleanup and setup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

CREATE SCHEMA sk2_ext_test;
CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_sys_test;
CREATE SCHEMA sk1_kba_htest;

-- Seed one geometry table in sk2_ext_test so C4/C5 and D tests have something to query
CREATE TABLE sk2_ext_test.fororeningar_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

-- Seed one table in sk2_sys_test so C4 can count across schemas
CREATE TABLE sk2_sys_test.konfig (
    param text,
    varde text
);

-- ============================================================
-- C: CLIENT SIMULATION (GeoServer, QGIS, FME)
-- ============================================================
\echo ''
\echo '--- GROUP C: Client application simulation ---'

-- C1: application_name = GeoServer - NOT FME, full restructuring must occur
SET application_name = 'GeoServer 2.24.3';

CREATE TABLE sk2_ext_test.gs_lager_p (
    layer_id integer,
    geom geometry(Point, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'gs_lager_p'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST C1 PASSED: Table created via GeoServer-named connection still gets restructured';
    ELSE
        RAISE WARNING 'TEST C1 FAILED: GeoServer application_name caused table to skip restructuring';
    END IF;
END $$;

RESET application_name;

-- C2: application_name = QGIS - not FME, full kba restructuring
SET application_name = 'QGIS 3.34.8 Prizren';

CREATE TABLE sk1_kba_htest.byggnader_y (
    fastighet text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_htest' AND table_name = 'byggnader_y'
        AND column_name = 'andrad_tidpunkt'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_htest' AND table_name = 'byggnader_y_h'
    ) THEN
        RAISE NOTICE 'TEST C2 PASSED: QGIS connection gets full kba treatment (andrad_tidpunkt + history table)';
    ELSE
        RAISE WARNING 'TEST C2 FAILED: QGIS kba table missing andrad_tidpunkt or history table';
    END IF;
END $$;

RESET application_name;

-- C3: application_name = FME - restructuring still occurs
SET application_name = 'FME Desktop 2024.0.0.0';

CREATE TABLE sk2_ext_test.fme_import_y (
    kalla text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'fme_import_y'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST C3 PASSED: FME connection still gets table restructured (gid present)';
    ELSE
        RAISE WARNING 'TEST C3 FAILED: FME application_name caused table to skip restructuring';
    END IF;
END $$;

RESET application_name;

-- C4: GeoServer/QGIS-style metadata queries (read-only, must always be safe)
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM geometry_columns
    WHERE f_table_schema IN ('sk2_ext_test', 'sk2_kba_test');

    SELECT COUNT(*) INTO cnt FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test';

    SELECT COUNT(*) INTO cnt FROM information_schema.tables
    WHERE table_schema IN ('sk2_ext_test', 'sk2_kba_test', 'sk2_sys_test');

    SELECT COUNT(*) INTO cnt FROM pg_indexes
    WHERE schemaname = 'sk2_ext_test';

    RAISE NOTICE 'TEST C4 PASSED: GeoServer/QGIS-style metadata queries work fine (% tables found)', cnt;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST C4 FAILED: Metadata query error: %', SQLERRM;
END $$;

-- C5: QGIS-style EXPLAIN on a Hex-managed table
DO $$
BEGIN
    EXECUTE 'EXPLAIN SELECT * FROM sk2_ext_test.fororeningar_y WHERE ST_Intersects(geom, ST_MakeEnvelope(0,0,100,100,3007))';
    RAISE NOTICE 'TEST C5 PASSED: EXPLAIN on geometry-filtered query works fine';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST C5 FAILED: EXPLAIN failed: %', SQLERRM;
END $$;

-- ============================================================
-- D: ADVERSARIAL AND STRUCTURAL EDGE CASES
-- ============================================================
\echo ''
\echo '--- GROUP D: Adversarial and structural edge cases ---'

-- D1: CREATE UNLOGGED TABLE - Hex restructures it; UNLOGGED property may be silently lost
CREATE UNLOGGED TABLE sk2_ext_test.temp_import_y (
    batch_id integer,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE persistence char(1);
BEGIN
    SELECT relpersistence INTO persistence
    FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'sk2_ext_test' AND c.relname = 'temp_import_y';

    CASE persistence
        WHEN 'p' THEN
            RAISE WARNING 'TEST D1 INFO: UNLOGGED TABLE became permanent/logged after Hex restructuring. The UNLOGGED property is silently dropped during byt_ut_tabell. Expected if temp table is created as permanent.';
        WHEN 'u' THEN
            RAISE NOTICE 'TEST D1 PASSED: UNLOGGED property preserved after restructuring';
        ELSE
            RAISE WARNING 'TEST D1 UNEXPECTED: relpersistence = "%"', persistence;
    END CASE;
END $$;

-- D2: CREATE TABLE IF NOT EXISTS (table does NOT yet exist) - should work normally
DO $$
BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS sk2_ext_test.ifnotexists_y (
        naam text,
        geom geometry(Polygon, 3007)
    )';
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'ifnotexists_y'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST D2 PASSED: CREATE TABLE IF NOT EXISTS (new table) restructured correctly';
    ELSE
        RAISE WARNING 'TEST D2 FAILED: IF NOT EXISTS new table not restructured';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D2 FAILED: %', SQLERRM;
END $$;

-- D3: CREATE TABLE IF NOT EXISTS (table ALREADY EXISTS) - must be a safe no-op
DO $$
BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS sk2_ext_test.ifnotexists_y (
        naam text,
        geom geometry(Polygon, 3007)
    )';
    RAISE NOTICE 'TEST D3 PASSED: CREATE TABLE IF NOT EXISTS on existing table is a safe no-op';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D3 FAILED: Existing-table IF NOT EXISTS caused error: %', SQLERRM;
END $$;

-- D4: CREATE TABLE LIKE - copies column structure, must be restructured by Hex
CREATE TABLE sk2_ext_test.fororeningar_kopia_y
    (LIKE sk2_ext_test.fororeningar_y);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_kopia_y'
        AND column_name = 'gid'
    )
    AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk2_ext_test' AND tablename = 'fororeningar_kopia_y'
        AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST D4 PASSED: CREATE TABLE LIKE is restructured correctly (gid + GiST index)';
    ELSE
        RAISE WARNING 'TEST D4 FAILED: CREATE TABLE LIKE not restructured (missing gid or GiST index)';
    END IF;
END $$;

-- D5: ALTER TABLE RENAME TO - hantera_kolumntillagg fires on the NEW name.
--     The history table keeps the OLD name -> becomes orphaned.
CREATE TABLE sk2_kba_test.rename_src_y (
    info text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h'
    ) THEN
        RAISE NOTICE 'TEST D5a PASSED: History table rename_src_y_h exists before rename';
    ELSE
        RAISE WARNING 'TEST D5a FAILED: No history table before rename test';
    END IF;
END $$;

ALTER TABLE sk2_kba_test.rename_src_y RENAME TO rename_dst_y;

DO $$
DECLARE
    dst_exists  boolean;
    src_gone    boolean;
    old_hist    boolean;
    new_hist    boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y')  INTO dst_exists;
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y') INTO src_gone;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h') INTO old_hist;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y_h') INTO new_hist;

    IF dst_exists AND src_gone AND old_hist AND NOT new_hist THEN
        RAISE WARNING 'TEST D5b BUG CONFIRMED: After RENAME TO, history table rename_src_y_h is ORPHANED. Parent rename_src_y no longer exists. DROP TABLE rename_dst_y will NOT clean up rename_src_y_h.';
    ELSIF dst_exists AND src_gone AND NOT old_hist AND NOT new_hist THEN
        RAISE NOTICE 'TEST D5b INFO: Rename succeeded, no history table orphan (no kba history was created)';
    ELSIF dst_exists AND src_gone AND new_hist THEN
        RAISE NOTICE 'TEST D5b PASSED: After rename, history table was renamed too (unexpected bonus)';
    ELSE
        RAISE WARNING 'TEST D5b UNEXPECTED STATE: dst=% src_gone=% old_hist=% new_hist=%',
            dst_exists, src_gone, old_hist, new_hist;
    END IF;
END $$;

-- After fix: DROP TABLE on renamed table should clean up rename_dst_y_h via OID lookup
DROP TABLE IF EXISTS sk2_kba_test.rename_dst_y;

DO $$
DECLARE
    old_h_gone boolean;
    new_h_gone boolean;
BEGIN
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_src_y_h') INTO old_h_gone;
    SELECT NOT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'rename_dst_y_h') INTO new_h_gone;

    IF old_h_gone AND new_h_gone THEN
        RAISE NOTICE 'TEST D5c PASSED: Both history table names cleaned up after DROP TABLE rename_dst_y (hex_metadata OID lookup worked)';
    ELSIF NOT old_h_gone THEN
        RAISE WARNING 'TEST D5c BUG: rename_src_y_h still exists (was never renamed - RENAME handling did not fire)';
    ELSIF NOT new_h_gone THEN
        RAISE WARNING 'TEST D5c BUG: rename_dst_y_h was NOT cleaned up on DROP TABLE (OID lookup in hantera_borttagen_tabell failed)';
    END IF;
END $$;

-- D6: ALTER TABLE ADD COLUMN then DROP COLUMN (user column) - no orphan temp columns
CREATE TABLE sk2_kba_test.dropcol_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_kba_test.dropcol_test_y ADD COLUMN temp_col text;
ALTER TABLE sk2_kba_test.dropcol_test_y DROP COLUMN temp_col;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'dropcol_test_y'
    AND column_name LIKE '%_temp0001';

    IF orphan_count = 0 THEN
        RAISE NOTICE 'TEST D6 PASSED: DROP COLUMN on user column leaves no orphaned _temp0001 columns';
    ELSE
        RAISE WARNING 'TEST D6 FAILED: % orphaned _temp0001 column(s) after DROP user column', orphan_count;
    END IF;
END $$;

-- D7: DROP a STANDARD column - the column mover adds temp then fails -> orphaned _temp0001
--     This is the bug where hantera_kolumntillagg has no pre-existence check.
ALTER TABLE sk2_kba_test.dropcol_test_y DROP COLUMN IF EXISTS andrad_tidpunkt;

DO $$
DECLARE orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'dropcol_test_y'
    AND column_name LIKE '%_temp0001';

    IF orphan_count > 0 THEN
        RAISE WARNING 'TEST D7 BUG CONFIRMED: Dropping a standard column (andrad_tidpunkt) leaves % orphaned _temp0001 column(s) in the table. The column mover has no pre-existence guard: it adds the temp column (step 1 succeeds) before discovering the original is gone (step 2 fails). The EXCEPTION block catches the error but does not roll back the already-created temp column.', orphan_count;
    ELSE
        RAISE NOTICE 'TEST D7 PASSED: No orphan _temp0001 columns after dropping standard column (pre-existence guard works)';
    END IF;
END $$;

-- D8: Multiple ADD COLUMNs in one ALTER TABLE statement (one DDL event, one trigger call)
CREATE TABLE sk2_ext_test.multi_add_y (
    naam text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk2_ext_test.multi_add_y
    ADD COLUMN kolumn_a text,
    ADD COLUMN kolumn_b integer,
    ADD COLUMN kolumn_c boolean;

DO $$
DECLARE
    col_count  integer;
    geom_pos   integer;
    last_pos   integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y'
    AND column_name IN ('kolumn_a', 'kolumn_b', 'kolumn_c');

    SELECT ordinal_position INTO geom_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO last_pos FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'multi_add_y';

    IF col_count = 3 AND geom_pos = last_pos THEN
        RAISE NOTICE 'TEST D8 PASSED: Multi-ADD COLUMN: all 3 new columns present, geom still last (pos %/%)', geom_pos, last_pos;
    ELSE
        RAISE WARNING 'TEST D8 FAILED: col_count=% (expected 3), geom_pos=% last_pos=%',
            col_count, geom_pos, last_pos;
    END IF;
END $$;

-- D9: 61-character table name -> Hex validera_tabell max is 54 chars, so this gets
--     rejected before PostgreSQL's 63-char identifier limit is ever reached.
DO $$
DECLARE
    tname text := repeat('a', 59) || '_y';   -- 61 chars
BEGIN
    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tname
    );
    -- If we get here, Hex allowed it - check for history table
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = tname || '_h'
    ) THEN
        RAISE NOTICE 'TEST D9 PASSED: 61-char table name allowed and history table created';
    ELSE
        RAISE WARNING 'TEST D9 FAILED: 61-char table allowed but no history table created';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%för långt%' OR SQLERRM LIKE '%too long%' THEN
            RAISE NOTICE 'TEST D9 INFO: 61-char table name rejected by Hex name length guard (max 54 chars). PostgreSQL''s 63-char identifier limit not reached.';
        ELSE
            RAISE WARNING 'TEST D9 FAILED: Unexpected error: %', SQLERRM;
        END IF;
END $$;

-- D10: 62-character table name -> same Hex limit applies (max 54 chars).
DO $$
DECLARE
    tname text := repeat('b', 60) || '_y';  -- 62 chars
BEGIN
    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tname
    );
    -- If allowed, check whether PostgreSQL truncated the 64-char history name to 63
    DECLARE
        intended_hname  text := tname || '_h';        -- 64 chars
        truncated_hname text := left(tname || '_h', 63); -- 63 chars
    BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'sk2_kba_test' AND table_name = truncated_hname)
           AND truncated_hname != intended_hname THEN
            RAISE WARNING 'TEST D10 BUG CONFIRMED: 62-char name causes history table truncation. Intended "%" -> actual "%" (trailing h dropped -> orphan on DROP TABLE).', intended_hname, truncated_hname;
        ELSE
            RAISE NOTICE 'TEST D10 PASSED: 62-char history table name not truncated';
        END IF;
    END;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%för långt%' OR SQLERRM LIKE '%too long%' THEN
            RAISE NOTICE 'TEST D10 INFO: 62-char table name rejected by Hex name length guard (max 54 chars). PostgreSQL''s identifier truncation not reached.';
        ELSE
            RAISE WARNING 'TEST D10 FAILED: Unexpected error: %', SQLERRM;
        END IF;
END $$;

-- D11: _h bypass - cleverly named table to skip restructuring
--      A table ending in _h where the parent (stripped name) does NOT exist gets blocked.
--      A table ending in _h where the parent DOES exist passes through unmodified.
--      This means _h tables always bypass Hex entirely - deliberate but worth confirming.
CREATE TABLE sk2_ext_test.sneaky_bypass_y (
    naam text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    -- A table named parent_y_h (not sneaky_h) is not blocked since parent_y exists
    EXECUTE 'CREATE TABLE sk2_ext_test.sneaky_bypass_y_h (
        h_typ char(1), h_tidpunkt timestamptz, gid integer, naam text, geom geometry
    )';
    -- _h tables bypass restructuring - this table has no Hex standard columns added
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_ext_test' AND table_name = 'sneaky_bypass_y_h'
        AND column_name = 'skapad_tidpunkt'
    ) THEN
        RAISE NOTICE 'TEST D11 PASSED: _h tables bypass Hex restructuring (no standard columns added). This is intentional - history tables keep their own schema.';
    ELSE
        RAISE WARNING 'TEST D11 UNEXPECTED: _h table got standard columns added (restructuring not bypassed)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST D11: _h table creation raised exception: %', left(SQLERRM, 80);
END $$;

-- D12: CREATE SCHEMA IF NOT EXISTS on already-existing schema - must be safe no-op
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS sk2_ext_test';
    RAISE NOTICE 'TEST D12 PASSED: CREATE SCHEMA IF NOT EXISTS on existing schema is safe no-op';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST D12 FAILED: CREATE SCHEMA IF NOT EXISTS caused error: %', SQLERRM;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

\echo ''
\echo 'HEX EXTENDED C & D COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
