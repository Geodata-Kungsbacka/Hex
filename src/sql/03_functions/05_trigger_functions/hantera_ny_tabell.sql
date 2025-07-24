CREATE OR REPLACE FUNCTION public.hantera_ny_tabell()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
/******************************************************************************
 * Denna funktion hanterar omstrukturering av tabeller när de skapas. Den:
 * 1. Validerar att tabellen följer namngivningsstandarden
 * 2. Validerar geometrikolumnen
 * 3. Sparar både tabellregler och kolumnegenskaper
 * 4. Skapar en temporär tabell med standardkolumner
 * 5. Ersätter originaltabellen med den temporära
 * 6. Döper om tillhörande sekvenser för IDENTITY-kolumner
 * 7. Återskapar alla tabellregler och kolumnegenskaper
 * 8. Skapar historiktabell och QA-triggers om behövs
 ******************************************************************************/
DECLARE
    -- Grundläggande variabler för tabellhantering
    flagg_varde text;          -- För rekursionskontroll
    kommando record;           -- Information om CREATE TABLE-kommandot
    schema_namn text;          -- Schema för tabellen
    tabell_namn text;          -- Namn på tabellen
    temp_tabellnamn text;      -- Temporärt tabellnamn
    
    -- Variabel för kolumnhantering
    standardkolumner kolumnkonfig[];   -- Kolumner för den nya tabellen
    
    -- Variabler för regler och egenskaper
    tabell_regler tabellregler;        -- Tabellövergripande regler
    kolumn_egenskaper kolumnegenskaper; -- Kolumnspecifika egenskaper
    
    -- För geometrihantering
    geometriinfo geom_info;            -- Strukturerad geometriinformation
    
    -- För felhantering och loggning
    op_steg text;                      -- Operationssteg för felsökning
BEGIN
    RAISE NOTICE E'\n======== hantera_ny_tabell START ========';
    
    -- Kontrollera rekursion
    IF current_setting('temp.tabellstrukturering_pagar', true) = 'true' THEN
        RETURN;
    END IF;
    PERFORM set_config('temp.tabellstrukturering_pagar', 'true', true);

    -- Bearbeta tabeller
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE TABLE'
    LOOP
        -- Extrahera schema och tabellnamn
        schema_namn := split_part(kommando.object_identity, '.', 1);
        tabell_namn := split_part(kommando.object_identity, '.', 2);
        temp_tabellnamn := tabell_namn || '_temp_0001';

        -- Kontrollera undantag
        IF schema_namn = 'public' OR tabell_namn LIKE '%\_h' THEN
            RAISE NOTICE 'Hoppar över tabell %.% - %', 
                schema_namn, tabell_namn,
                CASE 
                    WHEN schema_namn = 'public' THEN 'public-schema'
                    ELSE 'historiktabell'
                END;
            CONTINUE;
        END IF;

        RAISE NOTICE E'\n--- Bearbetar %.% ---', schema_namn, tabell_namn;

        BEGIN
            -- Steg 1: Validera
            op_steg := 'validering';
            RAISE NOTICE 'Steg 1/8: Validerar tabell';
            geometriinfo := validera_tabell(schema_namn, tabell_namn);
            
            -- Steg 2: Spara tabellregler och kolumnegenskaper
            op_steg := 'spara regler';
            RAISE NOTICE 'Steg 2/8: Sparar tabellregler och kolumnegenskaper';
            tabell_regler := spara_tabellregler(schema_namn, tabell_namn);
            kolumn_egenskaper := spara_kolumnegenskaper(schema_namn, tabell_namn);
            
            -- Steg 3: Bestäm kolumner
            op_steg := 'kolumnstruktur';
            RAISE NOTICE 'Steg 3/8: Bestämmer kolumnstruktur';
            standardkolumner := hamta_kolumnstandard(schema_namn, tabell_namn, geometriinfo);
            
            -- Steg 4: Skapa temporär tabell
            op_steg := 'skapa temporär tabell';
            RAISE NOTICE 'Steg 4/8: Skapar temporär tabell';
            DECLARE
                kolumn_sql text;
            BEGIN
                SELECT string_agg(format('%I %s', kolumnnamn, datatyp), ', ')
                INTO kolumn_sql
                FROM unnest(standardkolumner);

                RAISE NOTICE '[hantera_ny_tabell] SQL för temporär tabell: CREATE TABLE %.% (%)', 
                schema_namn, temp_tabellnamn, kolumn_sql;
                
                EXECUTE format(
                    'CREATE TABLE %I.%I (%s)',
                    schema_namn, 
                    temp_tabellnamn,
                    kolumn_sql
                );
            END;
            
            -- Steg 5: Byt ut tabeller
            op_steg := 'byt tabeller';
            RAISE NOTICE 'Steg 5/8: Byter ut tabeller';
            PERFORM byt_ut_tabell(schema_namn, tabell_namn, temp_tabellnamn);
            
            -- Hantera sekvenser
            DECLARE
                antal_sekvenser integer;
            BEGIN
                antal_sekvenser := uppdatera_sekvensnamn(schema_namn, tabell_namn);
                IF antal_sekvenser > 0 THEN
                    RAISE NOTICE '  ✓ % sekvenser uppdaterade', antal_sekvenser;
                END IF;
            END;
            
            -- Steg 6: Återskapa tabellregler
            op_steg := 'återskapa regler';
            RAISE NOTICE 'Steg 6/8: Återskapar tabellregler';
            PERFORM aterskapa_tabellregler(schema_namn, tabell_namn, tabell_regler);
            
            -- Steg 7: Återskapa kolumnegenskaper
            op_steg := 'återskapa egenskaper';
            RAISE NOTICE 'Steg 7/8: Återskapar kolumnegenskaper';
            PERFORM aterskapa_kolumnegenskaper(schema_namn, tabell_namn, kolumn_egenskaper);
            
            -- Steg 8: Skapa historik och QA om behövs
            op_steg := 'skapa historik/qa';
            RAISE NOTICE 'Steg 8/8: Kontrollerar historik/QA-behov';
            IF skapa_historik_qa(schema_namn, tabell_namn) THEN
                RAISE NOTICE '  ✓ Historiktabell och QA-triggers skapade';
            ELSE
                RAISE NOTICE '  - Ingen historik/QA behövs';
            END IF;

            RAISE NOTICE '✓ Tabell %.% omstrukturerad', schema_namn, tabell_namn;

        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '✗ Fel vid bearbetning av %.%', schema_namn, tabell_namn;
                RAISE NOTICE '  Operation: %', op_steg;
                RAISE NOTICE '  Felmeddelande: %', SQLERRM;
                RAISE;
        END;
    END LOOP;

    -- Återställ flaggan
    PERFORM set_config('temp.tabellstrukturering_pagar', 'false', true);
    RAISE NOTICE E'======== hantera_ny_tabell SLUT ========\n';

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('temp.tabellstrukturering_pagar', 'false', true);
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_ny_tabell()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_ny_tabell()
    IS 'Event trigger-funktion som körs vid CREATE TABLE för att validera och 
omstrukturera tabeller enligt standardiserade kolumner. Funktionen validerar
namngivning, sparar tabellregler och kolumnegenskaper separat, skapar en 
standardiserad tabellstruktur, hanterar sekvenser för IDENTITY-kolumner,
återskapar regler och egenskaper, samt skapar historiktabeller och QA-triggers
för scheman som konfigurerats för detta.';