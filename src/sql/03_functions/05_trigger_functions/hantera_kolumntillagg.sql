-- FUNCTION: public.hantera_kolumntillagg()

-- DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();

CREATE OR REPLACE FUNCTION public.hantera_kolumntillagg()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Denna funktion hanterar omstrukturering av tabeller när kolumner läggs till.
 * När en ny kolumn läggs till med ALTER TABLE ADD COLUMN hamnar den sist i 
 * tabellen. För att bibehålla vår standardstruktur behöver vi då:
 *
 * 1. Flytta standardkolumner med negativ ordinal_position (t.ex. andrad_av)
 *    så att de hamnar efter den nya kolumnen.
 *
 * 2. Flytta geometrikolumnen sist, om den finns. Detta kräver särskild
 *    hantering via hamta_geometri_definition() för att säkerställa korrekt
 *    hantering av dimensioner och SRID.
 *
 * Loggningsstrategi:
 * - Alla loggmeddelanden prefixas med funktionsnamnet för tydlig källhänvisning
 * - Huvudsteg och tabelloperationer loggas på övergripande nivå
 * - SQL-satser loggas precis innan exekvering för felsökning
 * - Vid fel loggas detaljerad diagnostikinformation med operationskontext
 * - Tydliga avgränsare används för att separera olika operationer i loggen
 ******************************************************************************/
DECLARE
    -- Grundläggande variabler för tabellhantering
    flagg_varde text;          -- För rekursionskontroll
    kommando record;           -- Information om ALTER TABLE-kommandot
    schema_namn text;          -- Schema för tabellen
    tabell_namn text;          -- Namn på tabellen
    
    -- Variabler för kolumnhantering
    flyttkolumner kolumnkonfig[];     -- Kolumner som ska flyttas
    kolumn kolumnkonfig;             -- För iteration över kolumner
    geometriinfo geom_info;          -- Strukturerad geometriinformation
    sql_sats text;                   -- För att bygga SQL-satser
    
    -- Variabler för statushantering
    antal_flyttade integer := 0;      -- Räknare för flyttade kolumner
    antal_fel integer := 0;           -- Räknare för eventuella problem
    op_steg text;                     -- Operationssteg för felsökning
