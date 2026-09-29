/******************************************************************************
 * Returnerar det namnsuffix en tabell eller vy med geometritypen p_typ ska ha,
 * läst från hex_installningar (suffix_punkt, suffix_linje, suffix_yta,
 * suffix_ovrigt).
 *
 * p_typ är en geometrityp som i geometry_columns.type eller
 * hex_geom_info.typ_basal. Dimensionssuffix (Z, M, ZM) och skiftläge spelar
 * ingen roll: 'PointZ', 'POINT' och 'MULTIPOINTM' ger alla suffix_punkt.
 * Allt som inte är punkt, linje eller yta – GEOMETRY, GEOMETRYCOLLECTION,
 * kurvtyper, NULL – ger suffix_ovrigt.
 *
 * Används av hex_validera_tabell(), hex_validera_vynamn() och
 * hex_hantera_ny_kolumn().
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_geometrisuffix(p_typ text)
    RETURNS text
    LANGUAGE sql
    STABLE
AS $BODY$
    SELECT CASE regexp_replace(upper(p_typ), '(ZM|Z|M)$', '')
               WHEN 'POINT'           THEN i.suffix_punkt
               WHEN 'MULTIPOINT'      THEN i.suffix_punkt
               WHEN 'LINESTRING'      THEN i.suffix_linje
               WHEN 'MULTILINESTRING' THEN i.suffix_linje
               WHEN 'POLYGON'         THEN i.suffix_yta
               WHEN 'MULTIPOLYGON'    THEN i.suffix_yta
               ELSE i.suffix_ovrigt
           END
    FROM   public.hex_installningar i;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_geometrisuffix(text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_geometrisuffix(text)
    IS 'Returnerar namnsuffixet för en geometrityp enligt hex_installningar, t.ex. '
       '''_p'' för POINT/MULTIPOINT. Okända typer ger suffix_ovrigt.';
