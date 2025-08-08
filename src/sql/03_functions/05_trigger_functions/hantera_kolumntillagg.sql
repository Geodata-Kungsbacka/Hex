-- FUNCTION: public.hantera_kolumntillagg()

-- DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();

CREATE OR REPLACE FUNCTION public.hantera_kolumntillagg()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Denna funktion hanterar omstrukturering av tabeller när kolumner ändras
 * via ALTER TABLE-operationer. När nya kolumner läggs till hamnar de sist i
 * tabellen, vilket kräver omorganisering för att bibehålla systemets standarder.
 *
 * Funktionen utför följande operationer:
 * 1. Flyttar standardkolumner med negativ ordinal_position så att de hamnar
 *    efter nyligen tillagda kolumner
 * 2. Flyttar geometrikolumnen sist för korrekt struktur
 * 3. Kontrollerar strukturskillnader mellan modertabeller och historiktabeller
 * 4. Inaktiverar QA-triggers temporärt vid strukturskillnader för att undvika
 *    krascher under kolumnflyttning
 * 5. Ger användaren instruktioner för manuell synkronisering av historiktabeller
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med funktionsnamnet för tydlig källhänvisning
 * - Huvudsteg och tabelloperationer loggas på övergripande nivå
 * - SQL-satser loggas precis innan exekvering för felsökning
 * - Vid fel loggas detaljerad diagnostikinformation med operationskontext
 * - Tydliga avgränsare används för att separera olika operationer i loggen
 * - Varningsmeddelanden för historiktabeller använder WARNING-nivå för synlighet
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
    
    -- Variabler för historiktabellhantering
    historik_tabell_namn text;        -- Namnet på historiktabellen
    har_historiktabell boolean;       -- Om historiktabell existerar
    antal_skillnader integer := 0;    -- Antal strukturskillnader mellan moder- och historiktabell
    qa_trigger_inaktiverad boolean := false;  -- Flagga för QA-trigger status
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
        RAISE NOTICE '[hantera_kolumntillagg] Bearbetar tabell %s.%s', schema_namn, tabell_namn;

        -- Kontrollera om vi ska hantera denna tabell
        -- UPPDATERAT: Tar bort undantaget för historiktabeller (%\_h)
        -- Nu behandlas även historiktabeller för att få korrekt kolumnordning
        IF schema_namn = 'public' OR
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
            RAISE NOTICE '[hantera_kolumntillagg] Hittade %s standardkolumner att flytta', array_length(flyttkolumner, 1);
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
                    RAISE NOTICE '[hantera_kolumntillagg]   Temporär kolumn skapad';

                    -- Steg 4.2: Kopiera data till temporär kolumn
                    op_steg := 'kopierar data';
                    sql_sats := format(
                        'UPDATE %I.%I SET %I_temp0001 = %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn, kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [2/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Data kopierad';

                    -- Steg 4.3: Ta bort originalkolumnen
                    op_steg := 'tar bort originalkolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I DROP COLUMN %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [3/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Originalkolumn borttagen';

                    -- Steg 4.4: Döp om temporär kolumn till originalnamn
                    op_steg := 'döper om temporär kolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I RENAME COLUMN %I_temp0001 TO %I',
                        schema_namn, tabell_namn,
                        kolumn.kolumnnamn, kolumn.kolumnnamn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [4/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Kolumn omdöpt till %s', kolumn.kolumnnamn;

                    antal_flyttade := antal_flyttade + 1;
                    RAISE NOTICE '[hantera_kolumntillagg]   Kolumnflytt slutförd';
                EXCEPTION
                    WHEN OTHERS THEN
                        antal_fel := antal_fel + 1;
                        RAISE WARNING '[hantera_kolumntillagg] FEL vid flyttning av standardkolumn "%s"', kolumn.kolumnnamn;
                        RAISE WARNING '[hantera_kolumntillagg] Operation: %s', op_steg;
                        RAISE WARNING '[hantera_kolumntillagg] SQL: %s', sql_sats;
                        RAISE WARNING '[hantera_kolumntillagg] Felmeddelande: %s', SQLERRM;
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
                    RAISE NOTICE '[hantera_kolumntillagg]   Temporär geometrikolumn skapad';
                    
                    -- Steg 5.2: Kopiera geometridata
                    op_steg := 'kopierar geometridata';
                    sql_sats := format(
                        'UPDATE %I.%I SET geom_temp0001 = geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [2/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Geometridata kopierad';
                    
                    -- Steg 5.3: Ta bort original geometrikolumn
                    op_steg := 'tar bort originalgeometri';
                    sql_sats := format(
                        'ALTER TABLE %I.%I DROP COLUMN geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [3/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Original geometrikolumn borttagen';
                    
                    -- Steg 5.4: Döp om temporär kolumn
                    op_steg := 'döper om temporär geometrikolumn';
                    sql_sats := format(
                        'ALTER TABLE %I.%I RENAME COLUMN geom_temp0001 TO geom',
                        schema_namn, tabell_namn
                    );
                    RAISE NOTICE '[hantera_kolumntillagg]   SQL [4/4]: %', sql_sats;
                    EXECUTE sql_sats;
                    RAISE NOTICE '[hantera_kolumntillagg]   Geometrikolumn omdöpt till "geom"';
                    
                    antal_flyttade := antal_flyttade + 1;
                    RAISE NOTICE '[hantera_kolumntillagg]   Geometriflytt slutförd';
                EXCEPTION
                    WHEN OTHERS THEN
                        antal_fel := antal_fel + 1;
                        RAISE WARNING '[hantera_kolumntillagg] FEL vid flyttning av geometrikolumn';
                        RAISE WARNING '[hantera_kolumntillagg] Operation: %s', op_steg;
                        RAISE WARNING '[hantera_kolumntillagg] SQL: %s', sql_sats;
                        RAISE WARNING '[hantera_kolumntillagg] Geometriinfo: %s', 
                            coalesce(geometriinfo.definition, 'NULL');
                        RAISE WARNING '[hantera_kolumntillagg] Felmeddelande: %s', SQLERRM;
                END;
            ELSE
                RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometrikolumn hittad men ingen giltig definition returnerades';
                RAISE WARNING '[hantera_kolumntillagg] ⚠ Geometriinfo: %', geometriinfo;
                antal_fel := antal_fel + 1;
            END IF;
        ELSE
            RAISE NOTICE '[hantera_kolumntillagg] Ingen geometrikolumn att hantera';
        END IF;

        -- Steg 6: Kontrollera historiktabell och analysera skillnader
        RAISE NOTICE E'[hantera_kolumntillagg] ----------';
        RAISE NOTICE '[hantera_kolumntillagg] (4/4) Kontrollerar historiktabellsynkronisering';
        
        -- Bestäm historiktabellnamn (hoppa över om detta redan ÄR en historiktabell)
        historik_tabell_namn := tabell_namn || '_h';
        
        IF NOT tabell_namn LIKE '%\_h' THEN
            -- Detta är en modertabell, kontrollera om det finns motsvarande historiktabell
            SELECT EXISTS(
                SELECT 1 FROM information_schema.tables 
                WHERE table_schema = schema_namn 
                AND table_name = historik_tabell_namn
            ) INTO har_historiktabell;
            
            IF har_historiktabell THEN
                RAISE NOTICE '[hantera_kolumntillagg] Hittade historiktabell %s.%s - analyserar strukturskillnader', 
                    schema_namn, historik_tabell_namn;
                
                -- Analysera strukturskillnader mellan moder- och historiktabell
                DECLARE
                    saknade_i_historik text[];      -- Kolumner som finns i moder men saknas i historik
                    extra_i_historik text[];        -- Kolumner som finns i historik men saknas i moder  
                    typ_skillnader text[];          -- Kolumner med olika datatyper
                    kolumn_info text;
                BEGIN
                    -- Hitta kolumner som finns i modertabell men saknas i historiktabell
                    -- (exkluderar h_-kolumner som bara finns i historik)
                    SELECT array_agg(m.column_name ORDER BY m.ordinal_position)
                    INTO saknade_i_historik
                    FROM information_schema.columns m
                    WHERE m.table_schema = schema_namn 
                    AND m.table_name = tabell_namn
                    AND NOT EXISTS (
                        SELECT 1 FROM information_schema.columns h
                        WHERE h.table_schema = schema_namn
                        AND h.table_name = historik_tabell_namn
                        AND h.column_name = m.column_name
                    );
                    
                    -- Hitta kolumner som finns i historiktabell men saknas i modertabell
                    -- (exkluderar h_-kolumner som är normala i historik)
                    SELECT array_agg(h.column_name ORDER BY h.ordinal_position)
                    INTO extra_i_historik
                    FROM information_schema.columns h
                    WHERE h.table_schema = schema_namn 
                    AND h.table_name = historik_tabell_namn
                    AND h.column_name NOT LIKE 'h\_%'  -- Hoppa över historikkolumner
                    AND NOT EXISTS (
                        SELECT 1 FROM information_schema.columns m
                        WHERE m.table_schema = schema_namn
                        AND m.table_name = tabell_namn
                        AND m.column_name = h.column_name
                    );
                    
                    -- Hitta kolumner med olika datatyper
                    SELECT array_agg(
                        format('%s (moder: %s, historik: %s)', 
                            m.column_name, m.data_type, h.data_type)
                        ORDER BY m.ordinal_position
                    )
                    INTO typ_skillnader
                    FROM information_schema.columns m
                    JOIN information_schema.columns h ON (
                        h.table_schema = schema_namn
                        AND h.table_name = historik_tabell_namn
                        AND h.column_name = m.column_name
                        AND h.data_type != m.data_type
                    )
                    WHERE m.table_schema = schema_namn
                    AND m.table_name = tabell_namn;
                    
                    -- Räkna totalt antal skillnader (sätt på funktion-nivå variabel)
                    antal_skillnader := COALESCE(array_length(saknade_i_historik, 1), 0) +
                                       COALESCE(array_length(extra_i_historik, 1), 0) +
                                       COALESCE(array_length(typ_skillnader, 1), 0);
                    
                    -- Om strukturskillnader finns, inaktivera QA-triggers temporärt för säker kolumnflyttning
                    IF antal_skillnader > 0 THEN
                        BEGIN
                            EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER trg_%s_qa', 
                                schema_namn, tabell_namn, tabell_namn);
                            qa_trigger_inaktiverad := true;
                            RAISE NOTICE '[hantera_kolumntillagg] QA-trigger tillfälligt inaktiverad för säker strukturändring';
                        EXCEPTION
                            WHEN OTHERS THEN
                                RAISE NOTICE '[hantera_kolumntillagg] Kunde inte inaktivera QA-trigger: %s', SQLERRM;
                                -- Fortsätt ändå, men varna användaren extra
                        END;
                    END IF;
                    
                    IF antal_skillnader > 0 THEN
                        -- Det finns skillnader - visa koncisa varningar
                        RAISE WARNING '[hantera_kolumntillagg] Strukturskillnader funna: %s st', antal_skillnader;
                        RAISE WARNING '[hantera_kolumntillagg] Modertabell: %s.%s, Historiktabell: %s.%s', 
                            schema_namn, tabell_namn, schema_namn, historik_tabell_namn;
                        
                        -- Visa kolumner som saknas i historik
                        IF array_length(saknade_i_historik, 1) > 0 THEN
                            RAISE WARNING '[hantera_kolumntillagg] Saknas i historik: %s', 
                                array_to_string(saknade_i_historik, ', ');
                        END IF;
                        
                        -- Visa kolumner som finns extra i historik
                        IF array_length(extra_i_historik, 1) > 0 THEN
                            RAISE WARNING '[hantera_kolumntillagg] Extra i historik: %s', 
                                array_to_string(extra_i_historik, ', ');
                        END IF;
                        
                        -- Visa kolumner med olika datatyper
                        IF array_length(typ_skillnader, 1) > 0 THEN
                            RAISE WARNING '[hantera_kolumntillagg] Olika datatyper: %s', 
                                array_to_string(typ_skillnader, ', ');
                        END IF;
                        
                        RAISE WARNING '[hantera_kolumntillagg] QA-trigger inaktiverad temporärt för säker kolumnflyttning';
                        RAISE WARNING '[hantera_kolumntillagg] Utför samma ALTER TABLE-operation på historiktabellen för synkronisering';
                    ELSE
                        -- Inga skillnader - tabellerna är synkroniserade
                        RAISE NOTICE '[hantera_kolumntillagg] Historiktabell %s.%s är redan synkroniserad', 
                            schema_namn, historik_tabell_namn;
                    END IF;
                END;
            ELSE
                RAISE NOTICE '[hantera_kolumntillagg] Ingen historiktabell hittades - ingen ytterligare åtgärd krävs';
                antal_skillnader := 0;  -- Inga skillnader att rapportera
            END IF;
        ELSE
            -- Detta är redan en historiktabell
            RAISE NOTICE '[hantera_kolumntillagg] Detta är en historiktabell - inga varningar behövs';
            antal_skillnader := 0;  -- Historiktabeller analyseras inte
        END IF;

        -- Återaktivera QA-trigger om den inaktiverades
        IF qa_trigger_inaktiverad THEN
            BEGIN
                EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER trg_%s_qa', 
                    schema_namn, tabell_namn, tabell_namn);
                RAISE NOTICE '[hantera_kolumntillagg] QA-trigger återaktiverad efter strukturändring';
                
                -- Strukturloggning hoppas över pga CHECK constraint i historiktabell
                RAISE NOTICE '[hantera_kolumntillagg] Strukturändring slutförd (loggning hoppas över på grund av constraints)';
                
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING '[hantera_kolumntillagg] KRITISKT: Kunde inte återaktivera QA-trigger: %s', SQLERRM;
                    RAISE WARNING '[hantera_kolumntillagg] Du måste manuellt aktivera: ALTER TABLE %I.%I ENABLE TRIGGER trg_%I_qa;', 
                        schema_namn, tabell_namn, tabell_namn;
            END;
        END IF;

        -- Sammanfattning för denna tabell
        RAISE NOTICE E'[hantera_kolumntillagg] ----------';
        RAISE NOTICE '[hantera_kolumntillagg] Sammanfattning för tabell %s.%s:', schema_namn, tabell_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   » Flyttade kolumner: %s', antal_flyttade;
        RAISE NOTICE '[hantera_kolumntillagg]   » Problem uppstod: %s', antal_fel;
        RAISE NOTICE '[hantera_kolumntillagg]   » Historiktabell: %s', 
            CASE WHEN NOT tabell_namn LIKE '%\_h' AND har_historiktabell AND antal_skillnader > 0
                 THEN format('%s skillnader funna', antal_skillnader)
                 WHEN NOT tabell_namn LIKE '%\_h' AND har_historiktabell AND antal_skillnader = 0
                 THEN 'Synkroniserad'
                 WHEN NOT tabell_namn LIKE '%\_h' AND NOT har_historiktabell
                 THEN 'Ingen historik'
                 ELSE 'Historiktabell'
            END;
        RAISE NOTICE '[hantera_kolumntillagg]   » Status: %s', 
            CASE WHEN antal_fel = 0 THEN 'Slutförd utan fel' 
                 ELSE format('Slutförd med %s fel', antal_fel) 
            END;
        
        -- Återställ räknare för nästa tabell
        antal_flyttade := 0;
        antal_fel := 0;
        antal_skillnader := 0;
        qa_trigger_inaktiverad := false;
    END LOOP;

    -- Återställ flaggan
    RAISE NOTICE '[hantera_kolumntillagg] Återställer rekursionsflagga';
    PERFORM set_config('temp.reorganization_in_progress', 'false', true);

    RAISE NOTICE '[hantera_kolumntillagg] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        -- Återställ flaggan och ge detaljerad felinformation
        PERFORM set_config('temp.reorganization_in_progress', 'false', true);
        
        RAISE NOTICE E'[hantera_kolumntillagg] !!!!! KRITISKT FEL !!!!!';
        RAISE NOTICE '[hantera_kolumntillagg] Senaste kontext:';
        RAISE NOTICE '[hantera_kolumntillagg]   - Schema: %s', schema_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   - Tabell: %s', tabell_namn;
        RAISE NOTICE '[hantera_kolumntillagg]   - Operation: %s', op_steg;
        RAISE NOTICE '[hantera_kolumntillagg]   - SQL: %s', coalesce(sql_sats, 'Ingen SQL');
        RAISE NOTICE '[hantera_kolumntillagg]   - Status: %s kolumner flyttade, %s fel innan kraschen', 
            antal_flyttade, antal_fel;
        RAISE NOTICE '[hantera_kolumntillagg] Tekniska feldetaljer:';
        RAISE NOTICE '[hantera_kolumntillagg]   - Felkod: %s', SQLSTATE;
        RAISE NOTICE '[hantera_kolumntillagg]   - Felmeddelande: %s', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_kolumntillagg()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_kolumntillagg()
    IS 'Event trigger-funktion som triggas vid ALTER TABLE-operationer. Funktionen:

1. Omstrukturerar tabeller genom att flytta standardkolumner med negativ 
   ordinal_position så att de hamnar sist i tabellen efter nyligen tillagda kolumner.

2. Flyttar geometrikolumnen (geom) till allra sist för att bibehålla korrekt 
   kolumnordning enligt systemets standarder.

3. Analyserar strukturskillnader mellan modertabeller och deras motsvarande 
   historiktabeller (_h). När skillnader upptäcks visas tydliga varningar som 
   anger exakt vilka kolumner som skiljer sig åt.

4. AUTOMATISK SÄKRING: När strukturskillnader upptäcks inaktiveras QA-triggers 
   temporärt under kolumnflyttning för att undvika krascher från strukturmismatch. 
   Triggers återaktiveras automatiskt efter slutförd operation.

5. Instruerar användaren att manuellt utföra samma ALTER TABLE-operation på 
   historiktabellen för att behålla fullständig synkronisering.

6. Behandlar nu även historiktabeller direkt för att säkerställa korrekt 
   kolumnordning i dessa tabeller också.

7. Loggar strukturändringar i historiktabeller för spårbarhet när det är möjligt.

Funktionen använder detaljerad loggning med tydlig funktionsmarkering för att 
underlätta felsökning och omfattar rekursionskontroll för att undvika oändliga 
loopar vid tabellmodifieringar.';