CREATE OR REPLACE FUNCTION public.forklara_geometrifel(
    geom geometry,
    tolerans float DEFAULT 0.001
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
 * 3. Duplicerade pts  - Inga upprepade punkter inom toleransen
 * 4. Area > tolerans^2 - Polygoner har rimlig area (ej degenererade)
 * 5. Längd > tolerans - Linjer har rimlig längd (ej degenererade)
 * 6. ST_IsSimple      - Linjer saknar självskärningar (figur-8, korsande segment)
 * 7. ST_HasArc        - Geometrin innehåller inga kurvsegment (stöds ej i systemet)
 *
 * PARAMETRAR:
 *   geom     - Geometri att diagnostisera
 *   tolerans - Tolerans i kartenheter (meter för SWEREF99 TM), default 0.001 (1mm)
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

    IF ST_NPoints(geom) != ST_NPoints(ST_RemoveRepeatedPoints(geom, tolerans)) THEN
        RETURN format(
            'Geometrin innehåller duplicerade punkter inom %s mm tolerans',
            round((tolerans * 1000)::numeric, 0)
        );
    END IF;

    IF ST_Dimension(geom) = 2 AND ST_Area(geom) <= tolerans * tolerans THEN
        RETURN format(
            'Polygonen är degenererad – arean (%s m²) är för liten (minimum: %s m²)',
            round(ST_Area(geom)::numeric, 6),
            round((tolerans * tolerans)::numeric, 6)
        );
    END IF;

    IF ST_Dimension(geom) = 1 AND ST_Length(geom) <= tolerans THEN
        RETURN format(
            'Linjen är degenererad – längden (%s m) är för kort (minimum: %s m)',
            round(ST_Length(geom)::numeric, 6),
            round(tolerans::numeric, 3)
        );
    END IF;

    IF ST_Dimension(geom) = 1 AND NOT ST_IsSimple(geom) THEN
        RETURN 'Linjen skär sig själv – geometrin är inte enkel (self-intersection)';
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

ALTER FUNCTION public.forklara_geometrifel(geometry, float)
    OWNER TO postgres;

COMMENT ON FUNCTION public.forklara_geometrifel(geometry, float)
    IS 'Diagnostiserar geometriproblem och returnerar en läsbar förklaring på svenska.
Returnerar NULL om geometrin är giltig, annars en text som beskriver det första problemet.
Speglar kontrollerna i validera_geometri() men ger specifika felmeddelanden istället för
en boolean. Används av kontrollera_geometri_trigger() för meningsfulla QGIS-felmeddelanden.
Kontrollerar: OGC-validitet, tomhet, duplicerade punkter, area/längd, självskärning (linjer),
samt kurvsegment (CIRCULARSTRING m.m.).';
