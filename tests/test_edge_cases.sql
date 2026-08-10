-- ============================================================
-- HEX TESTSVIT FÖR SPECIALFALL — GRUPPERNA H, I, J, K, L, M & N
--
-- H  Varianter av CREATE TABLE
--    H1  CREATE TEMP TABLE med geometrisuffix (ignoreras av Hex)
--    H2  Inline CHECK-villkor överlever Hex-omstrukturering
--    H3  Inline UNIQUE-villkor överlever Hex-omstrukturering
--    H4  Inline FOREIGN KEY överlever Hex-omstrukturering
--    H5  CREATE TABLE ... INHERITS (hantering av barn-tabell)
--    H6  MultiPoint-geometri med _p-suffix
--    H7  MultiLineString-geometri med _l-suffix
--    H8  GeometryCollection-geometri med _g-suffix
--
-- I  Varianter av ALTER TABLE
--    I1  RENAME COLUMN (ej geometri) + synk med historiktabell
--    I2  ALTER COLUMN TYPE (typomvandling, ej geometri)
--    I3  ALTER COLUMN TYPE på geom (SRID-ändring via USING)
--    I4  ADD CONSTRAINT CHECK (användardefinierad, efter skapande)
--    I5  ADD CONSTRAINT UNIQUE (användardefinierad, efter skapande)
--    I6  DROP CONSTRAINT (användardefinierad)
--    I7  SET SCHEMA (tabell flyttad mellan schematyper)
--
-- J  Specialfall för schemanamngivning
--    J1  sk0_sys_*-schemabehandling
--    J2  sk1_sys_*-schemabehandling
--    J3  sk3_*-schema (utanför standardintervallet)
--    J4  Ej matchande schemanamn (delvis mönster, ingen Hex-kontroll)
--
-- K  Användarutfärdad index-DDL
--    K1  CREATE INDEX (B-tree) på Hex-hanterad tabell
--    K2  CREATE UNIQUE INDEX på Hex-hanterad tabell
--    K3  DROP INDEX på Hex-skapat GiST-index
--
-- L  Varianter av DROP
--    L1  DROP TABLE CASCADE (tar bort beroende vy)
--    L2  DROP SCHEMA utan CASCADE på icke-tomt schema (måste ge fel)
--
-- M  Varianter av TRUNCATE
--    M1  TRUNCATE grundläggande (rad-triggers avfyras inte, historik opåverkad)
--    M2  TRUNCATE RESTART IDENTITY
--    M3  TRUNCATE CASCADE
--
-- N  Materialiserade vyer
--    N1  CREATE MATERIALIZED VIEW med giltigt v_-prefix
--    N2  CREATE MATERIALIZED VIEW utan v_-prefix
--    N3  REFRESH MATERIALIZED VIEW
--    N4  DROP MATERIALIZED VIEW
--
-- Scheman som används: sk1_kba_edge, sk0_ext_edge, sk0_sys_edge, sk1_sys_edge, sk3_ext_edge
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX TESTSVIT FÖR SPECIALFALL'
\echo '============================================================'

-- ============================================================
-- Städning och förberedelse
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

-- Referenstabell i public för FK-tester (inte Hex-hanterad)
CREATE TABLE public.hex_edge_ref (id integer PRIMARY KEY);

-- ============================================================
-- H: VARIANTER AV CREATE TABLE
-- ============================================================
\echo ''
\echo '--- GRUPP H: Varianter av CREATE TABLE ---'

-- H1: CREATE TEMP TABLE med geometrisuffix - Hex måste ignorera pg_temp-schemat
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
        RAISE NOTICE 'TEST H1 PASSED: TEMP TABLE korrekt ignorerad av Hex (inget gid tillagt i pg_temp-tabell)';
    ELSE
        RAISE WARNING 'TEST H1 FAILED: Hex omstrukturerade en TEMP TABLE i pg_temp (gid hittades)';
    END IF;

    EXECUTE 'DROP TABLE IF EXISTS tmp_hex_edge_y';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltigt tabellnamn%pg_temp%'
        OR SQLERRM LIKE '%invalid table name%pg_temp%' THEN
            RAISE WARNING 'TEST H1 BUG CONFIRMED: Hex event trigger avfyras på TEMP TABLE och ger fel (hex_validera_tabell avvisar namnet pg_temp.*). TEMP TABLE-skapande i ett hanterat schema misslyckas helt. Fel: %', left(SQLERRM, 120);
        ELSE
            RAISE WARNING 'TEST H1 FAILED: TEMP TABLE orsakade oväntat fel: %', SQLERRM;
        END IF;
