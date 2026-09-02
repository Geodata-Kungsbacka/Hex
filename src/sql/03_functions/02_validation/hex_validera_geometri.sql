DROP FUNCTION IF EXISTS public.hex_validera_geometri(geometry, float);

CREATE OR REPLACE FUNCTION public.hex_validera_geometri(
    geom geometry
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    -- Låst search_path. Utan den slås ST_*-anropen nedan upp via
    -- ANROPARENS search_path, och funktionen når CHECK-villkoret
    -- validera_geom_<tabell> på varje INSERT. pg_dump/pg_restore kör med
    -- search_path = '' – då finns inte PostGIS-funktionerna och COPY-steget
    -- havererar. Se docs/12.
    --
    -- FÖRUTSÄTTER POSTGIS I public. Låsningen byter ut anroparens search_path
    -- mot den här, så ligger extensionen i ett eget schema hittas ST_* inte
    -- alls och valideringen slutar fungera för alla anropare, inte bara
    -- pg_restore. install_hex.py varnar vid installation om så är fallet.
    -- Flyttas PostGIS måste schemat läggas till här, i
    -- hex_forklara_geometrifel.sql och i hex_kontrollera_geometri.sql.
    SET search_path = public, pg_temp
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
 *       CHECK (hex_validera_geometri(geom));
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

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_validera_geometri(geometry) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_validera_geometri(geometry)
    IS 'Validerar geometrikvalitet för _kba_-scheman. Kontrollerar OGC-validitet,
icke-tomhet, inga exakta konsekutiva duplicerade punkter (ST_RemoveRepeatedPoints),
samt att geometrin inte innehåller kurvsegment (ST_HasArc).
Används som CHECK-constraint på tabeller med manuellt redigerade data.';
