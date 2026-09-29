CREATE OR REPLACE FUNCTION public.hex_komplettera_metadata(
    p_schema_namn text,
    p_tabell_namn text
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $BODY$
/******************************************************************************
 * Registrerar en Hex-tabell som saknar rad i hex_metadata.
 *
 * Anropas av hex_underhall() för varje tabell i ett Hex-schema. En rad kan
 * saknas för tabeller som skapades medan event-triggrarna var avstängda eller
 * Hex var avinstallerat, och för tabeller utan historik i databaser från
 * före den här versionen (då registrerades bara tabeller med historik).
 *
 * Skillnaden mot hex_registrera_metadata() är created_by: den som kör
 * underhållet har inte skapat tabellen, så kolumnen sätts till NULL
 * ("okänd"). En befintlig rad rörs aldrig. Samma säkerhetsmodell som
 * hex_registrera_metadata(): allt som skrivs härleds ur systemkatalogen.
 *
 * RETURVÄRDE
 * true om en rad lades till, false om raden redan fanns eller tabellen inte
 * är en Hex-tabell.
 ******************************************************************************/
DECLARE
    moder_oid oid;
BEGIN
    moder_oid := to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn));

    IF moder_oid IS NULL
       OR EXISTS (SELECT 1 FROM public.hex_metadata m WHERE m.parent_oid = moder_oid)
       OR NOT public.hex_registrera_metadata(p_schema_namn, p_tabell_namn)
    THEN
        RETURN false;
    END IF;

    UPDATE public.hex_metadata m
    SET created_by = NULL
    WHERE m.parent_oid = moder_oid;

    RETURN true;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_komplettera_metadata(text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_komplettera_metadata(text, text)
    IS 'Registrerar en Hex-tabell som saknar rad i hex_metadata, med created_by = NULL.
Anropas av hex_underhall(). SECURITY DEFINER; allt härleds ur systemkatalogen.';
