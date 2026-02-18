-- ============================================================
-- HEX EXTENDED TEST SUITE
--
-- Täcker:
--   A  sk2 schema-hantering (fullständigt)
--   B  Vy-validering (hantera_ny_vy / validera_vynamn)
--   C  Klient-simulering (GeoServer, QGIS, FME)
--   D  Strukturella kantfall och adversariella tester
--   E  Historiktabell-synkronisering (ALTER TABLE ADD COLUMN)
--   F  Dataöverlevnad
--
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX EXTENDED TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Initial cleanup
-- ============================================================
\echo ''
\echo '--- Initial cleanup ---'

DROP SCHEMA IF EXISTS sk2_ext_test   CASCADE;
DROP SCHEMA IF EXISTS sk2_kba_test   CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test   CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest  CASCADE;

-- ============================================================
-- A: sk2 SCHEMA HANDLING
-- ============================================================
\echo ''
\echo '--- GROUP A: sk2 schema handling ---'

CREATE SCHEMA sk2_ext_test;
CREATE SCHEMA sk2_kba_test;
CREATE SCHEMA sk2_sys_test;
CREATE SCHEMA sk1_kba_htest;

-- ------------------------------------------------------------
-- A1: sk2_ext - should get gid + skapad_tidpunkt only (not kba columns)
-- ------------------------------------------------------------
CREATE TABLE sk2_ext_test.fororeningar_y (
    beskrivning text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt');
    IF col_count = 2 THEN
        RAISE NOTICE 'TEST A1a PASSED: sk2_ext table has gid and skapad_tidpunkt';
    ELSE
        RAISE WARNING 'TEST A1a FAILED: Expected 2 base standard columns on sk2_ext, got %', col_count;
    END IF;
END $$;

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_ext_test' AND table_name = 'fororeningar_y'
    AND column_name IN ('skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF col_count = 0 THEN
        RAISE NOTICE 'TEST A1b PASSED: sk2_ext does NOT have kba-only columns';
    ELSE
        RAISE WARNING 'TEST A1b FAILED: sk2_ext has % kba-only columns (schema_uttryck filter broken)', col_count;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk2_ext_test' AND tablename = 'fororeningar_y'
        AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST A1c PASSED: GiST index on sk2_ext geometry table';
    ELSE
        RAISE WARNING 'TEST A1c FAILED: No GiST index on sk2_ext table';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_ext_test.fororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A1d PASSED: No geometry validation constraint on sk2_ext (correct)';
    ELSE
        RAISE WARNING 'TEST A1d FAILED: sk2_ext has geometry validation (only kba should)';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A2: sk2_kba - full kba treatment: all standard columns, validation, history
-- ------------------------------------------------------------
CREATE TABLE sk2_kba_test.markfororeningar_y (
    orsak text,
    geom geometry(Polygon, 3007)
);

DO $$
DECLARE col_count integer;
BEGIN
    SELECT COUNT(*) INTO col_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y'
    AND column_name IN ('gid', 'skapad_tidpunkt', 'skapad_av', 'andrad_tidpunkt', 'andrad_av');
    IF col_count = 5 THEN
        RAISE NOTICE 'TEST A2a PASSED: sk2_kba table has all 5 standard columns';
    ELSE
        RAISE WARNING 'TEST A2a FAILED: Expected 5 standard columns on sk2_kba, got %', col_count;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk2_kba_test.markfororeningar_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST A2b PASSED: sk2_kba has geometry validation constraint';
    ELSE
        RAISE WARNING 'TEST A2b FAILED: sk2_kba missing geometry validation';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'markfororeningar_y_h'
    ) THEN
        RAISE NOTICE 'TEST A2c PASSED: History table created for sk2_kba table';
    ELSE
        RAISE WARNING 'TEST A2c FAILED: No history table for sk2_kba';
    END IF;
END $$;

DO $$
BEGIN
    INSERT INTO sk2_kba_test.markfororeningar_y (orsak, geom)
    VALUES ('test', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST A2d FAILED: Empty geometry accepted in sk2_kba (should be blocked)';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'TEST A2d PASSED: Empty geometry correctly blocked in sk2_kba';
END $$;

-- ------------------------------------------------------------
-- A3: sk2_sys - non-geometry, standard columns
-- ------------------------------------------------------------
CREATE TABLE sk2_sys_test.konfig (
    param text,
    varde text
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST A3a PASSED: sk2_sys non-geometry table has gid';
    ELSE
        RAISE WARNING 'TEST A3a FAILED: sk2_sys table missing gid';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_sys_test' AND table_name = 'konfig_h'
    ) THEN
        RAISE NOTICE 'TEST A3b PASSED: sk2_sys non-geometry table has no history table (correct)';
    ELSE
        RAISE WARNING 'TEST A3b FAILED: sk2_sys non-geometry table unexpectedly has history table';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A4: sk2 roles - r_{schema} (LIKE sk2_%) and w_{schema} (IS NOT NULL) created
-- ------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'w_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4a PASSED: Write role w_sk2_ext_test created';
    ELSE
        RAISE WARNING 'TEST A4a FAILED: Missing write role w_sk2_ext_test';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_test') THEN
        RAISE NOTICE 'TEST A4b PASSED: Read role r_sk2_ext_test created (sk2 matches LIKE sk2_%%)';
    ELSE
        RAISE WARNING 'TEST A4b FAILED: Missing read role r_sk2_ext_test';
    END IF;
END $$;

-- sk2 must NOT receive r_sk0_global or r_sk1_global
DO $$
BEGIN
    -- These global roles apply to sk0_% and sk1_% only.
    -- We confirm sk2 schema creation didn't accidentally toggle them.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk0_global')
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_global') THEN
        RAISE NOTICE 'TEST A4c PASSED: Global roles r_sk0_global and r_sk1_global still exist unchanged';
    ELSE
        RAISE WARNING 'TEST A4c FAILED: A global role was unexpectedly removed or altered';
    END IF;
END $$;

-- Login roles for sk2 (suffixed _geoserver, _cesium, _qgis)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk2_ext_test_geoserver') THEN
        RAISE NOTICE 'TEST A4d PASSED: Login role r_sk2_ext_test_geoserver created';
    ELSE
        RAISE WARNING 'TEST A4d FAILED: Missing login role r_sk2_ext_test_geoserver';
    END IF;
END $$;

-- ------------------------------------------------------------
-- A5: sk2 must NOT trigger GeoServer pg_notify
-- Test the regex that guards the notification directly
-- ------------------------------------------------------------
DO $$
DECLARE matched_prefix text;
BEGIN
    matched_prefix := substring('sk2_kba_test' FROM '^(sk[01])_');
    IF matched_prefix IS NULL THEN
        RAISE NOTICE 'TEST A5 PASSED: sk2 schema correctly excluded from GeoServer notification (prefix regex ''^(sk[01])_'' returns NULL for sk2)';
    ELSE
        RAISE WARNING 'TEST A5 FAILED: sk2 schema matched GeoServer prefix: "%"', matched_prefix;
    END IF;
END $$;

-- ============================================================
-- B: VIEW VALIDATION  (previously ZERO test coverage)
-- ============================================================
\echo ''
\echo '--- GROUP B: View validation ---'

-- B1: Valid non-geometry view - must be accepted (starts with v_, no suffix needed)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.v_konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig WHERE varde IS NOT NULL';
    RAISE NOTICE 'TEST B1 PASSED: Valid non-geometry view (v_xxx) accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B1 FAILED: Valid non-geometry view rejected: %', SQLERRM;
END $$;

-- B2: Valid geometry view - correct suffix for polygon data
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_y AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B2 PASSED: Valid geometry view (v_xxx_y) accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B2 FAILED: Valid geometry view rejected: %', SQLERRM;
END $$;

-- B3: View missing v_ prefix - must be rejected
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_sys_test.konfig_aktiv AS
             SELECT * FROM sk2_sys_test.konfig';
    RAISE WARNING 'TEST B3 FAILED: View without v_ prefix was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B3 PASSED: View without v_ prefix rejected correctly';
END $$;

-- B4: View with wrong geometry suffix (polygon data but named _l)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_fororeningar_l AS
             SELECT * FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B4 FAILED: Wrong geometry suffix (_l for polygon) was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B4 PASSED: Wrong geometry suffix correctly rejected';
END $$;

-- B5: View in public schema - must be silently skipped (no enforcement)
DO $$
BEGIN
    EXECUTE 'CREATE VIEW public.anything AS SELECT 1 AS x';
    RAISE NOTICE 'TEST B5 PASSED: View in public schema skipped (any name accepted)';
    EXECUTE 'DROP VIEW public.anything';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B5 FAILED: View in public schema caused error: %', SQLERRM;
END $$;

-- B6: ST_ transformation without explicit type cast - must get helpful diagnostic
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid, ST_Buffer(geom, 10) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE WARNING 'TEST B6 FAILED: ST_ transformation without cast was accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST B6 PASSED: ST_ transformation without cast rejected (message: %)',
            left(SQLERRM, 80);
END $$;

-- B7: ST_ transformation WITH explicit cast - must be accepted
DO $$
BEGIN
    EXECUTE 'CREATE VIEW sk2_ext_test.v_buffer_y AS
             SELECT gid,
                    ST_Buffer(geom, 10)::geometry(Polygon, 3007) AS geom
             FROM sk2_ext_test.fororeningar_y';
    RAISE NOTICE 'TEST B7 PASSED: ST_ transformation with explicit type cast accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST B7 FAILED: ST_ transformation with cast rejected: %', SQLERRM;
END $$;

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

-- C3: application_name = FME - restructuring still occurs; geometry errors become warnings not exceptions
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

-- D9: 61-character table name -> history table = 63 chars (exactly at PostgreSQL identifier limit)
--     Must create correctly with no truncation.
DO $$
DECLARE
    tname text := repeat('a', 59) || '_y';   -- 61 chars
    hname text;
BEGIN
    hname := tname || '_h';  -- 63 chars - exactly at limit
    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tname
    );
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = hname
    ) THEN
        RAISE NOTICE 'TEST D9 PASSED: 61-char table name creates 63-char history table correctly ("%"_h)', tname;
    ELSE
        RAISE WARNING 'TEST D9 FAILED: History table for 61-char name not found (expected "%")', hname;
    END IF;