END $$;

-- H2: Inline CHECK-villkor - måste överleva omstrukturering i hex_byt_ut_tabell
CREATE TABLE sk1_kba_edge.checked_y (
    category text    CHECK (category IN ('A', 'B', 'C')),
    score    integer CHECK (score BETWEEN 0 AND 100),
    geom     geometry(Polygon, 3007)
);

DO $$
DECLARE antal_anv_check integer;
BEGIN
    SELECT COUNT(*) INTO antal_anv_check
    FROM pg_constraint
    WHERE conrelid = 'sk1_kba_edge.checked_y'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) NOT LIKE '%hex_validera_geometri%';

    IF antal_anv_check >= 2 THEN
        RAISE NOTICE 'TEST H2 PASSED: % användar-CHECK-villkor överlevde Hex-omstrukturering', antal_anv_check;
    ELSIF antal_anv_check = 1 THEN
        RAISE WARNING 'TEST H2 PARTIAL: Bara 1 av 2 användar-CHECK-villkor överlevde hex_byt_ut_tabell';
    ELSE
        RAISE WARNING 'TEST H2 FAILED: Användar-CHECK-villkor gick förlorade under Hex-omstrukturering (hex_byt_ut_tabell bevarar dem inte)';
    END IF;
END $$;

-- H3: Inline UNIQUE-villkor - måste överleva omstrukturering i hex_byt_ut_tabell
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
        RAISE NOTICE 'TEST H3 PASSED: UNIQUE-villkor överlevde Hex-omstrukturering';
    ELSE
        RAISE WARNING 'TEST H3 FAILED: UNIQUE-villkor gick förlorat under Hex-omstrukturering (hex_byt_ut_tabell bevarar det inte)';
    END IF;
END $$;

-- H4: Inline FOREIGN KEY - måste överleva omstrukturering i hex_byt_ut_tabell
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
        RAISE NOTICE 'TEST H4 PASSED: FOREIGN KEY-villkor överlevde Hex-omstrukturering';
    ELSE
        RAISE WARNING 'TEST H4 FAILED: FOREIGN KEY-villkor gick förlorat under Hex-omstrukturering (hex_byt_ut_tabell bevarar det inte)';
    END IF;
END $$;

-- H5: CREATE TABLE ... INHERITS (barn ärver från Hex-hanterad förälder)
CREATE TABLE sk0_ext_edge.parent_base_y (
    naam text,
    geom geometry(Polygon, 3007)
);

DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.child_base_y (extra text) INHERITS (sk0_ext_edge.parent_base_y)';

    -- Kontrollera om barnet har ett direkt ägt gid (attinhcount = 0 betyder inte ärvt)
    IF EXISTS (
        SELECT 1 FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'sk0_ext_edge' AND c.relname = 'child_base_y'
          AND a.attname = 'gid' AND a.attinhcount = 0
          AND a.attnum > 0 AND NOT a.attisdropped
    ) THEN
        RAISE NOTICE 'TEST H5 PASSED: INHERITS-barnet har eget gid (Hex omstrukturerade barnet oberoende)';
    ELSE
        RAISE NOTICE 'TEST H5 INFO: INHERITS-barnet har inget eget gid (ärver från föräldern eller Hex hoppar över ärvda tabeller)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H5 INFO: INHERITS orsakade: %', left(SQLERRM, 100);
END $$;

