-- FUNCTION: public.hantera_ny_vy()

-- DROP FUNCTION IF EXISTS public.hantera_ny_vy();

CREATE OR REPLACE FUNCTION public.hantera_ny_vy()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Denna funktion validerar namngivningen av nyskapade vyer. Den säkerställer
 * att vyerna följer vår namngivningsstandard:
 *
 * 1. Prefix: schema.schema_v_
 *    Exempel: teknik.teknik_v_ledningar_p
 *
 * 2. Suffix baserat på geometriinnehåll:
 *    - Ingen geometri: Inget suffix
 *    - En geometri: _p, _l eller _y baserat på typ
 *    - Flera geometrier: _g
 *    - Vid geometritransformationer krävs typkonvertering
 *      eller _g-suffix
 ******************************************************************************/
DECLARE
    -- Grundläggande variabler för vyhantering
    kommando record;           -- Information om CREATE VIEW-kommandot
    schema_namn text;          -- Schema där vyn skapas
    vy_namn text;             -- Namnet på vyn som skapas
BEGIN
    RAISE NOTICE E'\n=== START hantera_ny_vy() ===';
    
    -- Loopa genom alla CREATE VIEW-kommandon
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE VIEW'
    LOOP
        -- Extrahera schema- och vynamn
        schema_namn := split_part(kommando.object_identity, '.', 1);
        vy_namn := split_part(kommando.object_identity, '.', 2);
        
        RAISE NOTICE 'Validerar vy %.%', schema_namn, vy_namn;
        
        -- Kontrollera om det är public-schema
        IF schema_namn = 'public' THEN
            RAISE NOTICE 'Hoppar över vy - schema = public';
            CONTINUE;
        END IF;
        
        -- Validera vynamnet
        -- Detta anrop kontrollerar prefix och suffix baserat på geometriinnehåll
        PERFORM validera_vynamn(schema_namn, vy_namn);
        
        RAISE NOTICE 'Vy %.% validerad och godkänd', schema_namn, vy_namn;
    END LOOP;
    
    RAISE NOTICE '=== SLUT hantera_ny_vy() ===\n';

EXCEPTION
    WHEN OTHERS THEN
        -- Skicka vidare felet utan extra meddelanden
        -- Detta ger tydligare felmeddelanden från validera_vynamn
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_ny_vy()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_ny_vy()
    IS 'Triggerfunktion som körs vid CREATE VIEW för att validera vynamn enligt
standardiserad namngivning. Vyerna måste följa mönstret schema_v_namn
med suffix baserat på geometriinnehåll (_p, _l, _y eller _g).';