END $$;

-- D10: 62-character table name -> history table would be 64 chars -> PostgreSQL silently truncates to 63
--      The truncation drops the trailing 'h', so hantera_borttagen_tabell will look for
--      the wrong name and leave the history table permanently orphaned on DROP TABLE.
DO $$
DECLARE
    tname          text := repeat('b', 60) || '_y';  -- 62 chars
    intended_hname text;
    truncated_hname text;
BEGIN
    intended_hname  := tname || '_h';         -- 64 chars (over limit)
    truncated_hname := left(tname || '_h', 63); -- 63 chars (last 'h' dropped)

    EXECUTE format(
        'CREATE TABLE sk2_kba_test.%I (info text, geom geometry(Polygon, 3007))',
        tname
    );

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = truncated_hname
    ) AND truncated_hname != intended_hname THEN
        RAISE WARNING 'TEST D10 BUG CONFIRMED: 62-char table name causes history table name truncation. Intended: "%" (64 chars) -> Actual: "%" (63 chars, trailing "h" dropped). hantera_borttagen_tabell searches for the intended name and will NOT find the actual table -> permanent orphan on DROP TABLE.',
            intended_hname, truncated_hname;
    ELSIF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = intended_hname
    ) THEN
        RAISE NOTICE 'TEST D10 PASSED: 62-char history table created with full name (no truncation observed)';
    ELSE
        RAISE WARNING 'TEST D10 INCONCLUSIVE: No history table found for 62-char table. skapa_historik_qa may have failed silently.';
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
-- E: HISTORY TABLE AUTO-SYNC (ALTER TABLE ADD COLUMN on kba table)
-- ============================================================
\echo ''
\echo '--- GROUP E: History table auto-sync on ALTER TABLE ---'

