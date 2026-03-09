-- ============================================================
-- HEX EDGE CASE TEST SUITE — GROUPS H, I, J, K, L, M & N
--
-- H  CREATE TABLE variations
--    H1  CREATE TEMP TABLE with geometry suffix (ignored by Hex)
--    H2  Inline CHECK constraint survives Hex restructuring
--    H3  Inline UNIQUE constraint survives Hex restructuring
--    H4  Inline FOREIGN KEY survives Hex restructuring
--    H5  CREATE TABLE ... INHERITS (child table handling)
--    H6  MultiPoint geometry with _p suffix
--    H7  MultiLineString geometry with _l suffix
--    H8  GeometryCollection geometry with _g suffix
--
-- I  ALTER TABLE variations
--    I1  RENAME COLUMN (non-geometry) + history table sync
--    I2  ALTER COLUMN TYPE (non-geometry cast)
--    I3  ALTER COLUMN TYPE on geom (SRID change via USING)
--    I4  ADD CONSTRAINT CHECK (user-defined, post-creation)
--    I5  ADD CONSTRAINT UNIQUE (user-defined, post-creation)
--    I6  DROP CONSTRAINT (user-defined)
--    I7  SET SCHEMA (table moved between schema types)
--
-- J  Schema naming edge cases
--    J1  sk0_sys_* schema treatment
--    J2  sk1_sys_* schema treatment
--    J3  sk3_* schema (beyond standard range)
--    J4  Non-matching schema name (partial pattern, no Hex enforcement)
--
-- K  User-issued index DDL
--    K1  CREATE INDEX (B-tree) on Hex-managed table
--    K2  CREATE UNIQUE INDEX on Hex-managed table
--    K3  DROP INDEX on Hex-created GiST index
--
-- L  DROP variations
--    L1  DROP TABLE CASCADE (removes dependent view)
--    L2  DROP SCHEMA without CASCADE on non-empty schema (must error)
--
-- M  TRUNCATE variations
--    M1  TRUNCATE basic (row triggers do not fire, history unaffected)
--    M2  TRUNCATE RESTART IDENTITY
--    M3  TRUNCATE CASCADE
--
-- N  Materialized views
--    N1  CREATE MATERIALIZED VIEW with valid v_ prefix
--    N2  CREATE MATERIALIZED VIEW without v_ prefix
--    N3  REFRESH MATERIALIZED VIEW
--    N4  DROP MATERIALIZED VIEW
--
-- Schemas used: sk1_kba_edge, sk0_ext_edge, sk0_sys_edge, sk1_sys_edge, sk3_ext_edge
-- Convention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX EDGE CASE TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Cleanup and setup
-- ============================================================
DROP SCHEMA  IF EXISTS sk1_kba_edge    CASCADE;
DROP SCHEMA  IF EXISTS sk0_ext_edge    CASCADE;
DROP SCHEMA  IF EXISTS sk0_sys_edge    CASCADE;
DROP SCHEMA  IF EXISTS sk1_sys_edge    CASCADE;
DROP SCHEMA  IF EXISTS sk3_ext_edge    CASCADE;
DROP SCHEMA  IF EXISTS sk0ext_partial  CASCADE;
DROP TABLE   IF EXISTS public.hex_edge_ref CASCADE;

CREATE SCHEMA sk1_kba_edge;
CREATE SCHEMA sk0_ext_edge;

-- Reference table in public for FK tests (not Hex-managed)
CREATE TABLE public.hex_edge_ref (id integer PRIMARY KEY);

-- ============================================================
-- H: CREATE TABLE VARIATIONS
-- ============================================================
\echo ''
\echo '--- GROUP H: CREATE TABLE variations ---'

