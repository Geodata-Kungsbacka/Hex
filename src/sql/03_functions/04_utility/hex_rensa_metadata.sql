CREATE OR REPLACE FUNCTION public.hex_rensa_metadata()
    RETURNS integer
    LANGUAGE 'plpgsql'
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $BODY$
/******************************************************************************
 * Tar bort rader i hex_metadata vars tabell inte längre finns.
 *
 * Anropas av hex_hantera_borttagen_tabell() vid DROP TABLE och DROP SCHEMA.
 * Vid sql_drop är tabellerna redan borta ur pg_class, så villkoret "OID:n
 * pekar inte på någon tabell" fångar precis de borttagna – och dessutom
 * rader som blivit kvar tidigare. Det är det enda som tas bort, så funktionen
 * kan inte användas för att radera en giltig registrering.
 *
 * RETURVÄRDE
 * Antal borttagna rader.
 ******************************************************************************/
DECLARE
    antal integer;
BEGIN
    DELETE FROM public.hex_metadata m
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        WHERE c.oid = m.parent_oid AND c.relkind = 'r'
    );
    GET DIAGNOSTICS antal = ROW_COUNT;
    RETURN antal;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_rensa_metadata() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_rensa_metadata()
    IS 'Tar bort rader i hex_metadata vars tabell inte längre finns. SECURITY DEFINER;
kan bara radera döda registreringar.';