-- H6: MultiPoint-geometri med _p-suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.multipoint_p (naam text, geom geometry(MultiPoint, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'multipoint_p'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H6 PASSED: MultiPoint med _p-suffix accepterad och GiST-index skapat';
    ELSE
        RAISE WARNING 'TEST H6 FAILED: MultiPoint-tabell skapad men inget GiST-index (suffix-/typkontrollen kan ha avvisat den)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H6 INFO: MultiPoint + _p-suffix avvisat av Hex: %', left(SQLERRM, 100);
END $$;

-- H7: MultiLineString-geometri med _l-suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.multiline_l (naam text, geom geometry(MultiLineString, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'multiline_l'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H7 PASSED: MultiLineString med _l-suffix accepterad och GiST-index skapat';
    ELSE
        RAISE WARNING 'TEST H7 FAILED: MultiLineString-tabell skapad men inget GiST-index';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H7 INFO: MultiLineString + _l-suffix avvisat av Hex: %', left(SQLERRM, 100);
END $$;

-- H8: GeometryCollection-geometri med _g-suffix
DO $$
BEGIN
    EXECUTE 'CREATE TABLE sk0_ext_edge.collection_g (naam text, geom geometry(GeometryCollection, 3007))';

    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'collection_g'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST H8 PASSED: GeometryCollection med _g-suffix accepterad och GiST-index skapat';
    ELSE
        RAISE WARNING 'TEST H8 FAILED: GeometryCollection-tabell skapad men inget GiST-index';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST H8 INFO: GeometryCollection + _g-suffix avvisat av Hex: %', left(SQLERRM, 100);
END $$;

-- ============================================================
-- I: VARIANTER AV ALTER TABLE
-- ============================================================
\echo ''
\echo '--- GRUPP I: Varianter av ALTER TABLE ---'

-- I-förberedelse: färsk kba-tabell för ALTER-tester
CREATE TABLE sk1_kba_edge.alter_target_y (
    old_naam text,
    waarde   integer,
    geom     geometry(Polygon, 3007)
);

-- I1: RENAME COLUMN (ej geometri) - verifiera synk mellan huvudtabell och historiktabell
ALTER TABLE sk1_kba_edge.alter_target_y RENAME COLUMN old_naam TO new_naam;

DO $$
DECLARE
    huvud_ok boolean;
    hist_ok  boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y'
          AND column_name = 'new_naam'
    ) INTO huvud_ok;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y_h'
          AND column_name = 'new_naam'
    ) INTO hist_ok;

    IF huvud_ok AND hist_ok THEN
        RAISE NOTICE 'TEST I1 PASSED: RENAME COLUMN speglas i både huvudtabellen och historiktabellen';
    ELSIF huvud_ok AND NOT hist_ok THEN
        RAISE WARNING 'TEST I1 BUG: RENAME COLUMN tillämpad på huvudtabellen men historiktabellen har fortfarande det gamla kolumnnamnet (historiksynk spårar inte namnbyten)';
    ELSE
        RAISE WARNING 'TEST I1 FAILED: Den omdöpta kolumnen hittades inte i huvudtabellen';
    END IF;
END $$;

-- I2: ALTER COLUMN TYPE (ej geometri: integer -> bigint)
ALTER TABLE sk1_kba_edge.alter_target_y ALTER COLUMN waarde TYPE bigint;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'alter_target_y'
          AND column_name = 'waarde' AND data_type = 'bigint'
    ) THEN
        RAISE NOTICE 'TEST I2 PASSED: ALTER COLUMN TYPE (integer -> bigint) lyckades på Hex-hanterad tabell';
    ELSE
        RAISE WARNING 'TEST I2 FAILED: Typändring till bigint fick ingen effekt';
    END IF;
END $$;

-- I3: ALTER COLUMN TYPE på geometri (SRID-ändring 3007 -> 3006 via USING)
DO $$
BEGIN
    EXECUTE 'ALTER TABLE sk1_kba_edge.alter_target_y
             ALTER COLUMN geom TYPE geometry(Polygon, 3006)
             USING ST_Transform(geom, 3006)';
    RAISE NOTICE 'TEST I3 PASSED: SRID-ändring på geometrikolumn (3007 -> 3006 via USING) lyckades';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST I3 INFO: Geometritypändring misslyckades eller avvisades: %', left(SQLERRM, 100);
END $$;

-- I4: ADD CONSTRAINT CHECK (användardefinierad, efter skapande)
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
        RAISE NOTICE 'TEST I4 PASSED: ADD CONSTRAINT CHECK accepterad på Hex-hanterad tabell';
    ELSE
        RAISE WARNING 'TEST I4 FAILED: Användar-CHECK-villkoret saknas efter ADD CONSTRAINT';
    END IF;
END $$;

-- I5: ADD CONSTRAINT UNIQUE (användardefinierad, efter skapande)
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
        RAISE NOTICE 'TEST I5 PASSED: ADD CONSTRAINT UNIQUE accepterad på Hex-hanterad tabell';
    ELSE
        RAISE WARNING 'TEST I5 FAILED: UNIQUE-villkoret saknas efter ADD CONSTRAINT';
    END IF;
END $$;

-- I6: DROP CONSTRAINT (användardefinierad)
ALTER TABLE sk0_ext_edge.postconstrain_y DROP CONSTRAINT chk_edge_score;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_edge.postconstrain_y'::regclass
          AND conname = 'chk_edge_score'
    ) THEN
        RAISE NOTICE 'TEST I6 PASSED: DROP CONSTRAINT lyckades på Hex-hanterad tabell';
    ELSE
        RAISE WARNING 'TEST I6 FAILED: Villkoret finns fortfarande kvar efter DROP CONSTRAINT';
    END IF;
