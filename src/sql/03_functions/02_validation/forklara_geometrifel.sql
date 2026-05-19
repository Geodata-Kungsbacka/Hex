DROP FUNCTION IF EXISTS public.forklara_geometrifel(geometry, float);

CREATE OR REPLACE FUNCTION public.forklara_geometrifel(
    geom geometry
)
    RETURNS text
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $BODY$
/******************************************************************************
 * Diagnostiserar geometriproblem och returnerar en läsbar förklaring.
 *
 * Kontrollerar i prioritetsordning (speglar validera_geometri):
 * 1. ST_IsValid       - Geometrin följer OGC-specifikationen
 * 2. ST_IsEmpty       - Geometrin innehåller faktiska koordinater
 * 3. Duplicerade pts  - Inga exakt identiska konsekutiva punkter
 * 4. ST_HasArc        - Geometrin innehåller inga kurvsegment (stöds ej i systemet)
 *
 * PARAMETRAR:
 *   geom - Geometri att diagnostisera
 *
 * RETURVÄRDE:
 *   NULL - Geometrin är giltig (inga fel hittades)
 *   text - Förklaring av det första problemet som hittades
 *
 * ANVÄNDNING:
 *   Anropas av kontrollera_geometri_trigger() för att ge QGIS-användare
 *   ett meningsfullt felmeddelande istället för ett generiskt constraint-fel.
 ******************************************************************************/
BEGIN
    IF geom IS NULL THEN
        RETURN NULL;
    END IF;

    IF NOT ST_IsValid(geom) THEN
        RETURN format('Geometrin är inte OGC-giltig: %s', ST_IsValidReason(geom));
    END IF;

    IF ST_IsEmpty(geom) THEN
        RETURN 'Geometrin är tom (innehåller inga koordinater)';
    END IF;

    IF ST_NPoints(geom) != ST_NPoints(ST_RemoveRepeatedPoints(geom)) THEN
        RETURN 'Geometrin innehåller exakta duplicerade konsekutiva punkter';
    END IF;

    IF ST_HasArc(geom) THEN
        RETURN format(
            'Geometrin innehåller kurvsegment (%s) vilket inte stöds av systemet – konvertera till linjesegment',
            ST_GeometryType(geom)
        );
    END IF;

    RETURN NULL;
END;
$BODY$;

ALTER FUNCTION public.forklara_geometrifel(geometry)
    OWNER TO postgres;

COMMENT ON FUNCTION public.forklara_geometrifel(geometry)
    IS 'Diagnostiserar geometriproblem och returnerar en läsbar förklaring på svenska.
Returnerar NULL om geometrin är giltig, annars en text som beskriver det första problemet.
Speglar kontrollerna i validera_geometri() men ger specifika felmeddelanden istället för
en boolean. Används av kontrollera_geometri_trigger() för meningsfulla QGIS-felmeddelanden.
Kontrollerar: OGC-validitet, tomhet, exakta duplicerade punkter samt kurvsegment (CIRCULARSTRING m.m.).';
