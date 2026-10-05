CREATE OR REPLACE FUNCTION public.hex_uppdatera_metadata_namn(
    p_parent_oid oid
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $BODY$
/******************************************************************************
 * Uppdaterar namnen i hex_metadata efter ALTER TABLE ... RENAME TO.
 *
 * Anropas av hex_hantera_ny_kolumn() vid varje RENAME TO av en registrerad
 * tabell, för tabeller med historik efter att historiktabellen döpts om till
 * <nytt namn>_h. Tabellens schema och namn läses ur pg_class via OID:n.
 * history_table ändras bara om raden redan har en historik och <nytt namn>_h
 * finns och är en historiktabell – en tabell utan historik får ingen av att
 * en orelaterad <nytt namn>_h råkar finnas. trigger_funktion sätts till den
 * QA-triggerfunktion som tabellens trigger anropar, eftersom
 * hex_dop_om_harledda_objekt() döper om den vid namnbytet. Samma
 * säkerhetsmodell som hex_registrera_metadata(): inga värden från anroparen
 * hamnar i tabellen.
 *
 * RETURVÄRDE
 * true om en rad uppdaterades.
 ******************************************************************************/
DECLARE
    s        text;
    t        text;
    h_tabell text;
    h_oid    oid;
    qa_fn    text;
BEGIN
    SELECT n.nspname, c.relname INTO s, t
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_parent_oid AND c.relkind = 'r';

    IF t IS NULL THEN
        RETURN false;
    END IF;

    h_tabell := left(t || '_h', 63);
    h_oid := to_regclass(format('%I.%I', s, h_tabell));
    IF h_oid IS NULL OR (
        SELECT count(*) FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attname IN ('h_typ', 'h_tidpunkt', 'h_av')
          AND NOT a.attisdropped) <> 3
    THEN
        h_tabell := NULL;  -- Behåll det registrerade namnet
    END IF;

    SELECT p.proname INTO qa_fn
    FROM pg_catalog.pg_trigger tg
    JOIN pg_catalog.pg_proc p ON p.oid = tg.tgfoid
    WHERE tg.tgrelid = p_parent_oid
      AND NOT tg.tgisinternal
      AND p.proname ~ '^trg_fn_.+_qa$'
    LIMIT 1;

    UPDATE public.hex_metadata m
    SET parent_schema    = s,
        parent_table     = t,
        history_table    = CASE WHEN m.history_table IS NULL THEN NULL
                                ELSE coalesce(h_tabell, m.history_table) END,
        trigger_funktion = CASE WHEN m.trigger_funktion IS NULL THEN NULL
                                ELSE coalesce(qa_fn, m.trigger_funktion) END
    WHERE m.parent_oid = p_parent_oid;

    RETURN FOUND;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_uppdatera_metadata_namn(oid) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_uppdatera_metadata_namn(oid)
    IS 'Uppdaterar parent_table, history_table och trigger_funktion i hex_metadata efter RENAME TO.
SECURITY DEFINER; namnen läses ur pg_class via OID:n.';
