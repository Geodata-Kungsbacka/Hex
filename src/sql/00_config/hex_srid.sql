/******************************************************************************
 * Returnerar det förväntade koordinatsystemet (SRID) för Hex-geometritabeller,
 * läst från hex_installningar.
 *
 * Används av hex_hantera_ny_tabell(), hex_hantera_ny_kolumn() och
 * hex_underhall() för att avgöra om en tabell ska registreras i
 * hex_avvikande_srid, och av hex_lagg_till_dummy_geometri() för att tolka
 * referenspunkten.
 *
 * STABLE: värdet kan ändras mellan satser, men inte inom en.
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_srid()
    RETURNS integer
    LANGUAGE sql
    STABLE
AS $BODY$
    SELECT srid FROM public.hex_installningar;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_srid() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_srid()
    IS 'Returnerar förväntat SRID för Hex-geometritabeller (hex_installningar.srid). '
       'Ändra värdet i hex_installningar, inte i funktionen.';