BEGIN
    RAISE NOTICE E'[hantera_kolumntillagg] ======== START ========';
    
    -- Steg 1: Hantera rekursion
    -- Detta förhindrar oändliga loopar när vi modifierar tabellen
    RAISE NOTICE '[hantera_kolumntillagg] (1/4) Kontrollerar rekursionsflagga';
    SELECT COALESCE(current_setting('temp.reorganization_in_progress', true), 'false')
    INTO flagg_varde;
    
    IF flagg_varde = 'true' THEN
        RAISE NOTICE '[hantera_kolumntillagg] Rekursion upptäckt - avbryter för att undvika oändlig loop';
        RETURN;
    END IF;

    PERFORM set_config('temp.reorganization_in_progress', 'true', true);
    RAISE NOTICE '[hantera_kolumntillagg] Rekursionsflagga satt - påbörjar omstrukturering';

    -- Steg 2: Identifiera och hantera tabeller
    RAISE NOTICE '[hantera_kolumntillagg] (2/4) Börjar identifiera modifierade tabeller';
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'ALTER TABLE'
    LOOP
        -- Identifiera vilken tabell som modifieras
        schema_namn := split_part(kommando.object_identity, '.', 1);
        tabell_namn := split_part(kommando.object_identity, '.', 2);

        RAISE NOTICE E'[hantera_kolumntillagg] --------------------------------------------------';
        RAISE NOTICE '[hantera_kolumntillagg] Bearbetar tabell %.%', schema_namn, tabell_namn;

        -- Kontrollera om vi ska hantera denna tabell
        -- Vi hoppar över tabeller i public-schemat och tabeller som redan modifieras
        IF schema_namn = 'public' OR tabell_namn LIKE '%\_h' OR
            EXISTS (
                SELECT 1 
                FROM information_schema.columns 
                WHERE table_schema = schema_namn
                AND table_name = tabell_namn
                AND column_name LIKE '%_temp0001'
        ) THEN
            RAISE NOTICE '[hantera_kolumntillagg] Hoppar över tabell: %', 
                CASE 
                    WHEN schema_namn = 'public' THEN 'public-schema'
                    WHEN tabell_namn LIKE '%\_h' THEN 'historiktabell'
                    ELSE 'temporär operation pågår'
                END;
            CONTINUE;
        END IF;

        -- Steg 3: Hämta standardkolumner som ska flyttas
        RAISE NOTICE '[hantera_kolumntillagg] (3/4) Identifierar kolumner som ska flyttas';
        SELECT array_agg(
            ROW(
                kolumnnamn, 
                ordinal_position, 
                CASE 
                    WHEN default_varde IS NOT NULL AND historik_qa = false THEN
                        datatyp || ' DEFAULT ' || default_varde
                    ELSE
                        datatyp
                END
            )::kolumnkonfig 
            ORDER BY ordinal_position
        )
        INTO flyttkolumner
        FROM standardiserade_kolumner 
        WHERE ordinal_position < 0;

        IF array_length(flyttkolumner, 1) > 0 THEN
            RAISE NOTICE '[hantera_kolumntillagg] Hittade % standardkolumner att flytta', array_length(flyttkolumner, 1);
            -- Lista kolumnerna som ska flyttas
            FOR i IN 1..array_length(flyttkolumner, 1) LOOP
                RAISE NOTICE '[hantera_kolumntillagg]   #%: % (position: %)', 
                    i, flyttkolumner[i].kolumnnamn, flyttkolumner[i].ordinal_position;
            END LOOP;
        ELSE
            RAISE NOTICE '[hantera_kolumntillagg] Inga standardkolumner att flytta';
        END IF;

        -- Steg 4: Flytta varje standardkolumn
        FOR i IN 1..COALESCE(array_length(flyttkolumner, 1), 0) LOOP
            IF i <= array_length(flyttkolumner, 1) THEN
                kolumn := flyttkolumner[i];
                RAISE NOTICE E'[hantera_kolumntillagg] ----------';
                RAISE NOTICE '[hantera_kolumntillagg] Flyttar kolumn %/% - %', 
                    i, array_length(flyttkolumner, 1), kolumn.kolumnnamn;
                
                BEGIN
                    -- Steg 4.1: Skapa temporär kolumn
                    op_steg := 'skapar temporär kolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I ADD COLUMN %I_temp0001 %s',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn, kolumn.datatyp
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [1/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Temporär kolumn skapad';

                    -- Steg 4.2: Kopiera data till temporär kolumn
                    op_steg := 'kopierar data';
                    sql_sats := format(
                        'UPDATE %I.%I SET %I_temp0001 = %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn, kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [2/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Data kopierad';

                    -- Steg 4.3: Ta bort originalkolumnen
                    op_steg := 'tar bort originalkolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I DROP COLUMN %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [3/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Originalkolumn borttagen';

                    -- Steg 4.4: Döp om temporär kolumn till originalnamn
                    op_steg := 'döper om temporär kolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I RENAME COLUMN %I_temp0001 TO %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn, kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [4/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Kolumn omdöpt till %', kolumn.kolumnnamn;

                    antal_flyttade := antal_flyttade + 1;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Kolumnflytt slutförd';
                EXCEPTION
                    WHEN OTHERS THEN
                        antal_fel := antal_fel + 1;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ FEL #% när standardkolumn "%" skulle flyttas', 
                            antal_fel, kolumn.kolumnnamn;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Operation: %', op_steg;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ SQL: %', sql_sats;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Felmeddelande: %', SQLERRM;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Felkod: %', SQLSTATE;
                END;
            END IF;
        END LOOP;

        -- Steg 5: Hantera geometrikolumnen
        RAISE NOTICE E'[hantera_kolumntillagg] ----------';
        RAISE NOTICE '[hantera_kolumntillagg] Kontrollerar om geometrikolumn finns...';
        IF EXISTS (
            SELECT 1 FROM geometry_columns
            WHERE f_table_schema = schema_namn
            AND f_table_name = tabell_namn
            AND f_geometry_column = 'geom'
        ) THEN
            RAISE NOTICE '[hantera_kolumntillagg] Geometrikolumn "geom" hittad';
            RAISE NOTICE '[hantera_kolumntillagg] Hämtar geometridefinition (detaljerad analys sker i hjälpfunktion)';
            
            -- Hämta strukturerad geometriinformation
            geometriinfo := hamta_geometri_definition(schema_namn, tabell_namn);
            
            -- Flytta geometrikolumnen om vi fick en korrekt definition
            IF geometriinfo IS NOT NULL AND geometriinfo.definition IS NOT NULL THEN
                RAISE NOTICE '[hantera_kolumntillagg] Använder geometridefinition: %', geometriinfo.definition;
                
                BEGIN
                    -- Steg 5.1: Skapa temporär geometrikolumn
                    op_steg := 'skapar temporär geometrikolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I ADD COLUMN geom_temp0001 %s',
                        schema_namn, tabell_namn, geometriinfo.definition
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [1/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Temporär geometrikolumn skapad';
                    
                    -- Steg 5.2: Kopiera geometridata
                    op_steg := 'kopierar geometridata';
                    sql_sats := format(
                        'UPDATE %I.%I SET geom_temp0001 = geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [2/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Geometridata kopierad';
                    
                    -- Steg 5.3: Ta bort original geometrikolumn
                    op_steg := 'tar bort originalgeometri';
                    sql_sats := format(
                        'ALTER TABLE %I.%I DROP COLUMN geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [3/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Original geometrikolumn borttagen';
                    
                    -- Steg 5.4: Döp om temporär kolumn
                    op_steg := 'döper om temporär geometrikolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I RENAME COLUMN geom_temp0001 TO geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [4/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Geometrikolumn omdöpt till "geom"';
                    
                    antal_flyttade := antal_flyttade + 1;
                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ Geometriflytt slutförd';
                EXCEPTION
                    WHEN OTHERS THEN
                        antal_fel := antal_fel + 1;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ FEL #% när geometrikolumn skulle flyttas', antal_fel;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Operation: %', op_steg;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ SQL: %', sql_sats;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometriinfo: %', 
                            coalesce(geometriinfo.definition, 'NULL');
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometrityp: %', 
                            coalesce(geometriinfo.typ_komplett, 'NULL');
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ SRID: %', 
                            coalesce(geometriinfo.srid::text, 'NULL');
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Felmeddelande: %', SQLERRM;
                        RAISE WARNING '[hantera_kolumntillagg] ⚠ Felkod: %', SQLSTATE;
                END;
            ELSE
                RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometrikolumn hittad men ingen giltig definition returnerades';
                RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometriinfo: %', geometriinfo;
                antal_fel := antal_fel + 1;
            END IF;
        ELSE
            RAISE NOTICE '[hantera_kolumntillagg] Ingen geometrikolumn att hantera';
        END IF;

        -- Sammanfattning för denna tabell
        RAISE NOTICE E'[hantera_kolumntillagg] ----------';
        RAISE NOTICE '[hantera_kolumntillagg] Sammanfattning för tabell %.%:', schema_namn, tabell_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   » Flyttade kolumner: %', antal_flyttade;
        RAISE NOTICE '[hantera_kolumntillagg]   » Problem uppstod: %', antal_fel;
        RAISE NOTICE '[hantera_kolumntillagg]   » Status: %', 
            CASE WHEN antal_fel = 0 THEN '✓ Slutförd utan fel' 
                 ELSE format('⚠ Slutförd med %s fel', antal_fel) 
            END;
        
        -- Återställ räknare för nästa tabell
        antal_flyttade := 0;
        antal_fel := 0;
    END LOOP;

    -- Återställ flaggan
    RAISE NOTICE '[hantera_kolumntillagg] (4/4) Återställer rekursionsflagga';
    PERFORM set_config('temp.reorganization_in_progress', 'false', true);

    RAISE NOTICE '[hantera_kolumntillagg] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        -- Återställ flaggan och ge detaljerad felinformation
        PERFORM set_config('temp.reorganization_in_progress', 'false', true);
        
        RAISE NOTICE E'[hantera_kolumntillagg] !!!!! KRITISKT FEL !!!!!';
        RAISE NOTICE '[hantera_kolumntillagg] Senaste kontext:';
        RAISE NOTICE '[hantera_kolumntillagg]   Schema: %', schema_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   Tabell: %', tabell_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   Operation: %', op_steg;
        RAISE NOTICE '[hantera_kolumntillagg]   SQL: %', coalesce(sql_sats, 'Ingen SQL');
        RAISE NOTICE '[hantera_kolumntillagg]   Status: % kolumner flyttade, % fel innan kraschen', 
            antal_flyttade, antal_fel;
        RAISE NOTICE '[hantera_kolumntillagg] Tekniska feldetaljer:';
        RAISE NOTICE '[hantera_kolumntillagg]   Felkod: %', SQLSTATE;
        RAISE NOTICE '[hantera_kolumntillagg]   Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_kolumntillagg()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_kolumntillagg()
    IS 'Event trigger-funktion som hanterar omstrukturering av tabeller när kolumner
läggs till. Säkerställer att standardkolumner och geometrikolumn hamnar på
rätt plats i tabellstrukturen. Funktionen använder detaljerad loggning med
tydlig funktionsmarkering för att underlätta felsökning, särskilt i FME-kontext.';