END $$;

-- I7: ALTER TABLE ... SET SCHEMA (flytta tabell från ext- till kba-schema)
CREATE TABLE sk0_ext_edge.to_move_y (
    naam text,
    geom geometry(Polygon, 3007)
);

ALTER TABLE sk0_ext_edge.to_move_y SET SCHEMA sk1_kba_edge;

DO $$
DECLARE
    i_ny  boolean;
    i_gam boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_edge' AND table_name = 'to_move_y'
    ) INTO i_ny;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'to_move_y'
    ) INTO i_gam;

    IF i_ny AND NOT i_gam THEN
        RAISE NOTICE 'TEST I7 PASSED: SET SCHEMA flyttade tabellen från sk0_ext_edge till sk1_kba_edge. Obs: tabellen behåller ext-stilens omstrukturering — kba-regler tillämpas inte retroaktivt.';
    ELSE
        RAISE WARNING 'TEST I7 FAILED: i_ny=%, i_gam=%', i_ny, i_gam;
    END IF;
END $$;

-- ============================================================
-- J: SPECIALFALL FÖR SCHEMANAMNGIVNING
-- ============================================================
\echo ''
\echo '--- GRUPP J: Specialfall för schemanamngivning ---'

-- J1: sk0_sys_*-schema - ska få sys-behandling: bara gid, ingen historik, ingen validering
CREATE SCHEMA sk0_sys_edge;

CREATE TABLE sk0_sys_edge.config (
    param text,
    varde text
);

DO $$
DECLARE
    har_gid   boolean;
    har_hist  boolean;
    har_valid boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_sys_edge' AND table_name = 'config'
          AND column_name = 'gid'
    ) INTO har_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_sys_edge' AND table_name = 'config_h'
    ) INTO har_hist;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_sys_edge.config'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%hex_validera_geometri%'
    ) INTO har_valid;

    IF har_gid AND NOT har_hist AND NOT har_valid THEN
        RAISE NOTICE 'TEST J1 PASSED: sk0_sys_* behandlas som sys (bara gid, ingen historik, ingen geometrivalidering)';
    ELSIF NOT har_gid THEN
        RAISE WARNING 'TEST J1 FAILED: sk0_sys_*-tabellen saknar gid (prefixet känns inte igen av Hex)';
    ELSE
        RAISE NOTICE 'TEST J1 INFO: sk0_sys_*-tillstånd: gid=%, historik=%, validering=%', har_gid, har_hist, har_valid;
    END IF;
END $$;

-- J2: sk1_sys_*-schema - samma förväntade behandling som sk0_sys_*
CREATE SCHEMA sk1_sys_edge;

CREATE TABLE sk1_sys_edge.config (
    param text,
    varde text
);

DO $$
DECLARE
    har_gid  boolean;
    har_hist boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk1_sys_edge' AND table_name = 'config'
          AND column_name = 'gid'
    ) INTO har_gid;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_sys_edge' AND table_name = 'config_h'
    ) INTO har_hist;

    IF har_gid AND NOT har_hist THEN
        RAISE NOTICE 'TEST J2 PASSED: sk1_sys_* behandlas som sys (bara gid, ingen historik)';
    ELSIF NOT har_gid THEN
        RAISE WARNING 'TEST J2 FAILED: sk1_sys_*-tabellen saknar gid (prefixet känns inte igen)';
    ELSE
        RAISE NOTICE 'TEST J2 INFO: sk1_sys_*-tillstånd: gid=%, historik=%', har_gid, har_hist;
    END IF;
