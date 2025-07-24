CREATE OR REPLACE FUNCTION public.uppdatera_sekvensnamn(
    p_schema_namn text,
    p_tabell_namn text,
    p_temp_suffix text DEFAULT '_temp_0001'
)
    RETURNS integer
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Döper om temporära sekvenser efter tabellbyte.
 * IDENTITY-kolumner skapar sekvenser med temp-suffix som måste rättas till.
 * 
 * Returnerar antal omdöpta sekvenser.
 ******************************************************************************/
DECLARE
    seq_rec record;
    nytt_sekvensnamn text;
    antal_sekvenser integer := 0;
BEGIN
    FOR seq_rec IN 
        SELECT n.nspname as sekvens_schema, s.relname as sekvens_namn
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid
        JOIN pg_class t ON d.refobjid = t.oid
        JOIN pg_namespace n ON s.relnamespace = n.oid
        WHERE s.relkind = 'S'
        AND t.relname = p_tabell_namn
        AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = p_schema_namn)
        AND s.relname LIKE '%' || p_temp_suffix || '%'
    LOOP
        nytt_sekvensnamn := replace(seq_rec.sekvens_namn, p_temp_suffix || '_', '_');
        
        EXECUTE format(
            'ALTER SEQUENCE %I.%I RENAME TO %I', 
            seq_rec.sekvens_schema, seq_rec.sekvens_namn, nytt_sekvensnamn
        );
        
        antal_sekvenser := antal_sekvenser + 1;
    END LOOP;
    
    RETURN antal_sekvenser;
END;
$BODY$;

ALTER FUNCTION public.uppdatera_sekvensnamn(text, text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.uppdatera_sekvensnamn(text, text, text)
    IS 'Döper om IDENTITY-sekvenser som skapats med temporärt suffix tillbaka till korrekt namn.';