-- H1: CREATE TEMP TABLE with geometry suffix - Hex must ignore pg_temp schema
DO $$
BEGIN
    EXECUTE 'CREATE TEMP TABLE tmp_hex_edge_y (naam text, geom geometry(Polygon, 3007))';

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname LIKE 'pg_temp%'
          AND c.relname = 'tmp_hex_edge_y'
          AND a.attname = 'gid'
          AND a.attnum > 0 AND NOT a.attisdropped
    ) THEN
        RAISE NOTICE 'TEST H1 PASSED: TEMP TABLE correctly ignored by Hex (no gid added to pg_temp table)';
    ELSE
        RAISE WARNING 'TEST H1 FAILED: Hex restructured a TEMP TABLE in pg_temp (gid found)';
    END IF;

    EXECUTE 'DROP TABLE IF EXISTS tmp_hex_edge_y';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltigt tabellnamn%pg_temp%'
        OR SQLERRM LIKE '%invalid table name%pg_temp%' THEN
            RAISE WARNING 'TEST H1 BUG CONFIRMED: Hex event trigger fires on TEMP TABLE and errors (validera_tabell rejects pg_temp.* name). TEMP TABLE creation in a managed schema fails entirely. Error: %', left(SQLERRM, 120);
        ELSE
            RAISE WARNING 'TEST H1 FAILED: TEMP TABLE caused unexpected error: %', SQLERRM;
        END IF;
END $$;

-- H2: Inline CHECK constraint - must survive byt_ut_tabell restructuring
CREATE TABLE sk1_kba_edge.checked_y (
    category text    CHECK (category IN ('A', 'B', 'C')),
    score    integer CHECK (score BETWEEN 0 AND 100),
    geom     geometry(Polygon, 3007)
);

DO $$
DECLARE user_check_count integer;
BEGIN
    SELECT COUNT(*) INTO user_check_count
    FROM pg_constraint
    WHERE conrelid = 'sk1_kba_edge.checked_y'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) NOT LIKE '%validera_geometri%';

    IF user_check_count >= 2 THEN
        RAISE NOTICE 'TEST H2 PASSED: % user CHECK constraint(s) survived Hex restructuring', user_check_count;
    ELSIF user_check_count = 1 THEN
        RAISE WARNING 'TEST H2 PARTIAL: Only 1 of 2 user CHECK constraints survived byt_ut_tabell';
    ELSE
        RAISE WARNING 'TEST H2 FAILED: User CHECK constraints lost during Hex restructuring (byt_ut_tabell does not preserve them)';
    END IF;
END $$;

-- H3: Inline UNIQUE constraint - must survive byt_ut_tabell restructuring
CREATE TABLE sk0_ext_edge.unique_test_y (
    kodnummer text UNIQUE,
    geom      geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.unique_test_y'::regclass
          AND contype = 'u'
    ) THEN
        RAISE NOTICE 'TEST H3 PASSED: UNIQUE constraint survived Hex restructuring';
    ELSE
        RAISE WARNING 'TEST H3 FAILED: UNIQUE constraint lost during Hex restructuring (byt_ut_tabell does not preserve it)';
    END IF;
END $$;

-- H4: Inline FOREIGN KEY - must survive byt_ut_tabell restructuring
CREATE TABLE sk0_ext_edge.fk_test_y (
    ref_id integer REFERENCES public.hex_edge_ref(id),
    geom   geometry(Polygon, 3007)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.fk_test_y'::regclass
          AND contype = 'f'
    ) THEN
        RAISE NOTICE 'TEST H4 PASSED: FOREIGN KEY constraint survived Hex restructuring';
    ELSE
        RAISE WARNING 'TEST H4 FAILED: FOREIGN KEY constraint lost during Hex restructuring (byt_ut_tabell does not preserve it)';
    END IF;
END $$;

