DROP FUNCTION IF EXISTS public.validera_geometri(geometry, float);

CREATE OR REPLACE FUNCTION public.validera_geometri(
    geom geometry
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
 * 3. Inga duplicerade - Inga exakt identiska konsekutiva punkter
 * 4. NOT ST_HasArc    - Geometrin innehåller inga kurvsegment (stöds ej i systemet)
 *
 * PARAMETRAR:
 *   geom - Geometri att validera
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
    IF geom IS NULL THEN
        RETURN true;
    END IF;

    RETURN
        ST_IsValid(geom)
        AND NOT ST_IsEmpty(geom)
        AND ST_NPoints(geom) = ST_NPoints(ST_RemoveRepeatedPoints(geom))
        AND NOT ST_HasArc(geom);
END;
$BODY$;

ALTER FUNCTION public.validera_geometri(geometry)
    OWNER TO postgres;

COMMENT ON FUNCTION public.validera_geometri(geometry)
    IS 'Validerar geometrikvalitet för _kba_-scheman. Kontrollerar OGC-validitet,
icke-tomhet, inga exakta konsekutiva duplicerade punkter (ST_RemoveRepeatedPoints),
samt att geometrin inte innehåller kurvsegment (ST_HasArc).
Används som CHECK-constraint på tabeller med manuellt redigerade data.';
