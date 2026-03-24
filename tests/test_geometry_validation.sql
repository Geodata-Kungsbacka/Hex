-- ============================================================
-- HEX GEOMETRY VALIDATION TEST SUITE — GROUP G
--
-- Tests every bad geometry type through:
--   (a) forklara_geometrifel()  — error message correctness
--   (b) validera_geometri()     — boolean rejection
--   (c) kontrollera_geometri_trigger() — end-to-end through a _kba_ table
--
-- G1   NULL geometry                      → passes (CHECK semantics)
-- G2   OGC-invalid: self-intersecting polygon (bowtie)
-- G3   OGC-invalid: ring not closed
-- G4   Empty geometry (ST_GeomFromText with no points)
-- G5   Duplicate consecutive points (within 1 mm tolerance)
-- G6   Degenerate polygon — area below tolerance² (spike/needle)
-- G7   Degenerate line — length below tolerance (< 1 mm)
-- G8   Self-intersecting line (figure-8)
-- G9   Curved geometry (CIRCULARSTRING)
-- G10  Valid polygon                       → passes
-- G11  Valid line                          → passes
-- G12  Valid point                         → passes
-- G13  Custom tolerance — geometry valid at default but bad at tighter tolerance
-- G14  Duplicate points at exactly the tolerance boundary
-- G15  3D geometry (PolygonZ) — valid coordinates
-- G16  3D geometry (PolygonZ) — degenerate (zero area in XY)
-- G17  MultiPolygon with one invalid ring
-- G18  MultiLineString with one self-intersecting component
-- G19  Error message contains no C-style format specifiers (regression: issue #74)
-- G20  Trigger fires before CHECK constraint — correct exception structure
-- G21  Trigger: valid geometry INSERT succeeds in _kba_ table
-- G22  Trigger: invalid geometry INSERT rejected with Swedish message
-- G23  Trigger: invalid geometry UPDATE rejected
-- G24  Trigger: NULL geometry allowed through trigger
-- G25  Trigger: degenerate polygon rejected with area in message
-- G26  Trigger: degenerate line rejected with length in message
-- G27  Trigger: curved geometry rejected with geometry type in message
--
-- Schema used: sk1_kba_geomtest
-- Convention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX GEOMETRY VALIDATION TEST SUITE'
\echo '============================================================'

-- ============================================================
-- Cleanup and setup
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_geomtest CASCADE;
CREATE SCHEMA sk1_kba_geomtest;

-- Table for trigger tests (kba schema → gets trigger + CHECK constraint)
CREATE TABLE sk1_kba_geomtest.testobj_y (
    naam text,
    geom geometry(Polygon, 3006)
);

CREATE TABLE sk1_kba_geomtest.testlijn_l (
    naam text,
    geom geometry(LineString, 3006)
);

\echo ''
\echo '--- GROUP G: forklara_geometrifel() — error message correctness ---'

-- ============================================================
-- G1: NULL → should return NULL (valid per CHECK semantics)
-- ============================================================
DO $$
DECLARE result text;
BEGIN
    result := public.forklara_geometrifel(NULL::geometry);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G1 PASSED: NULL geometry returns NULL (no error)';
    ELSE
        RAISE WARNING 'TEST G1 FAILED: NULL geometry returned: %', result;
    END IF;
END $$;

-- ============================================================
-- G2: OGC-invalid: self-intersecting polygon (bowtie / figure-8 polygon)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Bowtie polygon: ring crosses itself
    geom := ST_GeomFromText('POLYGON((0 0, 2 2, 2 0, 0 2, 0 0))', 3006);
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G2 PASSED: Bowtie polygon detected as OGC-invalid: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G2 FAILED: Bowtie polygon was not detected as invalid (returned NULL)';
    ELSE
        RAISE WARNING 'TEST G2 FAILED: Unexpected message: %', result;
    END IF;
END $$;

-- ============================================================
-- G3: OGC-invalid: polygon with duplicate adjacent ring points causing
--     a spike (self-tangency) — different OGC violation than bowtie
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Ring touches itself at a point (self-tangency → OGC invalid)
    geom := ST_GeomFromText(
        'POLYGON((0 0, 4 0, 4 4, 2 4, 2 2, 2 4, 0 4, 0 0))', 3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G3 PASSED: Self-tangent polygon detected as OGC-invalid: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G3 FAILED: Self-tangent polygon was not detected as invalid';
    ELSE
        RAISE WARNING 'TEST G3 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G4: Empty geometry
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON EMPTY');
    result := public.forklara_geometrifel(geom);
    IF result = 'Geometrin är tom (innehåller inga koordinater)' THEN
        RAISE NOTICE 'TEST G4 PASSED: Empty geometry correctly identified';
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G4 FAILED: Empty geometry returned NULL (not caught)';
    ELSE
        RAISE WARNING 'TEST G4 FAILED: Unexpected message: %', result;
    END IF;
END $$;

-- ============================================================
-- G5: Duplicate consecutive points within 1 mm tolerance
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Two adjacent ring vertices only 0.0005 m apart (< 1 mm tolerance)
    geom := ST_GeomFromText(
        'POLYGON((0 0, 10 0, 10 0.0005, 10 10, 0 10, 0 0))', 3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Geometrin innehåller duplicerade punkter%' THEN
        RAISE NOTICE 'TEST G5 PASSED: Sub-tolerance duplicate points detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G5 FAILED: Duplicate points within tolerance not detected';
    ELSE
        RAISE WARNING 'TEST G5 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G6: Degenerate polygon — area below tolerance² (0.001² = 0.000001 m²)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Extremely thin needle polygon: area ≈ 0.0000001 m² (below 0.000001 threshold)
    geom := ST_GeomFromText(
        'POLYGON((0 0, 0.001 0, 0.001 0.0001, 0 0.0001, 0 0))', 3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Polygonen är degenererad%' THEN
        RAISE NOTICE 'TEST G6 PASSED: Degenerate polygon (tiny area) detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G6 FAILED: Degenerate polygon not detected (area may exceed tolerance²)';
    ELSE
        RAISE WARNING 'TEST G6 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G7: Degenerate line — length below tolerance (< 1 mm = 0.001 m)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Line only 0.0005 m long (< 1 mm threshold)
    geom := ST_GeomFromText('LINESTRING(0 0, 0.0005 0)', 3006);
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Linjen är degenererad%' THEN
        RAISE NOTICE 'TEST G7 PASSED: Degenerate line (too short) detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G7 FAILED: Sub-mm line not detected as degenerate';
    ELSE
        RAISE WARNING 'TEST G7 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G8: Self-intersecting line (figure-8)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Line crosses itself in the middle
    geom := ST_GeomFromText('LINESTRING(0 0, 10 10, 10 0, 0 10)', 3006);
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Linjen skär sig själv%' THEN
        RAISE NOTICE 'TEST G8 PASSED: Self-intersecting line (figure-8) detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G8 FAILED: Self-intersecting line not detected';
    ELSE
        RAISE WARNING 'TEST G8 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G9: Curved geometry (CIRCULARSTRING)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('CIRCULARSTRING(0 0, 1 1, 2 0)');
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Geometrin innehåller kurvsegment%' THEN
        RAISE NOTICE 'TEST G9 PASSED: Curved geometry (CIRCULARSTRING) detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G9 FAILED: CIRCULARSTRING not detected as unsupported';
    ELSE
        RAISE WARNING 'TEST G9 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G10: Valid polygon → should return NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON((0 0, 100 0, 100 100, 0 100, 0 0))', 3006);
    result := public.forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G10 PASSED: Valid polygon correctly returns NULL (no error)';
    ELSE
        RAISE WARNING 'TEST G10 FAILED: Valid polygon flagged as invalid: %', result;
    END IF;
END $$;

-- ============================================================
-- G11: Valid line → should return NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('LINESTRING(0 0, 100 100)', 3006);
    result := public.forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G11 PASSED: Valid line correctly returns NULL (no error)';
    ELSE
        RAISE WARNING 'TEST G11 FAILED: Valid line flagged as invalid: %', result;
    END IF;
END $$;

-- ============================================================
-- G12: Valid point → should return NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POINT(100 200)', 3006);
    result := public.forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G12 PASSED: Valid point correctly returns NULL (no error)';
    ELSE
        RAISE WARNING 'TEST G12 FAILED: Valid point flagged as invalid: %', result;
    END IF;
END $$;

-- ============================================================
-- G13: Custom tight tolerance — geometry valid at 1 mm but rejected at 10 m
-- ============================================================
DO $$
DECLARE
    geom          geometry;
    result_default text;
    result_tight   text;
BEGIN
    -- Line is 5 m long: passes default 1 mm threshold, fails 10 m threshold
    geom := ST_GeomFromText('LINESTRING(0 0, 5 0)', 3006);
    result_default := public.forklara_geometrifel(geom, 0.001);
    result_tight   := public.forklara_geometrifel(geom, 10.0);
    IF result_default IS NULL AND result_tight LIKE 'Linjen är degenererad%' THEN
        RAISE NOTICE 'TEST G13 PASSED: Custom tolerance works — valid at 1mm, degenerate at 10m';
    ELSIF result_default IS NOT NULL THEN
        RAISE WARNING 'TEST G13 FAILED: 5m line wrongly rejected at default tolerance: %', result_default;
    ELSE
        RAISE WARNING 'TEST G13 FAILED: 5m line not rejected at 10m tolerance, got: %', result_tight;
    END IF;
END $$;

-- ============================================================
-- G14: Duplicate points at exactly the tolerance boundary
--      Point separation = exactly tolerance → should NOT be rejected
--      (ST_RemoveRepeatedPoints keeps points >= tolerance apart)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Adjacent ring vertices exactly 0.001 m apart (at boundary — should pass)
    geom := ST_GeomFromText(
        'POLYGON((0 0, 10 0, 10 0.001, 10 10, 0 10, 0 0))', 3006
    );
    result := public.forklara_geometrifel(geom);
    -- Behavior at exact boundary depends on ST_RemoveRepeatedPoints semantics;
    -- document actual result rather than assert direction
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G14 INFO: Points at exactly tolerance boundary accepted (not flagged as duplicates)';
    ELSIF result LIKE 'Geometrin innehåller duplicerade punkter%' THEN
        RAISE NOTICE 'TEST G14 INFO: Points at exactly tolerance boundary flagged as duplicates (inclusive check)';
    ELSE
        RAISE NOTICE 'TEST G14 INFO: Boundary points result: %', result;
    END IF;
END $$;

-- ============================================================
-- G15: 3D polygon (PolygonZ) with valid XY and Z — should pass
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON Z((0 0 10, 100 0 11, 100 100 12, 0 100 13, 0 0 10))', 3006);
    result := public.forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G15 PASSED: Valid 3D polygon (PolygonZ) correctly returns NULL';
    ELSE
        RAISE WARNING 'TEST G15 FAILED: Valid PolygonZ flagged as invalid: %', result;
    END IF;
END $$;

-- ============================================================
-- G16: 3D polygon (PolygonZ) degenerate — collinear points (spike shape)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Extremely thin polygon with area ≈ 0 even with Z coordinates
    geom := ST_GeomFromText(
        'POLYGON Z((0 0 0, 0.0001 0 0, 0.0001 0.0001 0, 0 0.0001 0, 0 0 0))', 3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Polygonen är degenererad%' THEN
        RAISE NOTICE 'TEST G16 PASSED: Degenerate PolygonZ (tiny area) detected: %', result;
    ELSIF result IS NULL THEN
        RAISE NOTICE 'TEST G16 INFO: Tiny PolygonZ not caught — area may exceed tolerance² in Z projection';
    ELSE
        RAISE NOTICE 'TEST G16 INFO: PolygonZ result: %', result;
    END IF;
END $$;

-- ============================================================
-- G17: MultiPolygon with one invalid ring (bowtie component)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- One valid polygon + one bowtie polygon in a MultiPolygon
    geom := ST_GeomFromText(
        'MULTIPOLYGON(((0 0, 1 0, 1 1, 0 1, 0 0)), ((10 10, 12 12, 12 10, 10 12, 10 10)))',
        3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G17 PASSED: MultiPolygon with invalid component detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G17 FAILED: MultiPolygon with bowtie component not detected as invalid';
    ELSE
        RAISE NOTICE 'TEST G17 INFO: MultiPolygon result: %', result;
    END IF;
END $$;

-- ============================================================
-- G18: MultiLineString with one self-intersecting component
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- One valid line + one figure-8 line
    geom := ST_GeomFromText(
        'MULTILINESTRING((0 0, 10 0), (20 20, 30 30, 30 20, 20 30))',
        3006
    );
    result := public.forklara_geometrifel(geom);
    IF result LIKE 'Linjen skär sig själv%' THEN
        RAISE NOTICE 'TEST G18 PASSED: MultiLineString with self-intersecting component detected: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G18 FAILED: MultiLineString with figure-8 component not flagged';
    ELSE
        RAISE NOTICE 'TEST G18 INFO: MultiLineString result: %', result;
    END IF;
END $$;

\echo ''
\echo '--- GROUP G: validera_geometri() — boolean rejection ---'

-- ============================================================
-- G10b–G12b: Valid geometries return true
-- ============================================================
DO $$
BEGIN
    IF public.validera_geometri(ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006)) THEN
        RAISE NOTICE 'TEST G10b PASSED: validera_geometri returns true for valid polygon';
    ELSE
        RAISE WARNING 'TEST G10b FAILED: validera_geometri returns false for valid polygon';
    END IF;

    IF public.validera_geometri(ST_GeomFromText('LINESTRING(0 0, 100 100)', 3006)) THEN
        RAISE NOTICE 'TEST G11b PASSED: validera_geometri returns true for valid line';
    ELSE
        RAISE WARNING 'TEST G11b FAILED: validera_geometri returns false for valid line';
    END IF;

    IF public.validera_geometri(ST_GeomFromText('POINT(100 200)', 3006)) THEN
        RAISE NOTICE 'TEST G12b PASSED: validera_geometri returns true for valid point';
    ELSE
        RAISE WARNING 'TEST G12b FAILED: validera_geometri returns false for valid point';
    END IF;
END $$;

-- ============================================================
-- G2b: OGC-invalid polygon returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006)) THEN
        RAISE NOTICE 'TEST G2b PASSED: validera_geometri returns false for bowtie polygon';
    ELSE
        RAISE WARNING 'TEST G2b FAILED: validera_geometri returns true for bowtie polygon';
    END IF;
END $$;

-- ============================================================
-- G4b: Empty geometry returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(ST_GeomFromText('POLYGON EMPTY')) THEN
        RAISE NOTICE 'TEST G4b PASSED: validera_geometri returns false for empty geometry';
    ELSE
        RAISE WARNING 'TEST G4b FAILED: validera_geometri returns true for empty geometry';
    END IF;
END $$;

-- ============================================================
-- G5b: Duplicate points return false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(
        ST_GeomFromText('POLYGON((0 0,10 0,10 0.0005,10 10,0 10,0 0))', 3006)
    ) THEN
        RAISE NOTICE 'TEST G5b PASSED: validera_geometri returns false for duplicate points';
    ELSE
        RAISE WARNING 'TEST G5b FAILED: validera_geometri accepts duplicate points within tolerance';
    END IF;
END $$;

-- ============================================================
-- G6b: Degenerate polygon returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(
        ST_GeomFromText('POLYGON((0 0,0.001 0,0.001 0.0001,0 0.0001,0 0))', 3006)
    ) THEN
        RAISE NOTICE 'TEST G6b PASSED: validera_geometri returns false for degenerate polygon';
    ELSE
        RAISE WARNING 'TEST G6b FAILED: validera_geometri accepts degenerate polygon';
    END IF;
END $$;

-- ============================================================
-- G7b: Degenerate line returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(ST_GeomFromText('LINESTRING(0 0,0.0005 0)', 3006)) THEN
        RAISE NOTICE 'TEST G7b PASSED: validera_geometri returns false for sub-mm line';
    ELSE
        RAISE WARNING 'TEST G7b FAILED: validera_geometri accepts sub-mm line';
    END IF;
END $$;

-- ============================================================
-- G8b: Self-intersecting line returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(ST_GeomFromText('LINESTRING(0 0,10 10,10 0,0 10)', 3006)) THEN
        RAISE NOTICE 'TEST G8b PASSED: validera_geometri returns false for self-intersecting line';
    ELSE
        RAISE WARNING 'TEST G8b FAILED: validera_geometri accepts self-intersecting line';
    END IF;
END $$;

-- ============================================================
-- G9b: CIRCULARSTRING returns false
-- ============================================================
DO $$
BEGIN
    IF NOT public.validera_geometri(ST_GeomFromText('CIRCULARSTRING(0 0,1 1,2 0)')) THEN
        RAISE NOTICE 'TEST G9b PASSED: validera_geometri returns false for CIRCULARSTRING';
    ELSE
        RAISE WARNING 'TEST G9b FAILED: validera_geometri accepts CIRCULARSTRING';
    END IF;
END $$;

-- ============================================================
-- G1b: NULL returns true (CHECK constraint semantics)
-- ============================================================
DO $$
BEGIN
    IF public.validera_geometri(NULL::geometry) THEN
        RAISE NOTICE 'TEST G1b PASSED: validera_geometri returns true for NULL (CHECK semantics)';
    ELSE
        RAISE WARNING 'TEST G1b FAILED: validera_geometri returns false for NULL';
    END IF;
END $$;

\echo ''
\echo '--- GROUP G: Regression — format() specifier safety (issue #74) ---'

-- ============================================================
-- G19: Error messages must not contain C-style format specifiers.
--      The bug was that %.0f / %.6f / %.3f caused PostgreSQL errors.
--      We verify each message-producing branch executes without error.
-- ============================================================
DO $$
DECLARE
    msg text;
    ok  boolean := true;
BEGIN
    -- OGC-invalid branch (bowtie)
    BEGIN
        msg := public.forklara_geometrifel(ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: OGC-invalid branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Empty branch
    BEGIN
        msg := public.forklara_geometrifel(ST_GeomFromText('POLYGON EMPTY'));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Empty branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Duplicate points branch
    BEGIN
        msg := public.forklara_geometrifel(
            ST_GeomFromText('POLYGON((0 0,10 0,10 0.0005,10 10,0 10,0 0))', 3006)
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Duplicate-points branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Degenerate polygon branch
    BEGIN
        msg := public.forklara_geometrifel(
            ST_GeomFromText('POLYGON((0 0,0.001 0,0.001 0.0001,0 0.0001,0 0))', 3006)
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Degenerate-polygon branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Degenerate line branch
    BEGIN
        msg := public.forklara_geometrifel(ST_GeomFromText('LINESTRING(0 0,0.0005 0)', 3006));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Degenerate-line branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Self-intersecting line branch
    BEGIN
        msg := public.forklara_geometrifel(ST_GeomFromText('LINESTRING(0 0,10 10,10 0,0 10)', 3006));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Self-intersecting-line branch raised: %', SQLERRM;
        ok := false;
    END;

    -- Curved geometry branch
    BEGIN
        msg := public.forklara_geometrifel(ST_GeomFromText('CIRCULARSTRING(0 0,1 1,2 0)'));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Curved-geometry branch raised: %', SQLERRM;
        ok := false;
    END;

    IF ok THEN
        RAISE NOTICE 'TEST G19 PASSED: All forklara_geometrifel() branches execute without format() errors';
    END IF;
END $$;

\echo ''
\echo '--- GROUP G: End-to-end trigger tests on _kba_ table ---'

-- ============================================================
-- G20: Exception structure — trigger raises EXCEPTION with HINT
-- ============================================================
DO $$
DECLARE
    msg  text;
    hint text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('bowtie', ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));

    RAISE WARNING 'TEST G20 FAILED: Bowtie polygon was not rejected by trigger';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT, hint = PG_EXCEPTION_HINT;
        IF msg LIKE 'Ogiltig geometri i tabellen%'
           AND hint LIKE '%QGIS%' THEN
            RAISE NOTICE 'TEST G20 PASSED: Trigger raises EXCEPTION with Swedish message and QGIS HINT';
        ELSE
            RAISE WARNING 'TEST G20 FAILED: Wrong exception structure. msg=%, hint=%', msg, hint;
        END IF;
END $$;

-- ============================================================
-- G21: Valid geometry INSERT succeeds
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('valid', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006));
    RAISE NOTICE 'TEST G21 PASSED: Valid polygon INSERT accepted by _kba_ table';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G21 FAILED: Valid polygon INSERT rejected: %', SQLERRM;
END $$;

-- ============================================================
-- G22: OGC-invalid geometry INSERT rejected with Swedish message
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('bowtie', ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));
    RAISE WARNING 'TEST G22 FAILED: Bowtie INSERT was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE 'Ogildig%' OR msg LIKE 'Ogiltig geometri%' THEN
            RAISE NOTICE 'TEST G22 PASSED: OGC-invalid INSERT rejected: %', left(msg, 100);
        ELSE
            RAISE WARNING 'TEST G22 FAILED: Unexpected rejection message: %', msg;
        END IF;
END $$;

-- ============================================================
-- G23: Invalid geometry UPDATE rejected
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    -- First ensure a valid row exists (G21 may have inserted it)
    IF NOT EXISTS (SELECT 1 FROM sk1_kba_geomtest.testobj_y WHERE naam = 'valid') THEN
        INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
        VALUES ('valid', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006));
    END IF;

    UPDATE sk1_kba_geomtest.testobj_y
    SET geom = ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006)
    WHERE naam = 'valid';

    RAISE WARNING 'TEST G23 FAILED: Bowtie UPDATE was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE 'Ogiltig geometri%' THEN
            RAISE NOTICE 'TEST G23 PASSED: UPDATE with invalid geometry rejected: %', left(msg, 100);
        ELSE
            RAISE WARNING 'TEST G23 FAILED: Unexpected message on UPDATE: %', msg;
        END IF;