-- H5: CREATE TABLE ... INHERITS (child inherits from Hex-managed parent)
CREATE TABLE sk0_ext_edge.parent_base_y (
    naam text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.child_base_y (extra text) INHERITS (sk0_ext_edge.parent_base_y)';

    -- Check if child has a directly-owned gid (attinhcount = 0 means not inherited)
    IF EXISTS (
        SELECT 1 FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_edge' AND c.relname = 'child_base_y'
          AND a.attname = 'gid' AND a.attinhcount = 0
          AND a.attnum > 0 AND NOT a.attisdropped
    ) THEN
        RAISE NOTICE 'TEST H5 PASSED: INHERITS child has its own gid (Hex restructured child independently)';
    ELSE
        RAISE NOTICE 'TEST H5 INFO: INHERITS child does not have its own gid (inherits from parent or Hex skips inherited tables)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H5 INFO: INHERITS caused: %', left(SQLERRM, 100);
END $$;

-- H6: MultiPoint geometry with _p suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.multipoint_p (naam text, geom geometry(MultiPoint, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'multipoint_p'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H6 PASSED: MultiPoint with _p suffix accepted and GiST index created';
    ELSE
        RAISE WARNING 'TEST H6 FAILED: MultiPoint table created but no GiST index (suffix type check may have rejected it)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H6 INFO: MultiPoint + _p suffix rejected by Hex: %', left(SQLERRM, 100);
END $$;

-- H7: MultiLineString geometry with _l suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.multiline_l (naam text, geom geometry(MultiLineString, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'multiline_l'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H7 PASSED: MultiLineString with _l suffix accepted and GiST index created';
    ELSE
        RAISE WARNING 'TEST H7 FAILED: MultiLineString table created but no GiST index';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H7 INFO: MultiLineString + _l suffix rejected by Hex: %', left(SQLERRM, 100);
END $$;

-- H8: GeometryCollection geometry with _g suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.collection_g (naam text, geom geometry(GeometryCollection, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'collection_g'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H8 PASSED: GeometryCollection with _g suffix accepted and GiST index created';
    ELSE
        RAISE WARNING 'TEST H8 FAILED: GeometryCollection table created but no GiST index';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H8 INFO: GeometryCollection + _g suffix rejected by Hex: %', left(SQLERRM, 100);
END $$;

-- ============================================================
-- I: ALTER TABLE VARIATIONS
-- ============================================================
\echo ''
\echo '--- GROUP I: ALTER TABLE variations ---'

-- I-setup: fresh kba table for ALTER tests
CREATE TABLE sk1_kba_edge.alter_target_y (
    old_naam text,
    waarde   integer,
    geom     geometry(Polygon, 3007)
);

-- I1: RENAME COLUMN (non-geometry) - verify main table and history table sync
ALTER TABLE sk1_kba_edge.alter_target_y RENAME COLUMN old_naam TO new_naam;

DO $$
DECLARE
    main_ok boolean;
    hist_ok boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y'
          AND column_name = 'new_naam'
    ) INTO main_ok;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y_h'
          AND column_name = 'new_naam'
    ) INTO hist_ok;

    IF main_ok AND hist_ok THEN
        RAISE NOTICE 'TEST I1 PASSED: RENAME COLUMN reflected in both main table and history table';
    ELSIF main_ok AND NOT hist_ok THEN
        RAISE WARNING 'TEST I1 BUG: RENAME COLUMN applied to main table but history table still has old column name (history sync does not track renames)';
    ELSE
        RAISE WARNING 'TEST I1 FAILED: Renamed column not found in main table';
    END IF;
END $$;

-- I2: ALTER COLUMN TYPE (non-geometry: integer -> bigint)
ALTER TABLE sk1_kba_edge.alter_target_y ALTER COLUMN waarde TYPE bigint;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y'
          AND column_name = 'waarde' AND data_type = 'bigint'
    ) THEN
        RAISE NOTICE 'TEST I2 PASSED: ALTER COLUMN TYPE (integer -> bigint) succeeded on Hex-managed table';
    ELSE
        RAISE WARNING 'TEST I2 FAILED: Type change to bigint did not take effect';
    END IF;
END $$;

-- I3: ALTER COLUMN TYPE on geometry (SRID change 3007 -> 3006 via USING)
DO $$
BEGIN
    EXECUTE 'ALTER TABLE sk1_kba_edge.alter_target_y
             ALTER COLUMN geom TYPE geometry(Polygon, 3006)
             USING ST_Transform(geom, 3006)';
    RAISE NOTICE 'TEST I3 PASSED: Geometry column SRID change (3007 -> 3006 via USING) succeeded';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST I3 INFO: Geometry type change failed or rejected: %', left(SQLERRM, 100);
END $$;

-- I4: ADD CONSTRAINT CHECK (user-defined, post-creation)
CREATE TABLE sk0_ext_edge.postconstrain_y (
    score integer,
    geom  geometry(Polygon, 3007)
);

ALTER TABLE sk0_ext_edge.postconstrain_y
    ADD CONSTRAINT chk_edge_score CHECK (score >= 0);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.postconstrain_y'::regclass
          AND contype = 'c'
          AND conname = 'chk_edge_score'
    ) THEN
        RAISE NOTICE 'TEST I4 PASSED: ADD CONSTRAINT CHECK accepted on Hex-managed table';
    ELSE
        RAISE WARNING 'TEST I4 FAILED: User CHECK constraint missing after ADD CONSTRAINT';
    END IF;
END $$;

-- I5: ADD CONSTRAINT UNIQUE (user-defined, post-creation)
ALTER TABLE sk0_ext_edge.postconstrain_y
    ADD CONSTRAINT uq_edge_score UNIQUE (score);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.postconstrain_y'::regclass
          AND contype = 'u'
          AND conname = 'uq_edge_score'
    ) THEN
        RAISE NOTICE 'TEST I5 PASSED: ADD CONSTRAINT UNIQUE accepted on Hex-managed table';
    ELSE
        RAISE WARNING 'TEST I5 FAILED: UNIQUE constraint missing after ADD CONSTRAINT';
    END IF;
END $$;

-- I6: DROP CONSTRAINT (user-defined)
ALTER TABLE sk0_ext_edge.postconstrain_y DROP CONSTRAINT chk_edge_score;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.postconstrain_y'::regclass
          AND conname = 'chk_edge_score'
    ) THEN
        RAISE NOTICE 'TEST I6 PASSED: DROP CONSTRAINT succeeded on Hex-managed table';
    ELSE
        RAISE WARNING 'TEST I6 FAILED: Constraint still exists after DROP CONSTRAINT';
    END IF;
END $$;

-- I7: ALTER TABLE ... SET SCHEMA (move table from ext to kba schema)
CREATE TABLE sk0_ext_edge.to_move_y (
    naam text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk0_ext_edge.to_move_y SET SCHEMA sk1_kba_edge;

DO $$
DECLARE
    in_new boolean;
    in_old boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'to_move_y'
    ) INTO in_new;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'to_move_y'
    ) INTO in_old;

    IF in_new AND NOT in_old THEN
        RAISE NOTICE 'TEST I7 PASSED: SET SCHEMA moved table from sk0_ext_edge to sk1_kba_edge. Note: table retains ext-style restructuring — kba rules are not retroactively applied.';
    ELSE
        RAISE WARNING 'TEST I7 FAILED: in_new=%, in_old=%', in_new, in_old;
    END IF;
