-- ============================================================
-- HEX TESTSVIT FÖR GEOMETRIVALIDERING — GRUPP G
--
-- Testar varje typ av felaktig geometri genom:
--   (a) hex_forklara_geometrifel()  — korrekthet i felmeddelanden
--   (b) hex_validera_geometri()     — boolesk avvisning
--   (c) hex_kontrollera_geometri_trigger() — end-to-end via en _kba_-tabell
--
-- G1   NULL-geometri                       → godkänns (CHECK-semantik)
-- G2   OGC-ogiltig: självkorsande polygon (bowtie)
-- G3   OGC-ogiltig: ring inte sluten
-- G4   Tom geometri (ST_GeomFromText utan punkter)
-- G5   Dubblerade intilliggande punkter (exakt nolldistans)
-- G6   Degenererad polygon — area under tröskel [kontroll borttagen — nu INFO]
-- G7   Degenererad linje — längd under tröskel [kontroll borttagen — nu INFO]
-- G8   Självkorsande linje (åtta-form) [kontroll borttagen — nu INFO]
-- G9   Böjd geometri (CIRCULARSTRING)
-- G10  Giltig polygon                      → godkänns
-- G11  Giltig linje                        → godkänns
-- G12  Giltig punkt                        → godkänns
-- G15  3D-geometri (PolygonZ) — giltiga koordinater
-- G16  3D-geometri (PolygonZ) — degenererad (nollarea i XY) [areakontroll borttagen — INFO]
-- G17  MultiPolygon med en ogiltig ring
-- G18  MultiLineString med en självkorsande komponent [ST_IsSimple borttagen — INFO]
-- G19  Felmeddelande innehåller inga C-stil format-specifikatorer (regression: issue #74)
-- G20  Triggern avfyras före CHECK-villkoret — korrekt undantagsstruktur
-- G21  Trigger: giltig geometri-INSERT lyckas i _kba_-tabell
-- G22  Trigger: ogiltig geometri-INSERT avvisas med svenskt meddelande
-- G23  Trigger: ogiltig geometri-UPDATE avvisas
-- G24  Trigger: NULL-geometri tillåts genom triggern
-- G25  Trigger: degenererad polygon accepteras nu (storlekskontroller borttagna)
-- G26  Trigger: degenererad linje accepteras nu (storlekskontroller borttagna)
-- G27  Trigger: böjd geometri avvisas med geometrityp i meddelandet
--
-- Schema som används: sk1_kba_geomtest
-- Konvention: NOTICE = PASSED/INFO, WARNING = FAILED/BUG CONFIRMED
-- ============================================================

\echo ''
\echo '============================================================'
\echo 'HEX TESTSVIT FÖR GEOMETRIVALIDERING'
\echo '============================================================'

-- ============================================================
-- Städning och förberedelse
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_geomtest CASCADE;
CREATE SCHEMA sk1_kba_geomtest;

-- Tabell för triggertester (kba-schema → får trigger + CHECK-villkor)
CREATE TABLE sk1_kba_geomtest.testobj_y (
    naam text,
    geom geometry(Polygon, 3006)
);

CREATE TABLE sk1_kba_geomtest.testlijn_l (
    naam text,
    geom geometry(LineString, 3006)
);

\echo ''
\echo '--- GRUPP G: hex_forklara_geometrifel() — korrekthet i felmeddelanden ---'

-- ============================================================
-- G1: NULL → ska returnera NULL (giltigt enligt CHECK-semantik)
-- ============================================================
DO $$
DECLARE result text;
BEGIN
    result := public.hex_forklara_geometrifel(NULL::geometry);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G1 PASSED: NULL-geometri returnerar NULL (inget fel)';
    ELSE
        RAISE WARNING 'TEST G1 FAILED: NULL-geometri returnerade: %', result;
    END IF;
END $$;

-- ============================================================
-- G2: OGC-ogiltig: självkorsande polygon (bowtie/åtta-form-polygon)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Bowtie-polygon: ringen korsar sig själv
    geom := ST_GeomFromText('POLYGON((0 0, 2 2, 2 0, 0 2, 0 0))', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G2 PASSED: Bowtie-polygon upptäckt som OGC-ogiltig: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G2 FAILED: Bowtie-polygon upptäcktes inte som ogiltig (returnerade NULL)';
    ELSE
        RAISE WARNING 'TEST G2 FAILED: Oväntat meddelande: %', result;
    END IF;
END $$;

-- ============================================================
-- G3: OGC-ogiltig: polygon med dubblerade intilliggande ringpunkter som
--     orsakar en spets (självtangering) — annat OGC-brott än bowtie
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Ringen rör sig själv i en punkt (självtangering → OGC-ogiltig)
    geom := ST_GeomFromText(
        'POLYGON((0 0, 4 0, 4 4, 2 4, 2 2, 2 4, 0 4, 0 0))', 3006
    );
    result := public.hex_forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G3 PASSED: Självtangerande polygon upptäckt som OGC-ogiltig: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G3 FAILED: Självtangerande polygon upptäcktes inte som ogiltig';
    ELSE
        RAISE WARNING 'TEST G3 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G4: Tom geometri
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON EMPTY');
    result := public.hex_forklara_geometrifel(geom);
    IF result = 'Geometrin är tom (innehåller inga koordinater)' THEN
        RAISE NOTICE 'TEST G4 PASSED: Tom geometri korrekt identifierad';
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G4 FAILED: Tom geometri returnerade NULL (fångades inte)';
    ELSE
        RAISE WARNING 'TEST G4 FAILED: Oväntat meddelande: %', result;
    END IF;
END $$;

-- ============================================================
-- G5: Dubblerade intilliggande punkter (exakt nolldistans)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Linje med exakt dubblerad inre punkt: (10 0) förekommer två gånger i rad
    geom := ST_GeomFromText('LINESTRING(0 0, 10 0, 10 0, 20 0)', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result LIKE 'Geometrin innehåller exakta duplicerade%' THEN
        RAISE NOTICE 'TEST G5 PASSED: Exakt dubblerade punkter upptäckta: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G5 FAILED: Exakt dubblerade punkter upptäcktes inte';
    ELSE
        RAISE WARNING 'TEST G5 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G6: Degenererad polygon — areakontroll borttagen, geometrin accepteras nu
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText(
        'POLYGON((0 0, 0.002 0, 0.001 0.0005, 0 0))', 3006
    );
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G6 INFO: Degenererad polygon accepterad — area-/storlekskontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G6 INFO: Degenererad polygon flaggad av annan anledning: %', result;
    END IF;
END $$;

-- ============================================================
-- G7: Degenererad linje — längdkontroll borttagen, geometrin accepteras nu
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('LINESTRING(0 0, 0.0005 0)', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G7 INFO: Linje under en millimeter accepterad — längdkontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G7 INFO: Linje under en millimeter flaggad av annan anledning: %', result;
    END IF;
END $$;

-- ============================================================
-- G8: Självkorsande linje — ST_IsSimple-kontroll borttagen, geometrin accepteras nu
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('LINESTRING(0 0, 10 10, 10 0, 0 10)', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G8 INFO: Självkorsande linje accepterad — ST_IsSimple-kontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G8 INFO: Självkorsande linje flaggad av annan anledning: %', result;
    END IF;
END $$;

-- ============================================================
-- G9: Böjd geometri (CIRCULARSTRING)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('CIRCULARSTRING(0 0, 1 1, 2 0)');
    result := public.hex_forklara_geometrifel(geom);
    IF result LIKE 'Geometrin innehåller kurvsegment%' THEN
        RAISE NOTICE 'TEST G9 PASSED: Böjd geometri (CIRCULARSTRING) upptäckt: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G9 FAILED: CIRCULARSTRING upptäcktes inte som ej stödd';
    ELSE
        RAISE WARNING 'TEST G9 UNEXPECTED: %', result;
    END IF;
END $$;

-- ============================================================
-- G10: Giltig polygon → ska returnera NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON((0 0, 100 0, 100 100, 0 100, 0 0))', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G10 PASSED: Giltig polygon returnerar korrekt NULL (inget fel)';
    ELSE
        RAISE WARNING 'TEST G10 FAILED: Giltig polygon flaggad som ogiltig: %', result;
    END IF;
END $$;

-- ============================================================
-- G11: Giltig linje → ska returnera NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('LINESTRING(0 0, 100 100)', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G11 PASSED: Giltig linje returnerar korrekt NULL (inget fel)';
    ELSE
        RAISE WARNING 'TEST G11 FAILED: Giltig linje flaggad som ogiltig: %', result;
    END IF;
END $$;

-- ============================================================
-- G12: Giltig punkt → ska returnera NULL
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POINT(100 200)', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G12 PASSED: Giltig punkt returnerar korrekt NULL (inget fel)';
    ELSE
        RAISE WARNING 'TEST G12 FAILED: Giltig punkt flaggad som ogiltig: %', result;
    END IF;
END $$;

-- ============================================================
-- G15: 3D-polygon (PolygonZ) med giltig XY och Z — ska godkännas
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    geom := ST_GeomFromText('POLYGON Z((0 0 10, 100 0 11, 100 100 12, 0 100 13, 0 0 10))', 3006);
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G15 PASSED: Giltig 3D-polygon (PolygonZ) returnerar korrekt NULL';
    ELSE
        RAISE WARNING 'TEST G15 FAILED: Giltig PolygonZ flaggad som ogiltig: %', result;
    END IF;
END $$;

-- ============================================================
-- G16: 3D-polygon (PolygonZ) degenererad — kollineära punkter (spetsform)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- Extremt tunn polygon med area ≈ 0 även med Z-koordinater
    geom := ST_GeomFromText(
        'POLYGON Z((0 0 0, 0.0001 0 0, 0.0001 0.0001 0, 0 0.0001 0, 0 0 0))', 3006
    );
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G16 INFO: Mycket liten PolygonZ accepterad — areakontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G16 INFO: Mycket liten PolygonZ flaggad av annan anledning: %', result;
    END IF;
END $$;

-- ============================================================
-- G17: MultiPolygon med en ogiltig ring (bowtie-komponent)
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- En giltig polygon + en bowtie-polygon i en MultiPolygon
    geom := ST_GeomFromText(
        'MULTIPOLYGON(((0 0, 1 0, 1 1, 0 1, 0 0)), ((10 10, 12 12, 12 10, 10 12, 10 10)))',
        3006
    );
    result := public.hex_forklara_geometrifel(geom);
    IF result LIKE 'Geometrin är inte OGC-giltig:%' THEN
        RAISE NOTICE 'TEST G17 PASSED: MultiPolygon med ogiltig komponent upptäckt: %', result;
    ELSIF result IS NULL THEN
        RAISE WARNING 'TEST G17 FAILED: MultiPolygon med bowtie-komponent upptäcktes inte som ogiltig';
    ELSE
        RAISE NOTICE 'TEST G17 INFO: MultiPolygon-resultat: %', result;
    END IF;
END $$;

-- ============================================================
-- G18: MultiLineString med en självkorsande komponent
-- ============================================================
DO $$
DECLARE
    geom   geometry;
    result text;
BEGIN
    -- En giltig linje + en åtta-form-linje
    geom := ST_GeomFromText(
        'MULTILINESTRING((0 0, 10 0), (20 20, 30 30, 30 20, 20 30))',
        3006
    );
    result := public.hex_forklara_geometrifel(geom);
    IF result IS NULL THEN
        RAISE NOTICE 'TEST G18 INFO: MultiLineString med självkorsande komponent accepterad — ST_IsSimple-kontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G18 INFO: MultiLineString flaggad av annan anledning: %', result;
    END IF;
END $$;

\echo ''
\echo '--- GRUPP G: hex_validera_geometri() — boolesk avvisning ---'

-- ============================================================
-- G10b–G12b: Giltiga geometrier returnerar true
-- ============================================================
DO $$
BEGIN
    IF public.hex_validera_geometri(ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006)) THEN
        RAISE NOTICE 'TEST G10b PASSED: hex_validera_geometri returnerar true för giltig polygon';
    ELSE
        RAISE WARNING 'TEST G10b FAILED: hex_validera_geometri returnerar false för giltig polygon';
    END IF;

    IF public.hex_validera_geometri(ST_GeomFromText('LINESTRING(0 0, 100 100)', 3006)) THEN
        RAISE NOTICE 'TEST G11b PASSED: hex_validera_geometri returnerar true för giltig linje';
    ELSE
        RAISE WARNING 'TEST G11b FAILED: hex_validera_geometri returnerar false för giltig linje';
    END IF;

    IF public.hex_validera_geometri(ST_GeomFromText('POINT(100 200)', 3006)) THEN
        RAISE NOTICE 'TEST G12b PASSED: hex_validera_geometri returnerar true för giltig punkt';
    ELSE
        RAISE WARNING 'TEST G12b FAILED: hex_validera_geometri returnerar false för giltig punkt';
    END IF;
END $$;

-- ============================================================
-- G2b: OGC-ogiltig polygon returnerar false
-- ============================================================
DO $$
BEGIN
    IF NOT public.hex_validera_geometri(ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006)) THEN
        RAISE NOTICE 'TEST G2b PASSED: hex_validera_geometri returnerar false för bowtie-polygon';
    ELSE
        RAISE WARNING 'TEST G2b FAILED: hex_validera_geometri returnerar true för bowtie-polygon';
    END IF;
END $$;

-- ============================================================
-- G4b: Tom geometri returnerar false
-- ============================================================
DO $$
BEGIN
    IF NOT public.hex_validera_geometri(ST_GeomFromText('POLYGON EMPTY')) THEN
        RAISE NOTICE 'TEST G4b PASSED: hex_validera_geometri returnerar false för tom geometri';
    ELSE
        RAISE WARNING 'TEST G4b FAILED: hex_validera_geometri returnerar true för tom geometri';
    END IF;
END $$;

-- ============================================================
-- G5b: Exakt dubblerade punkter returnerar false
-- ============================================================
DO $$
BEGIN
    IF NOT public.hex_validera_geometri(
        ST_GeomFromText('LINESTRING(0 0, 10 0, 10 0, 20 0)', 3006)
    ) THEN
        RAISE NOTICE 'TEST G5b PASSED: hex_validera_geometri returnerar false för exakt dubblerade punkter';
    ELSE
        RAISE WARNING 'TEST G5b FAILED: hex_validera_geometri accepterar exakt dubblerade intilliggande punkter';
    END IF;
END $$;

-- ============================================================
-- G6b: Degenererad polygon accepteras nu (areakontroll borttagen)
-- ============================================================
DO $$
BEGIN
    IF public.hex_validera_geometri(
        ST_GeomFromText('POLYGON((0 0,0.002 0,0.001 0.0005,0 0))', 3006)
    ) THEN
        RAISE NOTICE 'TEST G6b INFO: hex_validera_geometri accepterar degenererad polygon — areakontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G6b INFO: hex_validera_geometri avvisar degenererad polygon av annan anledning';
    END IF;
END $$;

-- ============================================================
-- G7b: Degenererad linje accepteras nu (längdkontroll borttagen)
-- ============================================================
DO $$
BEGIN
    IF public.hex_validera_geometri(ST_GeomFromText('LINESTRING(0 0,0.0005 0)', 3006)) THEN
        RAISE NOTICE 'TEST G7b INFO: hex_validera_geometri accepterar linje under en millimeter — längdkontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G7b INFO: hex_validera_geometri avvisar linje under en millimeter av annan anledning';
    END IF;
END $$;

-- ============================================================
-- G8b: Självkorsande linje accepteras nu (ST_IsSimple borttagen)
-- ============================================================
DO $$
BEGIN
    IF public.hex_validera_geometri(ST_GeomFromText('LINESTRING(0 0,10 10,10 0,0 10)', 3006)) THEN
        RAISE NOTICE 'TEST G8b INFO: hex_validera_geometri accepterar självkorsande linje — ST_IsSimple-kontroll borttagen med avsikt';
    ELSE
        RAISE NOTICE 'TEST G8b INFO: hex_validera_geometri avvisar självkorsande linje av annan anledning';
    END IF;
END $$;

-- ============================================================
-- G9b: CIRCULARSTRING returnerar false
-- ============================================================
DO $$
BEGIN
    IF NOT public.hex_validera_geometri(ST_GeomFromText('CIRCULARSTRING(0 0,1 1,2 0)')) THEN
        RAISE NOTICE 'TEST G9b PASSED: hex_validera_geometri returnerar false för CIRCULARSTRING';
    ELSE
        RAISE WARNING 'TEST G9b FAILED: hex_validera_geometri accepterar CIRCULARSTRING';
    END IF;
END $$;

-- ============================================================
-- G1b: NULL returnerar true (CHECK-villkorssemantik)
-- ============================================================
DO $$
BEGIN
    IF public.hex_validera_geometri(NULL::geometry) THEN
        RAISE NOTICE 'TEST G1b PASSED: hex_validera_geometri returnerar true för NULL (CHECK-semantik)';
    ELSE
        RAISE WARNING 'TEST G1b FAILED: hex_validera_geometri returnerar false för NULL';
    END IF;
END $$;

\echo ''
\echo '--- GRUPP G: Regression — säkerhet för format()-specifikatorer (issue #74) ---'

-- ============================================================
-- G19: Felmeddelanden får inte innehålla C-stil format-specifikatorer.
--      Buggen var att %.0f / %.6f / %.3f orsakade PostgreSQL-fel.
--      Vi verifierar att varje meddelandeproducerande gren körs utan fel.
-- ============================================================
DO $$
DECLARE
    msg text;
    ok  boolean := true;
BEGIN
    -- OGC-ogiltig gren (bowtie)
    BEGIN
        msg := public.hex_forklara_geometrifel(ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: OGC-ogiltig-grenen gav: %', SQLERRM;
        ok := false;
    END;

    -- Tom-gren
    BEGIN
        msg := public.hex_forklara_geometrifel(ST_GeomFromText('POLYGON EMPTY'));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Tom-grenen gav: %', SQLERRM;
        ok := false;
    END;

    -- Dubblettpunkter-gren
    BEGIN
        msg := public.hex_forklara_geometrifel(
            ST_GeomFromText('LINESTRING(0 0, 10 0, 10 0, 20 0)', 3006)
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Dubblettpunkter-grenen gav: %', SQLERRM;
        ok := false;
    END;

    -- Böjd geometri-gren
    BEGIN
        msg := public.hex_forklara_geometrifel(ST_GeomFromText('CIRCULARSTRING(0 0,1 1,2 0)'));
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'TEST G19 FAILED: Böjd-geometri-grenen gav: %', SQLERRM;
        ok := false;
    END;

    IF ok THEN
        RAISE NOTICE 'TEST G19 PASSED: Alla grenar i hex_forklara_geometrifel() körs utan format()-fel';
    END IF;
END $$;

\echo ''
\echo '--- GRUPP G: End-to-end triggertester på _kba_-tabell ---'

-- ============================================================
-- G20: Undantagsstruktur — triggern kastar EXCEPTION med HINT
-- ============================================================
DO $$
DECLARE
    msg  text;
    hint text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('bowtie', ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));

    RAISE WARNING 'TEST G20 FAILED: Bowtie-polygon avvisades inte av triggern';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT, hint = PG_EXCEPTION_HINT;
        IF msg LIKE 'Ogiltig geometri i tabellen%'
           AND hint LIKE '%QGIS%' THEN
            RAISE NOTICE 'TEST G20 PASSED: Triggern kastar EXCEPTION med svenskt meddelande och QGIS-HINT';
        ELSE
            RAISE WARNING 'TEST G20 FAILED: Fel undantagsstruktur. msg=%, hint=%', msg, hint;
        END IF;
END $$;

-- ============================================================
-- G21: Giltig geometri-INSERT lyckas
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('valid', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006));
    RAISE NOTICE 'TEST G21 PASSED: Giltig polygon-INSERT accepterad av _kba_-tabellen';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G21 FAILED: Giltig polygon-INSERT avvisad: %', SQLERRM;
END $$;

-- ============================================================
-- G22: OGC-ogiltig geometri-INSERT avvisas med svenskt meddelande
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('bowtie', ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006));
    RAISE WARNING 'TEST G22 FAILED: Bowtie-INSERT avvisades inte';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE 'Ogildig%' OR msg LIKE 'Ogiltig geometri%' THEN
            RAISE NOTICE 'TEST G22 PASSED: OGC-ogiltig INSERT avvisad: %', left(msg, 100);
        ELSE
            RAISE WARNING 'TEST G22 FAILED: Oväntat avvisningsmeddelande: %', msg;
        END IF;
END $$;

-- ============================================================
-- G23: Ogiltig geometri-UPDATE avvisas
-- ============================================================
DO $$
DECLARE msg text;
BEGIN
    -- Säkerställ först att en giltig rad finns (G21 kan ha infogat den)
    IF NOT EXISTS (SELECT 1 FROM sk1_kba_geomtest.testobj_y WHERE naam = 'valid') THEN
        INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
        VALUES ('valid', ST_GeomFromText('POLYGON((0 0,100 0,100 100,0 100,0 0))', 3006));
    END IF;

    UPDATE sk1_kba_geomtest.testobj_y
    SET geom = ST_GeomFromText('POLYGON((0 0,2 2,2 0,0 2,0 0))', 3006)
    WHERE naam = 'valid';

    RAISE WARNING 'TEST G23 FAILED: Bowtie-UPDATE avvisades inte';
EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
        IF msg LIKE 'Ogiltig geometri%' THEN
            RAISE NOTICE 'TEST G23 PASSED: UPDATE med ogiltig geometri avvisad: %', left(msg, 100);
        ELSE
            RAISE WARNING 'TEST G23 FAILED: Oväntat meddelande vid UPDATE: %', msg;
        END IF;
END $$;

-- ============================================================
-- G24: NULL-geometri tillåts genom triggern
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom) VALUES ('null_geom', NULL);
    RAISE NOTICE 'TEST G24 PASSED: NULL-geometri-INSERT accepterad av triggern';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G24 FAILED: NULL-geometri-INSERT avvisad: %', SQLERRM;
END $$;

-- ============================================================
-- G25: Degenererad polygon accepteras nu (area-/storlekskontroller borttagna)
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testobj_y (naam, geom)
    VALUES ('tiny', ST_GeomFromText('POLYGON((0 0,0.002 0,0.001 0.0005,0 0))', 3006));
    RAISE NOTICE 'TEST G25 PASSED: Degenererad polygon-INSERT accepterad — storlekskontroller borttagna med avsikt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G25 FAILED: Degenererad polygon-INSERT oväntat avvisad: %', SQLERRM;
END $$;

-- ============================================================
-- G26: Degenererad linje accepteras nu (längdkontroll borttagen)
-- ============================================================
DO $$
BEGIN
    INSERT INTO sk1_kba_geomtest.testlijn_l (naam, geom)
    VALUES ('tiny', ST_GeomFromText('LINESTRING(0 0,0.0005 0)', 3006));
    RAISE NOTICE 'TEST G26 PASSED: Degenererad linje-INSERT accepterad — längdkontroll borttagen med avsikt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST G26 FAILED: Degenererad linje-INSERT oväntat avvisad: %', SQLERRM;
END $$;

-- ============================================================
-- G27: Meddelandet för böjd geometri innehåller geometrityptns namn
-- ============================================================
DO $$
DECLARE
    msg  text;
    geom geometry;
BEGIN
    -- Typomvandla CIRCULARSTRING till geometry så den passar i den generiska geom-kolumnen
    geom := ST_GeomFromText('CIRCULARSTRING(0 0, 1 1, 2 0)');

    -- Testa direkt mot hex_forklara_geometrifel (triggerns kolumntyp kan avvisa typomvandlingen)
    msg := public.hex_forklara_geometrifel(geom);
    IF msg LIKE '%kurvsegment%' AND msg ILIKE '%circularstring%' THEN
        RAISE NOTICE 'TEST G27 PASSED: Meddelandet för böjd geometri innehåller typnamnet: %', msg;
    ELSIF msg IS NULL THEN
        RAISE WARNING 'TEST G27 FAILED: CIRCULARSTRING returnerade NULL från hex_forklara_geometrifel';
    ELSE
        RAISE WARNING 'TEST G27 FAILED: Oväntat meddelande: %', msg;
    END IF;
END $$;

-- ============================================================
-- Städning
-- ============================================================
DROP SCHEMA IF EXISTS sk1_kba_geomtest CASCADE;

\echo ''
\echo 'HEX TESTSVIT FÖR GEOMETRIVALIDERING KLAR'
\echo 'NOTICE = PASSED/INFO,  WARNING = FAILED/BUG CONFIRMED'