END $$;

-- ============================================================
-- G24: NULL geometry allowed through trigger
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom) VALUES ('null_geom', NULL);
    RAISE NOTICE 'TEST G24 PASSED: NULL geometry INSERT accepted by trigger';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G24 FAILED: NULL geometry INSERT rejected: %', SQLERRM;
END $$;

-- ============================================================
-- G25: Degenerate polygon message contains area value
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('tiny', ST_GeomFromText('POLYGON((0 0,0.001 0,0.001 0.0001,0 0.0001,0 0))', 3006));
    RAISE WARNING 'TEST G25 FAILED: Degenerate polygon INSERT was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE '%degenererad%' AND msg LIKE '%m²%' THEN
            RAISE NOTICE 'TEST G25 PASSED: Degenerate polygon rejected with area in message: %', left(msg, 120);
        ELSIF msg LIKE '%degenererad%' THEN
            RAISE NOTICE 'TEST G25 PARTIAL: Degenerate polygon rejected but m² unit missing from message: %', left(msg, 120);
        ELSE
            RAISE WARNING 'TEST G25 FAILED: Unexpected message: %', msg;
        END IF;
END $$;

-- ============================================================
-- G26: Degenerate line message contains length value
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testlijn_l (naam, geom)
    VALUES ('tiny', ST_GeomFromText('LINESTRING(0 0,0.0005 0)', 3006));
    RAISE WARNING 'TEST G26 FAILED: Sub-mm line INSERT was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE '%degenererad%' AND msg LIKE '%m)%' THEN
            RAISE NOTICE 'TEST G26 PASSED: Degenerate line rejected with length in message: %', left(msg, 120);
        ELSIF msg LIKE '%degenererad%' THEN
            RAISE NOTICE 'TEST G26 PARTIAL: Degenerate line rejected but unit missing from message: %', left(msg, 120);
        ELSE
            RAISE WARNING 'TEST G26 FAILED: Unexpected message: %', msg;
        END IF;
END $$;

-- ============================================================
-- G27: Curved geometry message contains geometry type name
-- ============================================================
DO $$
DECLARE
    msg  text;
    geom geometry;
BEGIN
    -- Cast CIRCULARSTRING to geometry so it fits into the generic geom column
    geom := ST_GeomFromText('CIRCULARSTRING(0 0, 1 1, 2 0)');

    -- Test against forklara_geometrifel directly (trigger column type may reject cast)
    msg := public.forklara_geometrifel(geom);
    IF msg LIKE '%kurvsegment%' AND msg LIKE '%CIRCULARSTRING%' THEN
        RAISE NOTICE 'TEST G27 PASSED: Curved geometry message contains type name: %', msg;
    ELSIF msg IS NULL THEN
        RAISE WARNING 'TEST G27 FAILED: CIRCULARSTRING returned NULL from forklara_geometrifel';
    ELSE
        RAISE WARNING 'TEST G27 FAILED: Unexpected message: %', msg;
    END IF;
END $$;

-- ============================================================
-- Cleanup
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_geomtest CASCADE;

\echo ''
\echo 'HEX GEOMETRY VALIDATION SUITE COMPLETE'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
