CREATE OR REPLACE FUNCTION public.validera_geometri(
    geom geometry, 
    tolerans float DEFAULT 0.001
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $BODY$
/******************************************************************************
 * Validerar geometrins kvalitet för användning i _kba_-scheman.
 * 
 * Kontrollerar:
 * 1. ST_IsValid       - Geometrin följer OGC-specifikationen
 * 2. NOT ST_IsEmpty   - Geometrin innehåller faktiska koordinater
 * 3. Inga duplicerade - Inga upprepade punkter inom toleransen
 * 4. Area > tolerans² - Polygoner har rimlig area (ej degenererade)
 * 5. Längd > tolerans - Linjer har rimlig längd (ej degenererade)
 *
 * PARAMETRAR:
 *   geom     - Geometri att validera
 *   tolerans - Tolerans i kartenheter (meter för SWEREF99 TM), default 0.001 (1mm)
 *
 * RETURVÄRDE:
 *   true  - Geometrin uppfyller alla kvalitetskrav
 *   false - Geometrin har kvalitetsproblem
 *
 * ANVÄNDNING:
 *   ALTER TABLE schema.tabell ADD CONSTRAINT validera_geom_tabellnamn
 *       CHECK (validera_geometri(geom));
 *
 * NOTERA:
 *   - Används endast för _kba_-scheman (manuellt redigerade data)
 *   - _ext_-scheman undantas då bulkladdning valideras i FME
 *   - NULL-geometrier hanteras av PostgreSQL:s CHECK-semantik (NULL = ok)
 ******************************************************************************/
BEGIN
    -- NULL-geometrier passerar (CHECK-semantik: NULL uppfyller constraint)
    IF geom IS NULL THEN
        RETURN true;
    END IF;

    RETURN 
        -- 1. OGC-valid geometri
        ST_IsValid(geom)
        -- 2. Inte tom geometri
        AND NOT ST_IsEmpty(geom)
        -- 3. Inga duplicerade punkter (jämför antal punkter före/efter borttagning)
        AND ST_NPoints(geom) = ST_NPoints(ST_RemoveRepeatedPoints(geom, tolerans))
        -- 4. Polygoner måste ha rimlig area (> 1mm² med default-tolerans)
        AND (ST_Dimension(geom) != 2 OR ST_Area(geom) > tolerans * tolerans)
        -- 5. Linjer måste ha rimlig längd (> 1mm med default-tolerans)
        AND (ST_Dimension(geom) != 1 OR ST_Length(geom) > tolerans);
END;
$BODY$;

ALTER FUNCTION public.validera_geometri(geometry, float)
    OWNER TO postgres;

COMMENT ON FUNCTION public.validera_geometri(geometry, float)
    IS 'Validerar geometrikvalitet för _kba_-scheman. Kontrollerar OGC-validitet, 
icke-tomhet, inga duplicerade punkter, och rimlig storlek (area/längd > tolerans).
Tolerans i meter (default 0.001 = 1mm för SWEREF99 TM). Används som CHECK-constraint 
på tabeller med manuellt redigerade data för att förhindra geometriproblem i FME-flöden.';