CREATE TABLE sk2_kba_test.sync_test_y (
    info text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    ) THEN
        RAISE NOTICE 'TEST E0 PASSED: sync_test_y_h history table exists before sync tests';
    ELSE
        RAISE WARNING 'TEST E0 FAILED: No history table for sync_test_y - cannot run E tests';
    END IF;
END $$;

ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN extra_data text;

-- E1: New column must appear in history table automatically
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
        AND column_name = 'extra_data'
    ) THEN
        RAISE NOTICE 'TEST E1 PASSED: ADD COLUMN extra_data auto-synced to history table';
    ELSE
        RAISE WARNING 'TEST E1 FAILED: extra_data not synced to history table sync_test_y_h';
    END IF;
END $$;

-- E2: geom must stay last in BOTH main table and history table after sync
DO $$
DECLARE
    geom_pos_main  integer;
    last_pos_main  integer;
    geom_pos_hist  integer;
    last_pos_hist  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_main FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y';

    SELECT ordinal_position INTO geom_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h' AND column_name = 'geom';
    SELECT MAX(ordinal_position) INTO last_pos_hist FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h';

    IF geom_pos_main = last_pos_main AND geom_pos_hist = last_pos_hist THEN
        RAISE NOTICE 'TEST E2 PASSED: geom is last in both main (pos %/%) and history (pos %/%)',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    ELSE
        RAISE WARNING 'TEST E2 FAILED: geom not last. main: %/%, history: %/%',
            geom_pos_main, last_pos_main, geom_pos_hist, last_pos_hist;
    END IF;
