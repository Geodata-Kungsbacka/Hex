CREATE OR REPLACE FUNCTION public.hex_registrera_metadata(
    p_schema_namn text,
    p_tabell_namn text
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $BODY$
/******************************************************************************
 * Registrerar en tabell och dess historiktabell i hex_metadata.
 *
 * SÄKERHET
 * hex_metadata är inte skrivbar för PUBLIC. Skrivningar går via den här
 * funktionen och hex_uppdatera_metadata_namn()/hex_rensa_metadata(), som körs
 * som ägaren (SECURITY DEFINER). EXECUTE är öppet för alla, så funktionen tar
 * inte emot några värden som hamnar i tabellen: OID, historiktabell och
 * triggerfunktion härleds ur systemkatalogen, och created_by är alltid
 * session_user. Den som anropar kan alltså bara registrera det som är sant.
 *
 * Historiktabellen måste finnas och ha h_typ, h_tidpunkt och h_av – annars
 * registreras inget. Vid omregistrering uppdateras namnen men created_by och
 * created_at står kvar.
 *
 * RETURVÄRDE
 * true om tabellen registrerades, false om tabell eller historiktabell saknas.
 ******************************************************************************/
DECLARE
    moder_oid   oid;
    h_tabell    text := left(p_tabell_namn || '_h', 63);
    h_oid       oid;
    trigger_fn  text;
BEGIN
    moder_oid := to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn));
    h_oid     := to_regclass(format('%I.%I', p_schema_namn, h_tabell));

    IF moder_oid IS NULL OR h_oid IS NULL OR (
        SELECT count(*) FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attname IN ('h_typ', 'h_tidpunkt', 'h_av')
          AND NOT a.attisdropped) <> 3
    THEN
        RETURN false;
    END IF;

    -- Triggerfunktionen skapas före registreringen men triggern efter, så
    -- namnet hämtas ur pg_proc och inte ur pg_trigger.
    SELECT p.proname INTO trigger_fn
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = p_schema_namn
      AND p.proname = 'trg_fn_' || p_tabell_namn || '_qa';

    INSERT INTO public.hex_metadata
        (parent_oid, parent_schema, parent_table,
         history_schema, history_table, trigger_funktion, created_by)
    VALUES
        (moder_oid, p_schema_namn, p_tabell_namn,
         p_schema_namn, h_tabell, trigger_fn, session_user)
    ON CONFLICT (parent_oid) DO UPDATE SET
        parent_schema    = EXCLUDED.parent_schema,
        parent_table     = EXCLUDED.parent_table,
        history_schema   = EXCLUDED.history_schema,
        history_table    = EXCLUDED.history_table,
        trigger_funktion = EXCLUDED.trigger_funktion;

    RETURN true;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_registrera_metadata(text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_registrera_metadata(text, text)
    IS 'Registrerar tabell och historiktabell i hex_metadata. SECURITY DEFINER; alla
värden härleds ur systemkatalogen, så anroparen kan bara registrera det som är sant.';