END $$;

-- J3: sk3_*-schema - utanför standardintervallet sk0/sk1/sk2
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA sk3_ext_edge';
    EXECUTE 'CREATE TABLE sk3_ext_edge.punter_p (naam text, geom geometry(Point, 3007))';

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk3_ext_edge' AND table_name = 'punter_p'
          AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST J3 INFO: sk3_* omstruktureras AV Hex (gid tillagt — sk3 konfigurerat i hex_standardiserade_kolumner)';
    ELSE
        RAISE NOTICE 'TEST J3 INFO: sk3_* omstruktureras INTE av Hex (sk3 finns inte i hex_standardiserade_kolumner — behandlas som ohanterat schema)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST J3 INFO: sk3_*-schemat eller -tabellen orsakade fel (schemanamnet kan vara avvisat): %', left(SQLERRM, 100);
END $$;

-- J4: Ej matchande schemanamn (sk0ext_partial — saknar understreck mellan prefix och typ)
--     Hex ska antingen avvisa schemanamnet eller tyst ignorera tabeller i det.
DO $$
BEGIN
    EXECUTE 'CREATE SCHEMA sk0ext_partial';
    EXECUTE 'CREATE TABLE sk0ext_partial.geo_y (naam text, geom geometry(Polygon, 3007))';

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0ext_partial' AND table_name = 'geo_y'
          AND column_name = 'gid'
    ) THEN
        RAISE WARNING 'TEST J4 BUG: Hex tillämpade regler på det icke-standardmässiga schemat sk0ext_partial (gid tillagt — delvis mönstermatchning)';
    ELSE
        RAISE NOTICE 'TEST J4 PASSED: Schemat sk0ext_partial korrekt ignorerat av Hex (inget gid tillagt)';
    END IF;

    EXECUTE 'DROP SCHEMA sk0ext_partial CASCADE';
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            EXECUTE 'DROP SCHEMA IF EXISTS sk0ext_partial CASCADE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RAISE NOTICE 'TEST J4 INFO: Schemat sk0ext_partial avvisat av Hex namnvalidering: %', left(SQLERRM, 80);
END $$;

-- ============================================================
-- K: ANVÄNDARUTFÄRDAD INDEX-DDL
-- ============================================================
\echo ''
\echo '--- GRUPP K: Användarutfärdad index-DDL ---'

-- K-förberedelse
CREATE TABLE sk0_ext_edge.indexed_y (
    kategori text,
    waarde   integer,
    geom     geometry(Polygon, 3007)
);

-- K1: CREATE INDEX (B-tree) - användardefinierat, Hex får inte lägga sig i
CREATE INDEX idx_edge_indexed_y_kat ON sk0_ext_edge.indexed_y (kategori);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
          AND indexname = 'idx_edge_indexed_y_kat'
    ) THEN
        RAISE NOTICE 'TEST K1 PASSED: Användarens CREATE INDEX på Hex-hanterad tabell accepterad';
    ELSE
        RAISE WARNING 'TEST K1 FAILED: Det användarskapade indexet saknas';
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
        RAISE NOTICE 'TEST K2 PASSED: CREATE UNIQUE INDEX på Hex-hanterad tabell accepterad';
    ELSE
        RAISE WARNING 'TEST K2 FAILED: UNIQUE INDEX saknas eller inte markerat unikt';
    END IF;
END $$;

-- K3: DROP INDEX på det Hex-skapade GiST-indexet
DO $$
DECLARE gist_idx text;
BEGIN
    SELECT indexname INTO gist_idx
    FROM pg_indexes
    WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
      AND indexdef LIKE '%USING gist%'
    LIMIT 1;

    IF gist_idx IS NULL THEN
        RAISE WARNING 'TEST K3 SKIPPED: Inget GiST-index hittades på indexed_y';
        RETURN;
    END IF;

    EXECUTE format('DROP INDEX sk0_ext_edge.%I', gist_idx);

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_edge' AND tablename = 'indexed_y'
          AND indexdef LIKE '%USING gist%'
    ) THEN
        RAISE NOTICE 'TEST K3 PASSED: DROP INDEX på Hex-skapat GiST-index lyckades (tabellen finns kvar, inget spatialt index)';
    ELSE
        RAISE WARNING 'TEST K3 FAILED: GiST-indexet finns fortfarande kvar efter DROP INDEX';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST K3 FAILED: DROP INDEX orsakade fel: %', SQLERRM;