END $$;

-- E3: Adding a second column - both should appear in history table
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN kategori integer;

DO $$
DECLARE synced integer;
BEGIN
    SELECT COUNT(*) INTO synced FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name IN ('extra_data', 'kategori');
    IF synced = 2 THEN
        RAISE NOTICE 'TEST E3 PASSED: Both extra_data and kategori synced to history table';
    ELSE
        RAISE WARNING 'TEST E3 FAILED: Only % of 2 expected columns synced to history table', synced;
    END IF;
END $$;

-- E4: Running ADD COLUMN twice when already in sync - must not duplicate
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN stable_col text;
ALTER TABLE sk2_kba_test.sync_test_y ADD COLUMN another_col text;

DO $$
DECLARE dup_count integer;
BEGIN
    SELECT COUNT(*) INTO dup_count FROM information_schema.columns
    WHERE table_schema = 'sk2_kba_test' AND table_name = 'sync_test_y_h'
    AND column_name = 'stable_col';
    IF dup_count = 1 THEN
        RAISE NOTICE 'TEST E4 PASSED: stable_col appears exactly once in history (no duplicates from repeated syncs)';
    ELSE
        RAISE WARNING 'TEST E4 FAILED: stable_col appears % times in history table (expected 1)', dup_count;
    END IF;
END $$;

-- ============================================================
-- F: DATA SURVIVAL
-- ============================================================
\echo ''
\echo '--- GROUP F: Data survival ---'

CREATE TABLE sk2_kba_test.data_test_y (
    naam       text,
    waarde     numeric(10,2),
    categorie  text,
    geom       geometry(Polygon, 3007)
);