END $$;

-- ============================================================
-- J: SCHEMA NAMING EDGE CASES
-- ============================================================
\echo ''
\echo '--- GROUP J: Schema naming edge cases ---'

-- J1: sk0_sys_* schema - should get sys treatment: gid only, no history, no validation
CREATE SCHEMA sk0_sys_edge;

CREATE TABLE sk0_sys_edge.config (
    param text,
    varde text
);

DO $$
DECLARE
    has_gid   boolean;
    has_hist  boolean;
    has_valid boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_sys_edge' AND table_name = 'config'
          AND column_name = 'gid'
    ) INTO has_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_sys_edge' AND table_name = 'config_h'
    ) INTO has_hist;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_sys_edge.config'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) INTO has_valid;

    IF has_gid AND NOT has_hist AND NOT has_valid THEN
        RAISE NOTICE 'TEST J1 PASSED: sk0_sys_* treated as sys (gid only, no history, no geometry validation)';
    ELSIF NOT has_gid THEN
        RAISE WARNING 'TEST J1 FAILED: sk0_sys_* table missing gid (prefix not recognized by Hex)';
    ELSE
        RAISE NOTICE 'TEST J1 INFO: sk0_sys_* state: gid=%, history=%, validation=%', has_gid, has_hist, has_valid;
    END IF;
END $$;

