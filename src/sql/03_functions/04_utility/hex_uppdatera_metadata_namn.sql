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
 * Anropas av hex_hantera_ny_kolumn() efter att historiktabellen döpts om till
 * <nytt namn>_h. Tabellens schema och namn läses ur pg_class via OID:n, och
 * historiktabellen ändras bara om <nytt namn>_h finns och är en
 * historiktabell. Samma säkerhetsmodell som hex_registrera_metadata(): inga
 * värden från anroparen hamnar i tabellen.
 *
 * RETURVÄRDE
 * true om en rad uppdaterades.
 ******************************************************************************/
DECLARE
    s        text;
    t        text;
    h_tabell text;
    h_oid    oid;
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

    UPDATE public.hex_metadata m
    SET parent_schema = s,
        parent_table  = t,
        history_table = coalesce(h_tabell, m.history_table)
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
    IS 'Uppdaterar parent_table och history_table i hex_metadata efter RENAME TO.
SECURITY DEFINER; namnen läses ur pg_class via OID:n.';
