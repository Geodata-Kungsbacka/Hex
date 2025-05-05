-- FUNCTION: public.hantera_ny_tabell()

-- DROP FUNCTION IF EXISTS public.hantera_ny_tabell();

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
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [hantera_ny_tabell]
 * - Tydliga stegmarkörer för att visa progression
 * - Felmeddelanden innehåller diagnostikinformation för felsökning
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
    RAISE NOTICE E'[hantera_ny_tabell] ======== START ========';
    
    -- Steg 1: Hantera rekursion
    op_steg := 'rekursionskontroll';
    RAISE NOTICE '[hantera_ny_tabell] (1/7) Kontrollerar rekursionsflagga';
    SELECT COALESCE(current_setting('temp.reorganization_in_progress', true), 'false')
    INTO flagg_varde;
    
    IF flagg_varde = 'true' THEN
        RAISE NOTICE '[hantera_ny_tabell] Rekursion upptäckt - avbryter för att undvika oändlig loop';
        RETURN;
    END IF;

    PERFORM set_config('temp.reorganization_in_progress', 'true', true);
    RAISE NOTICE '[hantera_ny_tabell] Rekursionsflagga satt - påbörjar tabellbearbetning';

    -- Steg 2: Identifiera och bearbeta tabeller
    op_steg := 'tabellidentifiering';
    RAISE NOTICE '[hantera_ny_tabell] (2/7) Identifierar nyskapade tabeller';
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE TABLE'
    LOOP
        -- Extrahera schema och tabellnamn
        schema_namn := split_part(kommando.object_identity, '.', 1);
        tabell_namn := split_part(kommando.object_identity, '.', 2);
        temp_tabellnamn := tabell_namn || '_temp_0001';

        RAISE NOTICE E'[hantera_ny_tabell] --------------------------------------------------';
        RAISE NOTICE '[hantera_ny_tabell] Bearbetar tabell %.%', schema_namn, tabell_namn;

        -- Kontrollera om public-schema (hoppa över)
        IF schema_namn = 'public' THEN
            RAISE NOTICE '[hantera_ny_tabell] Hoppar över tabell - schema = public';
            CONTINUE;
        END IF;

        -- Steg 3: Validera tabellen och hämta geometriinfo
        op_steg := 'tabellvalidering';
        RAISE NOTICE '[hantera_ny_tabell] (3/7) Validerar tabellens struktur och namn';
        geometriinfo := validera_tabell(schema_namn, tabell_namn);
        
        IF geometriinfo IS NOT NULL THEN
            RAISE NOTICE '[hantera_ny_tabell] » Geometrityp: %', geometriinfo.typ_basal;
            RAISE NOTICE '[hantera_ny_tabell] » SRID: %', geometriinfo.srid;
        ELSE
            RAISE NOTICE '[hantera_ny_tabell] » Tabell utan geometri';
        END IF;
        
        -- Steg 4: Spara tabellregler och kolumnegenskaper
        op_steg := 'spara metadata';
        RAISE NOTICE '[hantera_ny_tabell] (4/7) Sparar tabellregler och kolumnegenskaper';
        
        -- 4a: Spara tabellregler
        tabell_regler := spara_tabellregler(schema_namn, tabell_namn);
        
        -- Logga antal regler som sparats
        RAISE NOTICE '[hantera_ny_tabell] » Tabellregler:';
        RAISE NOTICE '[hantera_ny_tabell]   - Index:        %', 
            COALESCE(array_length(tabell_regler.index_defs, 1), 0);
        RAISE NOTICE '[hantera_ny_tabell]   - Constraints:  %', 
            COALESCE(array_length(tabell_regler.constraint_defs, 1), 0);
        RAISE NOTICE '[hantera_ny_tabell]   - Foreign Keys: %', 
            COALESCE(array_length(tabell_regler.fk_defs, 1), 0);
            
        -- 4b: Spara kolumnegenskaper
        kolumn_egenskaper := spara_kolumnegenskaper(schema_namn, tabell_namn);
        
        -- Logga antal egenskaper som sparats
        RAISE NOTICE '[hantera_ny_tabell] » Kolumnegenskaper:';
        RAISE NOTICE '[hantera_ny_tabell]   - DEFAULT:      %', 
            COALESCE(array_length(kolumn_egenskaper.default_defs, 1), 0);
        RAISE NOTICE '[hantera_ny_tabell]   - NOT NULL:     %', 
            COALESCE(array_length(kolumn_egenskaper.notnull_defs, 1), 0);
        RAISE NOTICE '[hantera_ny_tabell]   - CHECK:        %', 
            COALESCE(array_length(kolumn_egenskaper.check_defs, 1), 0);
        RAISE NOTICE '[hantera_ny_tabell]   - IDENTITY:     %', 
            COALESCE(array_length(kolumn_egenskaper.identity_defs, 1), 0);

        -- Steg 5: Hämta kolumner och skapa temporär tabell
        op_steg := 'skapa temporär tabell';
        RAISE NOTICE '[hantera_ny_tabell] (5/7) Förbereder standardkolumner och skapar temporär tabell';
        standardkolumner := hamta_kolumnstandard(schema_namn, tabell_namn, geometriinfo);
        
        -- Skapa temporär tabell med standardkolumner
        RAISE NOTICE '[hantera_ny_tabell] » Skapar temporär tabell %', temp_tabellnamn;
        
        -- Skapa SQL-sats för temporär tabell
        DECLARE
            kolumn_sql text;
        BEGIN
            SELECT string_agg(format('%I %s', kolumnnamn, datatyp), ', ')
            INTO kolumn_sql
            FROM unnest(standardkolumner);
            
            RAISE NOTICE '[hantera_ny_tabell] » SQL: CREATE TABLE %I.%I (%s)', 
                schema_namn, temp_tabellnamn, kolumn_sql;
                
            EXECUTE format(
                'CREATE TABLE %I.%I (%s)',
                schema_namn, 
                temp_tabellnamn,
                kolumn_sql
            );
        END;

        -- Steg 6: Byt ut tabeller och hantera sekvenser
        op_steg := 'byt ut tabeller';
        RAISE NOTICE '[hantera_ny_tabell] (6/7) Byter ut tabeller och hanterar sekvenser';
        
        -- 6a: Byt ut tabeller
        RAISE NOTICE '[hantera_ny_tabell] » Byter ut originaltabell med temporär tabell';
        EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', 
            schema_namn, tabell_namn);
            
        EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', 
            schema_namn, temp_tabellnamn, tabell_namn);

        -- 6b: Hantera sekvenser för IDENTITY-kolumner
        RAISE NOTICE '[hantera_ny_tabell] » Letar efter och döper om temporära sekvenser';
        DECLARE
            seq_rec record;
            nytt_sekvensnamn text;
        BEGIN
            -- Hitta alla sekvenser som är associerade med den nydöpta tabellen
            FOR seq_rec IN 
                SELECT 
                    n.nspname as sekvens_schema,
                    s.relname as sekvens_namn
                FROM pg_class s
                JOIN pg_depend d ON d.objid = s.oid
                JOIN pg_class t ON d.refobjid = t.oid
                JOIN pg_namespace n ON s.relnamespace = n.oid
                WHERE s.relkind = 'S' -- S = sequence
                AND t.relname = tabell_namn
                AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = schema_namn)
                AND s.relname LIKE '%temp_0001%' -- Hitta sekvenser med temp_0001 i namnet
            LOOP
                -- Skapa nytt namn genom att ta bort _temp_0001 från sekvensnamnet
                nytt_sekvensnamn := regexp_replace(seq_rec.sekvens_namn, '_temp_0001_', '_');
                
                RAISE NOTICE '[hantera_ny_tabell]   ✓ Döper om sekvens %.% till %.%', 
                    schema_namn, seq_rec.sekvens_namn,
                    schema_namn, nytt_sekvensnamn;
                    
                -- Utför omdöpningen
                EXECUTE format(
                    'ALTER SEQUENCE %I.%I RENAME TO %I', 
                    seq_rec.sekvens_schema, seq_rec.sekvens_namn, nytt_sekvensnamn
                );
            END LOOP;
        END;

        -- Steg 7: Återskapa regler och egenskaper
        op_steg := 'återskapa regler och egenskaper';
        RAISE NOTICE '[hantera_ny_tabell] (7/7) Återskapar tabellregler och kolumnegenskaper';
        
        -- 7a: Återskapa tabellregler (index, constraints, FKs)
        RAISE NOTICE '[hantera_ny_tabell] » Återskapar tabellregler';
        PERFORM aterskapa_tabellregler(
            schema_namn, 
            tabell_namn,
            tabell_regler
        );
        
        -- 7b: Återskapa kolumnegenskaper (DEFAULT, NOT NULL, CHECK, IDENTITY)
        RAISE NOTICE '[hantera_ny_tabell] » Återskapar kolumnegenskaper';
        PERFORM aterskapa_kolumnegenskaper(
            schema_namn,
            tabell_namn,
            kolumn_egenskaper
        );

        RAISE NOTICE '[hantera_ny_tabell] ✓ Tabellomstrukturering slutförd för %.%', 
            schema_namn, tabell_namn;
    END LOOP;

    -- Återställ flaggan
    op_steg := 'återställ rekursionsflagga';
    RAISE NOTICE '[hantera_ny_tabell] Återställer rekursionsflagga';
    PERFORM set_config('temp.reorganization_in_progress', 'false', true);

    RAISE NOTICE '[hantera_ny_tabell] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('temp.reorganization_in_progress', 'false', true);
        RAISE NOTICE E'[hantera_ny_tabell] !!!!! KRITISKT FEL !!!!!';
        RAISE NOTICE '[hantera_ny_tabell] Senaste kontext:';
        RAISE NOTICE '[hantera_ny_tabell]   Schema: %', schema_namn;
        RAISE NOTICE '[hantera_ny_tabell]   Tabell: %', tabell_namn;
        RAISE NOTICE '[hantera_ny_tabell]   Operation: %', op_steg;
        RAISE NOTICE '[hantera_ny_tabell] Tekniska feldetaljer:';
        RAISE NOTICE '[hantera_ny_tabell]   Felkod: %', SQLSTATE;
        RAISE NOTICE '[hantera_ny_tabell]   Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_ny_tabell()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_ny_tabell()
    IS 'Event trigger-funktion som körs vid CREATE TABLE för att validera och 
omstrukturera tabeller enligt standardiserade kolumner. Funktionen validerar
namngivning, sparar tabellregler och kolumnegenskaper separat, skapar en 
standardiserad tabellstruktur, hanterar sekvenser för IDENTITY-kolumner och 
återskapar sedan regler och egenskaper på ett strukturerat sätt.';