-- J2: sk1_sys_* schema - same expected treatment as sk0_sys_*
CREATE SCHEMA sk1_sys_edge;

CREATE TABLE sk1_sys_edge.config (
    param text,
    varde text
);

DO $$
DECLARE
    has_gid  boolean;
    has_hist boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_sys_edge' AND table_name = 'config'
          AND column_name = 'gid'
    ) INTO has_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_sys_edge' AND table_name = 'config_h'
    ) INTO has_hist;

    IF has_gid AND NOT has_hist THEN
        RAISE NOTICE 'TEST J2 PASSED: sk1_sys_* treated as sys (gid only, no history)';
    ELSIF NOT has_gid THEN
        RAISE WARNING 'TEST J2 FAILED: sk1_sys_* table missing gid (prefix not recognized)';
    ELSE
        RAISE NOTICE 'TEST J2 INFO: sk1_sys_* state: gid=%, history=%', has_gid, has_hist;
    END IF;
END $$;

-- J3: sk3_* schema - beyond the standard sk0/sk1/sk2 range
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA sk3_ext_edge';
    EXECUTE 'CREATE TABLE sk3_ext_edge.punter_p (naam text, geom geometry(Point, 3007))';

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk3_ext_edge' AND table_name = 'punter_p'
          AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST J3 INFO: sk3_* IS restructured by Hex (gid added — sk3 configured in standardiserade_kolumner)';
    ELSE
        RAISE NOTICE 'TEST J3 INFO: sk3_* is NOT restructured by Hex (sk3 not in standardiserade_kolumner — treated as unmanaged schema)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST J3 INFO: sk3_* schema or table caused error (schema name may be rejected): %', left(SQLERRM, 100);
END $$;

-- J4: Non-matching schema name (sk0ext_partial — missing underscore between prefix and type)
--     Hex should either reject the schema name or silently ignore tables in it.
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA sk0ext_partial';
    EXECUTE 'CREATE TABLE sk0ext_partial.geo_y (naam text, geom geometry(Polygon, 3007))';

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0ext_partial' AND table_name = 'geo_y'
          AND column_name = 'gid'
    ) THEN
        RAISE WARNING 'TEST J4 BUG: Hex applied rules to non-standard schema sk0ext_partial (gid added — partial pattern match)';
    ELSE
        RAISE NOTICE 'TEST J4 PASSED: Schema sk0ext_partial correctly ignored by Hex (no gid added)';
    END IF;

    EXECUTE 'DROP SCHEMA sk0ext_partial CASCADE';
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            EXECUTE 'DROP SCHEMA IF EXISTS sk0ext_partial CASCADE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RAISE NOTICE 'TEST J4 INFO: sk0ext_partial schema rejected by Hex name validation: %', left(SQLERRM, 80);
END $$;

-- ============================================================
-- K: USER-ISSUED INDEX DDL
-- ============================================================
\echo ''
\echo '--- GROUP K: User-issued index DDL ---'

-- K-setup
CREATE TABLE sk0_ext_edge.indexed_y (
    kategori text,
    waarde   integer,
    geom     geometry(Polygon, 3007)
);

-- K1: CREATE INDEX (B-tree) - user-defined, Hex must not interfere
CREATE INDEX idx_edge_indexed_y_kat ON sk0_ext_edge.indexed_y (kategori);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
          AND indexname = 'idx_edge_indexed_y_kat'
    ) THEN
        RAISE NOTICE 'TEST K1 PASSED: User CREATE INDEX on Hex-managed table accepted';
    ELSE
        RAISE WARNING 'TEST K1 FAILED: User-created index missing';
    END IF;
END $$;

-- K2: CREATE UNIQUE INDEX
CREATE UNIQUE INDEX uidx_edge_indexed_y_wrd ON sk0_ext_edge.indexed_y (waarde);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
          AND indexname = 'uidx_edge_indexed_y_wrd'
          AND indexdef LIKE '%UNIQUE%'
    ) THEN
        RAISE NOTICE 'TEST K2 PASSED: CREATE UNIQUE INDEX on Hex-managed table accepted';
    ELSE
        RAISE WARNING 'TEST K2 FAILED: UNIQUE INDEX missing or not marked unique';
    END IF;
