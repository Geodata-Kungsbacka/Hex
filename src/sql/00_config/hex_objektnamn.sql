CREATE OR REPLACE FUNCTION public.hex_objektnamn(p_tabell text, p_typ text)
RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT
AS $BODY$
-- Ett gemensamt namn för skapande, namnbyte, reparation och borttagning.
-- Korta namn bevaras. Långa namn får en hash och ett intakt typ-suffix.
DECLARE
    prefix text;
    suffix text;
    stam text := p_tabell;
BEGIN
    CASE p_typ
        WHEN 'qa' THEN prefix := 'trg_fn_'; suffix := '_qa';
        WHEN 'insert_audit' THEN prefix := 'trg_fn_'; suffix := '_insert_audit';
        WHEN 'qa_trigger' THEN prefix := 'trg_'; suffix := '_qa';
        WHEN 'history_index' THEN prefix := ''; suffix := '_h_idx';
        WHEN 'gid_sequence' THEN prefix := ''; suffix := '_gid_seq';
        ELSE RAISE EXCEPTION 'Okänd Hex-objekttyp: %', p_typ;
    END CASE;
    IF octet_length(prefix || stam || suffix) <= 63 THEN
        RETURN prefix || stam || suffix;
    END IF;
    WHILE octet_length(prefix || stam || '_' || left(md5(p_tabell), 12) || suffix) > 63 LOOP
        stam := left(stam, length(stam) - 1);
    END LOOP;
    RETURN prefix || stam || '_' || left(md5(p_tabell), 12) || suffix;
END;
$BODY$;
DO $$ BEGIN
    EXECUTE format('ALTER FUNCTION public.hex_objektnamn(text, text) OWNER TO %I', public.hex_systemagare());
END $$;
COMMENT ON FUNCTION public.hex_objektnamn(text, text) IS
    'Gemensamma härledda objektnamn, högst 63 byte med bevarat suffix.';