END $$;

-- ============================================================
-- L: VARIANTER AV DROP
-- ============================================================
\echo ''
\echo '--- GRUPP L: Varianter av DROP ---'

-- L1: DROP TABLE CASCADE (tabellen har en beroende vy)
CREATE TABLE sk0_ext_edge.dep_table_y (
    naam text,
    geom geometry(Polygon, 3007)
);

CREATE VIEW sk0_ext_edge.v_dep_table_y AS
    SELECT gid, naam, geom FROM sk0_ext_edge.dep_table_y;

DROP TABLE sk0_ext_edge.dep_table_y CASCADE;

DO $$
DECLARE
    tabell_borta boolean;
    vy_borta     boolean;
BEGIN
    SELECT NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'dep_table_y'
    ) INTO tabell_borta;

    SELECT NOT EXISTS (
        SELECT 1 FROM information_schema.views
        WHERE table_schema = 'sk0_ext_edge' AND table_name = 'v_dep_table_y'
    ) INTO vy_borta;

    IF tabell_borta AND vy_borta THEN
        RAISE NOTICE 'TEST L1 PASSED: DROP TABLE CASCADE tog bort tabellen och den beroende vyn snyggt';
    ELSIF NOT tabell_borta THEN
        RAISE WARNING 'TEST L1 FAILED: Tabellen finns fortfarande kvar efter CASCADE-borttagning';
    ELSIF NOT vy_borta THEN
        RAISE WARNING 'TEST L1 FAILED: Den beroende vyn finns fortfarande kvar efter CASCADE-borttagning';
    END IF;
END $$;

-- L2: DROP SCHEMA utan CASCADE på icke-tomt schema (måste ge fel på PostgreSQL-nivå)
DO $$
BEGIN
    EXECUTE 'DROP SCHEMA sk0_ext_edge';  -- har fortfarande tabeller
    RAISE WARNING 'TEST L2 FAILED: DROP SCHEMA utan CASCADE på icke-tomt schema borde ha gett fel';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST L2 PASSED: DROP SCHEMA utan CASCADE korrekt avvisat för icke-tomt schema';
END $$;

-- ============================================================
-- M: VARIANTER AV TRUNCATE
-- ============================================================
\echo ''
\echo '--- GRUPP M: Varianter av TRUNCATE ---'

-- M-förberedelse: kba-tabell med rader
CREATE TABLE sk1_kba_edge.trunc_test_y (
    naam text,
    geom geometry(Polygon, 3007)
);

INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('r1', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007)),
    ('r2', ST_GeomFromText('POLYGON((2 2,3 2,3 3,2 3,2 2))', 3007));

-- M1: TRUNCATE grundläggande — rad-nivå-triggers avfyras inte, historiktabellen förblir tom
TRUNCATE sk1_kba_edge.trunc_test_y;

DO $$
DECLARE
    huvud_antal integer;
    hist_antal  integer;
BEGIN
    SELECT COUNT(*) INTO huvud_antal FROM sk1_kba_edge.trunc_test_y;
    SELECT COUNT(*) INTO hist_antal FROM sk1_kba_edge.trunc_test_y_h;

    IF huvud_antal = 0 AND hist_antal = 0 THEN
        RAISE NOTICE 'TEST M1 PASSED: TRUNCATE tömde huvudtabellen; historiken tom (rad-triggers avfyras inte vid TRUNCATE)';
    ELSIF huvud_antal = 0 AND hist_antal > 0 THEN
        RAISE NOTICE 'TEST M1 INFO: TRUNCATE tömde huvudtabellen; historiken har % rader (sats-nivå-trigger finns)', hist_antal;
    ELSE
        RAISE WARNING 'TEST M1 FAILED: TRUNCATE lämnade % rader kvar i huvudtabellen', huvud_antal;
    END IF;
END $$;

-- M2: TRUNCATE RESTART IDENTITY
INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('pre_restart', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007));