END $$;

-- K3: DROP INDEX on the Hex-created GiST index
DO $$
DECLARE gist_idx text;
BEGIN
    SELECT indexname INTO gist_idx
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
      AND indexdef LIKE '%USING gist%'
    LIMIT 1;

    IF gist_idx IS NULL THEN
        RAISE WARNING 'TEST K3 SKIPPED: No GiST index found on indexed_y';
        RETURN;
    END IF;

    EXECUTE format('DROP INDEX sk0_ext_edge.%I', gist_idx);

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST K3 PASSED: DROP INDEX on Hex-created GiST index succeeded (table still exists, no spatial index)';
    ELSE
        RAISE WARNING 'TEST K3 FAILED: GiST index still present after DROP INDEX';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST K3 FAILED: DROP INDEX caused error: %', SQLERRM;
END $$;

-- ============================================================
-- L: DROP VARIATIONS
-- ============================================================
\echo ''
\echo '--- GROUP L: DROP variations ---'

-- L1: DROP TABLE CASCADE (table has a dependent view)
CREATE TABLE sk0_ext_edge.dep_table_y (
    naam text,
    geom geometry(Polygon, 3007)
);

CREATE VIEW sk0_ext_edge.v_dep_table_y AS
    SELECT gid, naam, geom FROM sk0_ext_edge.dep_table_y;

DROP TABLE sk0_ext_edge.dep_table_y CASCADE;

DO $$
DECLARE
    table_gone boolean;
    view_gone  boolean;
BEGIN
    SELECT NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'dep_table_y'
    ) INTO table_gone;

    SELECT NOT EXISTS (
        SELECT 1 FROM information_schema.views
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'v_dep_table_y'
    ) INTO view_gone;

    IF table_gone AND view_gone THEN
        RAISE NOTICE 'TEST L1 PASSED: DROP TABLE CASCADE removed table and dependent view cleanly';
    ELSIF NOT table_gone THEN
        RAISE WARNING 'TEST L1 FAILED: Table still exists after CASCADE drop';
    ELSIF NOT view_gone THEN
        RAISE WARNING 'TEST L1 FAILED: Dependent view still exists after CASCADE drop';
    END IF;
END $$;

-- L2: DROP SCHEMA without CASCADE on non-empty schema (must error at PostgreSQL level)
DO $$
BEGIN
    EXECUTE 'DROP SCHEMA sk0_ext_edge';  -- still has tables
    RAISE WARNING 'TEST L2 FAILED: DROP SCHEMA without CASCADE on non-empty schema should have errored';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST L2 PASSED: DROP SCHEMA without CASCADE correctly rejected for non-empty schema';
END $$;

-- ============================================================
-- M: TRUNCATE VARIATIONS
-- ============================================================
\echo ''
\echo '--- GROUP M: TRUNCATE variations ---'

-- M-setup: kba table with rows
CREATE TABLE sk1_kba_edge.trunc_test_y (
    naam text,
    geom geometry(Polygon, 3007)
);

INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('r1', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007)),
    ('r2', ST_GeomFromText('POLYGON((2 2,3 2,3 3,2 3,2 2))', 3007));

-- M1: TRUNCATE basic — row-level triggers do not fire, history table stays empty
TRUNCATE sk1_kba_edge.trunc_test_y;

DO $$
DECLARE
    main_cnt integer;
    hist_cnt integer;
BEGIN
    SELECT COUNT(*) INTO main_cnt FROM sk1_kba_edge.trunc_test_y;
    SELECT COUNT(*) INTO hist_cnt FROM sk1_kba_edge.trunc_test_y_h;

    IF main_cnt = 0 AND hist_cnt = 0 THEN
        RAISE NOTICE 'TEST M1 PASSED: TRUNCATE cleared main table; history empty (row triggers do not fire on TRUNCATE)';
    ELSIF main_cnt = 0 AND hist_cnt > 0 THEN
        RAISE NOTICE 'TEST M1 INFO: TRUNCATE cleared main table; history has % rows (statement-level trigger present)', hist_cnt;
    ELSE
        RAISE WARNING 'TEST M1 FAILED: TRUNCATE left % rows in main table', main_cnt;
    END IF;
