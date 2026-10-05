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
 * Registrerar en Hex-tabell i hex_metadata, med historiktabell och
 * QA-triggerfunktion om tabellen har historik.
 *
 * SÄKERHET
 * hex_metadata är inte skrivbar för PUBLIC. Skrivningar går via den här
 * funktionen och hex_uppdatera_metadata_namn()/hex_rensa_metadata(), som körs
 * som ägaren (SECURITY DEFINER). EXECUTE är öppet för alla, så funktionen tar
 * inte emot några värden som hamnar i tabellen: OID, historiktabell och
 * triggerfunktion härleds ur systemkatalogen, och created_by är alltid
 * session_user. Den som anropar kan alltså bara registrera det som är sant.
 *
 * Bara vanliga tabeller i scheman som matchar hex_schema_regex() registreras,
 * och aldrig en tabell med _h-suffix. Historikkolumnerna fylls i bara om
 * <tabell>_h finns och har h_typ, h_tidpunkt och h_av – annars lämnas de
 * NULL. Anropas av hex_hantera_ny_tabell() för varje ny tabell och av
 * hex_skapa_historik_qa() när historiken skapas, som då fyller i
 * historikkolumnerna på den befintliga raden.
 *
 * Vid omregistrering uppdateras namnen men created_by och created_at står
 * kvar, och en redan registrerad historik skrivs inte över med NULL.
 *
 * RETURVÄRDE
 * true om tabellen registrerades, false om den inte är en Hex-tabell.
 ******************************************************************************/
DECLARE
    moder_oid   oid;
    h_tabell    text := left(p_tabell_namn || '_h', 63);
    h_oid       oid;
    trigger_fn  text;
BEGIN
    moder_oid := to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn));

    IF moder_oid IS NULL
       OR p_tabell_namn ~ '_h$'
       OR p_schema_namn !~ public.hex_schema_regex()
       OR (SELECT c.relkind FROM pg_catalog.pg_class c WHERE c.oid = moder_oid) <> 'r'
    THEN
        RETURN false;
    END IF;

    h_oid := to_regclass(format('%I.%I', p_schema_namn, h_tabell));
    IF h_oid IS NULL OR (
        SELECT count(*) FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attname IN ('h_typ', 'h_tidpunkt', 'h_av')
          AND NOT a.attisdropped) <> 3
    THEN
        h_tabell := NULL;  -- Ingen historik (ännu)
    ELSE
        -- Vid skapande finns funktionen före triggern. Efter namnbyte och
        -- underhåll används samma gemensamma objektnamn.
        SELECT p.proname INTO trigger_fn
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = p_schema_namn
          AND p.proname = public.hex_objektnamn(p_tabell_namn, 'qa');
    END IF;

    INSERT INTO public.hex_metadata AS m
        (parent_oid, parent_schema, parent_table,
         history_schema, history_table, trigger_funktion, created_by)
    VALUES
        (moder_oid, p_schema_namn, p_tabell_namn,
         CASE WHEN h_tabell IS NOT NULL THEN p_schema_namn END,
         h_tabell, trigger_fn, session_user)
    ON CONFLICT (parent_oid) DO UPDATE SET
        parent_schema    = EXCLUDED.parent_schema,
        parent_table     = EXCLUDED.parent_table,
        history_schema   = coalesce(EXCLUDED.history_schema, m.history_schema),
        history_table    = coalesce(EXCLUDED.history_table, m.history_table),
        trigger_funktion = coalesce(EXCLUDED.trigger_funktion, m.trigger_funktion);

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
    IS 'Registrerar en Hex-tabell i hex_metadata, med historiktabell om den finns. SECURITY DEFINER; alla
värden härleds ur systemkatalogen, så anroparen kan bara registrera det som är sant.';