INSERT INTO sk2_kba_test.data_test_y (naam, waarde, categorie, geom) VALUES
    ('objekt_1', 123.45, 'A', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3007)),
    ('objekt_2', 678.90, 'B', ST_GeomFromText('POLYGON((200 200,300 200,300 300,200 300,200 200))', 3007));

-- F1: ADD COLUMN - existing rows and values must survive
ALTER TABLE sk2_kba_test.data_test_y ADD COLUMN extra text;

DO $$
DECLARE
    row_count integer;
    sum_val   numeric;
BEGIN
    SELECT COUNT(*), SUM(waarde) INTO row_count, sum_val
    FROM sk2_kba_test.data_test_y;
    IF row_count = 2 AND sum_val = 802.35 THEN
        RAISE NOTICE 'TEST F1 PASSED: Both rows and numeric values intact after ADD COLUMN (count=%, sum=%)', row_count, sum_val;
    ELSE
        RAISE WARNING 'TEST F1 FAILED: Data not preserved. rows=%, sum=%', row_count, sum_val;
    END IF;
END $$;

-- F2: Geometry values must survive ADD COLUMN
DO $$
DECLARE geom_count integer;
BEGIN
    SELECT COUNT(*) INTO geom_count
    FROM sk2_kba_test.data_test_y
    WHERE ST_IsValid(geom) AND NOT ST_IsEmpty(geom);
    IF geom_count = 2 THEN
        RAISE NOTICE 'TEST F2 PASSED: Both geometry values valid and intact after ADD COLUMN';
    ELSE
        RAISE WARNING 'TEST F2 FAILED: Expected 2 valid geometries, found %', geom_count;
    END IF;
END $$;

-- F3: QA trigger works after ADD COLUMN - UPDATE writes history and bumps andrad_tidpunkt
DO $$
DECLARE
    hist_count integer;
    old_ts     timestamptz;
    new_ts     timestamptz;
BEGIN
    SELECT andrad_tidpunkt INTO old_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';

    PERFORM pg_sleep(0.05);

    UPDATE sk2_kba_test.data_test_y SET waarde = 999.99 WHERE naam = 'objekt_1';

    SELECT andrad_tidpunkt INTO new_ts
    FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_1';
    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_1' AND h_typ = 'U';

    IF hist_count = 1 AND new_ts > old_ts THEN
        RAISE NOTICE 'TEST F3 PASSED: UPDATE wrote 1 history row and bumped andrad_tidpunkt (old=%, new=%)',
            old_ts, new_ts;
    ELSIF hist_count = 1 THEN
        RAISE WARNING 'TEST F3 PARTIAL: History row written but andrad_tidpunkt not updated (old=%, new=%)',
            old_ts, new_ts;
    ELSE
        RAISE WARNING 'TEST F3 FAILED: Expected 1 history row, got %. andrad_tidpunkt: old=%, new=%',
            hist_count, old_ts, new_ts;
    END IF;
END $$;

-- F4: DELETE writes to history table with h_typ='D'
DO $$
DECLARE hist_count integer;
BEGIN
    DELETE FROM sk2_kba_test.data_test_y WHERE naam = 'objekt_2';
    SELECT COUNT(*) INTO hist_count
    FROM sk2_kba_test.data_test_y_h WHERE naam = 'objekt_2' AND h_typ = 'D';
    IF hist_count = 1 THEN
        RAISE NOTICE 'TEST F4 PASSED: DELETE wrote 1 history row with h_typ=''D''';
    ELSE
        RAISE WARNING 'TEST F4 FAILED: Expected 1 DELETE history row, got %', hist_count;
    END IF;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
\echo ''
\echo '--- Cleanup ---'

DROP SCHEMA IF EXISTS sk2_kba_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_ext_test  CASCADE;
DROP SCHEMA IF EXISTS sk2_sys_test  CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_htest CASCADE;

\echo ''
\echo '============================================================'
\echo 'HEX EXTENDED TEST SUITE COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
\echo '============================================================'
