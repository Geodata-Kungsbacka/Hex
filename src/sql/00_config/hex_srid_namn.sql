/******************************************************************************
 * Returnerar ett läsbart namn på ett koordinatsystem, t.ex. "SWEREF99 12 00"
 * för 3007, hämtat ur spatial_ref_sys.srtext. Används i meddelanden så att
 * namnet följer med när hex_installningar.srid ändras. Ger 'okänt' för SRID
 * som saknas i spatial_ref_sys (t.ex. 0).
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_srid_namn(p_srid integer)
    RETURNS text
    LANGUAGE sql
    STABLE
AS $BODY$
    SELECT coalesce(
        (SELECT nullif(split_part(srtext, '"', 2), '')
         FROM   public.spatial_ref_sys
         WHERE  srid = p_srid),
        'okänt'
    );
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_srid_namn(integer) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_srid_namn(integer)
    IS 'Returnerar koordinatsystemets namn ur spatial_ref_sys.srtext, t.ex. "SWEREF99 12 00". '
       'Ger ''okänt'' om SRID saknas.';