DO $$
BEGIN
    TRUNCATE sk1_kba_edge.trunc_test_y RESTART IDENTITY;
    RAISE NOTICE 'TEST M2 PASSED: TRUNCATE RESTART IDENTITY accepterad på Hex-hanterad tabell';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST M2 FAILED: TRUNCATE RESTART IDENTITY orsakade fel: %', SQLERRM;
END $$;

-- M3: TRUNCATE CASCADE
INSERT INTO sk1_kba_edge.trunc_test_y (naam, geom) VALUES
    ('cascade_row', ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))', 3007));

DO $$
BEGIN
    TRUNCATE sk1_kba_edge.trunc_test_y CASCADE;
    RAISE NOTICE 'TEST M3 PASSED: TRUNCATE CASCADE accepterad på Hex-hanterad tabell';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST M3 FAILED: TRUNCATE CASCADE orsakade fel: %', SQLERRM;
END $$;

-- ============================================================
-- N: MATERIALISERADE VYER
-- ============================================================
\echo ''
\echo '--- GRUPP N: Materialiserade vyer ---'

-- N-förberedelse: geometritabell att basera materialiserade vyer på
CREATE TABLE sk0_ext_edge.matview_src_y (
    naam text,
    geom geometry(Polygon, 3007)
);

-- N1: CREATE MATERIALIZED VIEW med giltigt v_-prefix
DO $$
BEGIN
    EXECUTE 'CREATE MATERIALIZED VIEW sk0_ext_edge.v_mat_src_y AS
             SELECT gid, naam, geom FROM sk0_ext_edge.matview_src_y';
    RAISE NOTICE 'TEST N1 PASSED: CREATE MATERIALIZED VIEW med giltigt v_-prefix accepterad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N1 FAILED: CREATE MATERIALIZED VIEW med v_-prefix avvisad: %', SQLERRM;
END $$;

-- N2: CREATE MATERIALIZED VIEW utan v_-prefix
--     Tillämpar Hex samma namngivningsregler på materialiserade vyer som på vanliga vyer?
DO $$
BEGIN
    EXECUTE 'CREATE MATERIALIZED VIEW sk0_ext_edge.mat_nv_src_y AS
             SELECT gid, naam, geom FROM sk0_ext_edge.matview_src_y';
    RAISE NOTICE 'TEST N2 INFO: Materialiserad vy utan v_-prefix ACCEPTERAD (Hex vy-namngivningsregler gäller inte materialiserade vyer)';
    EXECUTE 'DROP MATERIALIZED VIEW sk0_ext_edge.mat_nv_src_y';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST N2 INFO: Materialiserad vy utan v_-prefix AVVISAD (Hex tillämpar vy-namngivningsregler på materialiserade vyer): %', left(SQLERRM, 80);
END $$;

-- N3: REFRESH MATERIALIZED VIEW
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_matviews
        WHERE schemaname = 'sk0_ext_edge' AND matviewname = 'v_mat_src_y'
    ) THEN
        EXECUTE 'REFRESH MATERIALIZED VIEW sk0_ext_edge.v_mat_src_y';
        RAISE NOTICE 'TEST N3 PASSED: REFRESH MATERIALIZED VIEW accepterad';
    ELSE
        RAISE NOTICE 'TEST N3 SKIPPED: v_mat_src_y finns inte (N1 kan ha misslyckats)';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N3 FAILED: REFRESH MATERIALIZED VIEW orsakade fel: %', SQLERRM;
END $$;

-- N4: DROP MATERIALIZED VIEW
DO $$
BEGIN
    EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS sk0_ext_edge.v_mat_src_y';
    RAISE NOTICE 'TEST N4 PASSED: DROP MATERIALIZED VIEW accepterad';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST N4 FAILED: DROP MATERIALIZED VIEW orsakade fel: %', SQLERRM;
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP TABLE   IF EXISTS public.hex_edge_ref  CASCADE;
DROP SCHEMA  IF EXISTS sk1_kba_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0_ext_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0_sys_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk1_sys_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk3_ext_edge         CASCADE;
DROP SCHEMA  IF EXISTS sk0ext_partial       CASCADE;

\echo ''
\echo 'HEX TESTSVIT FÖR SPECIALFALL KLAR'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