END $$;

-- M2: TRUNCATE RESTART IDENTITY
INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('pre_restart', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007));

DO $$
BEGIN
    TRUNCATE sk1_kba_edge.trunc_test_y RESTART IDENTITY;
    RAISE NOTICE 'TEST M2 PASSED: TRUNCATE RESTART IDENTITY accepted on Hex-managed table';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST M2 FAILED: TRUNCATE RESTART IDENTITY caused error: %', SQLERRM;
END $$;

-- M3: TRUNCATE CASCADE
INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('cascade_row', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007));

DO $$
BEGIN
    TRUNCATE sk1_kba_edge.trunc_test_y CASCADE;
    RAISE NOTICE 'TEST M3 PASSED: TRUNCATE CASCADE accepted on Hex-managed table';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST M3 FAILED: TRUNCATE CASCADE caused error: %', SQLERRM;
END $$;

-- ============================================================
-- N: MATERIALIZED VIEWS
-- ============================================================
\echo ''
\echo '--- GROUP N: Materialized views ---'

-- N-setup: geometry table to base matviews on
CREATE TABLE sk0_ext_edge.matview_src_y (
    naam text,
    geom geometry(Polygon, 3007)
);

-- N1: CREATE MATERIALIZED VIEW with valid v_ prefix
DO $$
BEGIN
    EXECUTE 'CREATE MATERIALIZED VIEW sk0_ext_edge.v_mat_src_y AS
             SELECT gid, naam, geom FROM sk0_ext_edge.matview_src_y';
    RAISE NOTICE 'TEST N1 PASSED: CREATE MATERIALIZED VIEW with valid v_ prefix accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N1 FAILED: CREATE MATERIALIZED VIEW with v_ prefix rejected: %', SQLERRM;
END $$;

-- N2: CREATE MATERIALIZED VIEW without v_ prefix
--     Does Hex apply the same naming rules to materialized views as to regular views?
DO $$
BEGIN
    EXECUTE 'CREATE MATERIALIZED VIEW sk0_ext_edge.mat_nv_src_y AS
             SELECT gid, naam, geom FROM sk0_ext_edge.matview_src_y';
    RAISE NOTICE 'TEST N2 INFO: Materialized view without v_ prefix ACCEPTED (Hex view naming rules do not apply to materialized views)';
    EXECUTE 'DROP MATERIALIZED VIEW sk0_ext_edge.mat_nv_src_y';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST N2 INFO: Materialized view without v_ prefix REJECTED (Hex applies view naming rules to materialized views): %', left(SQLERRM, 80);
END $$;

-- N3: REFRESH MATERIALIZED VIEW
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_matviews
        WHERE schemaname = 'sk0_ext_edge' AND matviewname = 'v_mat_src_y'
    ) THEN
        EXECUTE 'REFRESH MATERIALIZED VIEW sk0_ext_edge.v_mat_src_y';
        RAISE NOTICE 'TEST N3 PASSED: REFRESH MATERIALIZED VIEW accepted';
    ELSE
        RAISE NOTICE 'TEST N3 SKIPPED: v_mat_src_y does not exist (N1 may have failed)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N3 FAILED: REFRESH MATERIALIZED VIEW caused error: %', SQLERRM;
END $$;

-- N4: DROP MATERIALIZED VIEW
DO $$
BEGIN
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS sk0_ext_edge.v_mat_src_y';
    RAISE NOTICE 'TEST N4 PASSED: DROP MATERIALIZED VIEW accepted';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N4 FAILED: DROP MATERIALIZED VIEW caused error: %', SQLERRM;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP TABLE   IF EXISTS public.hex_edge_ref  CASCADE;
DROP SCHEMA  IF EXISTS sk1_kba_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0_ext_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0_sys_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk1_sys_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk3_ext_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0ext_partial       CASCADE;

\echo ''
\echo 'HEX EDGE CASE SUITE COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
