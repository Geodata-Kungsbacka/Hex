CREATE OR REPLACE FUNCTION public.byt_ut_tabell(
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