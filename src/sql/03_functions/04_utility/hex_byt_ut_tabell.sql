CREATE OR REPLACE FUNCTION public.hex_byt_ut_tabell(
    p_schema_namn text,
    p_tabell_namn text,
    p_temp_tabellnamn text
)
    RETURNS void
    LANGUAGE 'plpgsql'
AS $BODY$
BEGIN
    EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', 
        p_schema_namn, p_tabell_namn);
    
    EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', 
        p_schema_namn, p_temp_tabellnamn, p_tabell_namn);
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_byt_ut_tabell(text, text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;
