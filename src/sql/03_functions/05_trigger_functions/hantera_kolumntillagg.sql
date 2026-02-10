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
 * 4. UPPDATERAD: Lägger automatiskt till saknade kolumner i historiktabeller
 * 5. Ger användaren instruktioner för manuell synkronisering vid typskillnader
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

    -- Kontrollera om hantera_ny_tabell pågår - avbryt för att inte störa
    -- steg 8 (GiST-index) och steg 9 (geometrivalidering)
    IF current_setting('temp.tabellstrukturering_pagar', true) = 'true' THEN
        RAISE NOTICE '[hantera_kolumntillagg] hantera_ny_tabell pågår - avbryter';
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
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');
        tabell_namn := replace(split_part(kommando.object_identity, '.', 2), '"', '');

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

        -- Steg 6: Kontrollera historiktabell och synkronisera automatiskt
        RAISE NOTICE E'[hantera_kolumntillagg] ----------';
        RAISE NOTICE '[hantera_kolumntillagg] (4/4) Kontrollerar historiktabellsynkronisering';
        
        -- Bestäm historiktabellnamn (hoppa över om detta redan ÄR en historiktabell)
        historik_tabell_namn := tabell_namn || '_h';
        
        IF NOT tabell_namn ~ '_h$' THEN
            -- Detta är en modertabell, kontrollera om det finns motsvarande historiktabell
            SELECT EXISTS(
                SELECT 1 FROM information_schema.tables 
                WHERE table_schema = schema_namn 
                AND table_name = historik_tabell_namn
            ) INTO har_historiktabell;
            
            IF har_historiktabell THEN
                RAISE NOTICE '[hantera_kolumntillagg] Hittade historiktabell %s.%s - analyserar och synkroniserar', 
                    schema_namn, historik_tabell_namn;
                
                -- Analysera strukturskillnader mellan moder- och historiktabell
                DECLARE
                    saknade_i_historik text[];      -- Kolumner som finns i moder men saknas i historik
                    extra_i_historik text[];        -- Kolumner som finns i historik men saknas i moder  
                    typ_skillnader text[];          -- Kolumner med olika datatyper
                    kolumn_info record;
                    antal_tillagda integer := 0;
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
                    
                    -- NYTT: Lägg automatiskt till saknade kolumner i historiktabellen
                    IF array_length(saknade_i_historik, 1) > 0 THEN
                        RAISE NOTICE '[hantera_kolumntillagg] Lägger till %s saknade kolumner i historiktabell:', 
                            array_length(saknade_i_historik, 1);
                        
                        FOR kolumn_info IN 
                            SELECT 
                                m.column_name,
                                CASE 
                                    WHEN m.data_type = 'USER-DEFINED' THEN m.udt_name
                                    WHEN m.data_type = 'character varying' THEN 
                                        'character varying' || 
                                        CASE WHEN m.character_maximum_length IS NOT NULL 
                                             THEN '(' || m.character_maximum_length || ')'
                                             ELSE ''
                                        END
                                    WHEN m.data_type = 'numeric' AND m.numeric_precision IS NOT NULL THEN 
                                        'numeric(' || m.numeric_precision || ',' || COALESCE(m.numeric_scale, 0) || ')'
                                    ELSE m.data_type
                                END as full_data_type
                            FROM information_schema.columns m
                            WHERE m.table_schema = schema_namn 
                            AND m.table_name = tabell_namn
                            AND m.column_name = ANY(saknade_i_historik)
                            ORDER BY m.ordinal_position
                        LOOP
                            BEGIN
                                sql_sats := format(
                                    'ALTER TABLE %I.%I ADD COLUMN %I %s',
                                    schema_namn, historik_tabell_namn,
                                    kolumn_info.column_name, kolumn_info.full_data_type
                                );
                                RAISE NOTICE '[hantera_kolumntillagg]   SQL: %', sql_sats;
                                EXECUTE sql_sats;
                                antal_tillagda := antal_tillagda + 1;
                                RAISE NOTICE '[hantera_kolumntillagg]   ✓ Lade till kolumn: %', kolumn_info.column_name;
                            EXCEPTION
                                WHEN OTHERS THEN
                                    RAISE WARNING '[hantera_kolumntillagg]   ✗ Kunde inte lägga till kolumn %: %', 
                                        kolumn_info.column_name, SQLERRM;
                            END;
                        END LOOP;
                        
                        RAISE NOTICE '[hantera_kolumntillagg] Historiktabell synkroniserad: % kolumner tillagda', antal_tillagda;
                        
                        -- Regenerera trigger-funktionen med uppdaterad kolumnlista
                        IF antal_tillagda > 0 THEN
                            RAISE NOTICE '[hantera_kolumntillagg] Regenererar trigger-funktion för att inkludera nya kolumner...';
                            
                            DECLARE
                                ny_kolumn_lista text;
                                trigger_funktionsnamn text := 'trg_fn_' || tabell_namn || '_qa';
                                qa_kolumner text[];
                                qa_uttryck text[];
                                trigger_satser text := '';
                                j integer;
                            BEGIN
                                -- Hämta uppdaterad kolumnlista från modertabellen
                                SELECT string_agg(c.column_name, ', ' ORDER BY c.ordinal_position)
                                INTO ny_kolumn_lista
                                FROM information_schema.columns c
                                WHERE c.table_schema = schema_namn
                                AND c.table_name = tabell_namn;
                                
                                -- Hämta QA-kolumner och deras uttryck
                                SELECT 
                                    array_agg(sk.kolumnnamn ORDER BY sk.ordinal_position),
                                    array_agg(sk.default_varde ORDER BY sk.ordinal_position)
                                INTO qa_kolumner, qa_uttryck
                                FROM standardiserade_kolumner sk
                                WHERE sk.historik_qa = true
                                AND sk.default_varde IS NOT NULL
                                AND EXISTS (
                                    SELECT 1 FROM information_schema.columns c
                                    WHERE c.table_schema = schema_namn 
                                    AND c.table_name = tabell_namn 
                                    AND c.column_name = sk.kolumnnamn
                                );
                                
                                -- Bygg trigger-satser för QA-uppdatering
                                FOR j IN 1..COALESCE(array_length(qa_kolumner, 1), 0) LOOP
                                    trigger_satser := trigger_satser || format(
                                        E'        rad.%I = %s;\n',
                                        qa_kolumner[j], qa_uttryck[j]
                                    );
                                END LOOP;
                                
                                -- Återskapa trigger-funktionen med ny kolumnlista
                                EXECUTE format($TRIG$
                                    CREATE OR REPLACE FUNCTION %I.%I()
                                    RETURNS TRIGGER AS $$
                                    DECLARE
                                        rad %I.%I%%ROWTYPE;
                                    BEGIN
                                        IF TG_OP = 'UPDATE' THEN
                                            rad := NEW;
                                            
                                            -- Sätt QA-värden
%s                
                                            -- Kopiera gamla värdet till historik
                                            INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                                            SELECT 'U', NOW(), session_user, OLD.*;
                                            
                                            RETURN rad;
                                        ELSE -- DELETE
                                            rad := OLD;
                                            
                                            -- Sätt QA-värden även för DELETE (för konsistens)
%s                
                                            -- Kopiera till historik
                                            INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                                            SELECT 'D', NOW(), session_user, rad.*;
                                            
                                            RETURN OLD;
                                        END IF;
                                    END;
                                    $$ LANGUAGE plpgsql;
                                $TRIG$,
                                    schema_namn, trigger_funktionsnamn,
                                    schema_namn, tabell_namn,
                                    trigger_satser,
                                    schema_namn, historik_tabell_namn, ny_kolumn_lista,
                                    trigger_satser,
                                    schema_namn, historik_tabell_namn, ny_kolumn_lista
                                );
                                
                                RAISE NOTICE '[hantera_kolumntillagg]   ✓ Trigger-funktion % regenererad', trigger_funktionsnamn;
                            EXCEPTION
                                WHEN OTHERS THEN
                                    RAISE WARNING '[hantera_kolumntillagg]   ✗ Kunde inte regenerera trigger-funktion: %', SQLERRM;
                            END;
                        END IF;
                        
                        -- Flytta standardkolumner med negativ ordinal_position till rätt plats i historiktabellen
                        RAISE NOTICE '[hantera_kolumntillagg] Reorganiserar standardkolumner i historiktabellen...';
                        
                        DECLARE
                            h_kolumn record;
                            h_kolumn_typ text;
                        BEGIN
                            FOR h_kolumn IN 
                                SELECT sk.kolumnnamn
                                FROM standardiserade_kolumner sk
                                WHERE sk.ordinal_position < 0
                                AND EXISTS (
                                    SELECT 1 FROM information_schema.columns c
                                    WHERE c.table_schema = schema_namn
                                    AND c.table_name = historik_tabell_namn
                                    AND c.column_name = sk.kolumnnamn
                                )
                                ORDER BY sk.ordinal_position
                            LOOP
                                -- Hämta kolumntyp från historiktabellen
                                SELECT 
                                    CASE 
                                        WHEN c.data_type = 'USER-DEFINED' THEN c.udt_name
                                        WHEN c.data_type = 'character varying' THEN 
                                            'character varying' || 
                                            CASE WHEN c.character_maximum_length IS NOT NULL 
                                                 THEN '(' || c.character_maximum_length || ')'
                                                 ELSE ''
                                            END
                                        ELSE c.data_type
                                    END
                                INTO h_kolumn_typ
                                FROM information_schema.columns c
                                WHERE c.table_schema = schema_namn
                                AND c.table_name = historik_tabell_namn
                                AND c.column_name = h_kolumn.kolumnnamn;
                                
                                -- Flytta kolumnen med temp-kolumn-teknik
                                EXECUTE format(
                                    'ALTER TABLE %I.%I ADD COLUMN %I_temp0001 %s',
                                    schema_namn, historik_tabell_namn, h_kolumn.kolumnnamn, h_kolumn_typ
                                );
                                EXECUTE format(
                                    'UPDATE %I.%I SET %I_temp0001 = %I',
                                    schema_namn, historik_tabell_namn, h_kolumn.kolumnnamn, h_kolumn.kolumnnamn
                                );
                                EXECUTE format(
                                    'ALTER TABLE %I.%I DROP COLUMN %I',
                                    schema_namn, historik_tabell_namn, h_kolumn.kolumnnamn
                                );
                                EXECUTE format(
                                    'ALTER TABLE %I.%I RENAME COLUMN %I_temp0001 TO %I',
                                    schema_namn, historik_tabell_namn, h_kolumn.kolumnnamn, h_kolumn.kolumnnamn
                                );
                                
                                RAISE NOTICE '[hantera_kolumntillagg]   ✓ Flyttade % till slutet av %', 
                                    h_kolumn.kolumnnamn, historik_tabell_namn;
                            END LOOP;
                        EXCEPTION
                            WHEN OTHERS THEN
                                RAISE WARNING '[hantera_kolumntillagg]   ✗ Kunde inte reorganisera standardkolumner i historiktabell: %', SQLERRM;
                        END;
                        
                        -- Flytta geom till slutet av historiktabellen om den finns
                        IF EXISTS (
                            SELECT 1 FROM information_schema.columns
                            WHERE table_schema = schema_namn
                            AND table_name = historik_tabell_namn
                            AND column_name = 'geom'
                        ) THEN
                            RAISE NOTICE '[hantera_kolumntillagg] Flyttar geom till slutet av historiktabellen...';
                            
                            DECLARE
                                h_geom_def text;
                            BEGIN
                                -- Hämta geometridefinition från modertabellen
                                SELECT geometriinfo.definition INTO h_geom_def;
                                
                                -- Om vi inte har geometriinfo, hämta från history table
                                IF h_geom_def IS NULL THEN
                                    SELECT format('geometry(%s,%s)', type, srid)
                                    INTO h_geom_def
                                    FROM geometry_columns
                                    WHERE f_table_schema = schema_namn
                                    AND f_table_name = historik_tabell_namn
                                    AND f_geometry_column = 'geom';
                                END IF;
                                
                                IF h_geom_def IS NOT NULL THEN
                                    -- Temp kolumn
                                    EXECUTE format(
                                        'ALTER TABLE %I.%I ADD COLUMN geom_temp0001 %s',
                                        schema_namn, historik_tabell_namn, h_geom_def
                                    );
                                    -- Kopiera data
                                    EXECUTE format(
                                        'UPDATE %I.%I SET geom_temp0001 = geom',
                                        schema_namn, historik_tabell_namn
                                    );
                                    -- Ta bort original
                                    EXECUTE format(
                                        'ALTER TABLE %I.%I DROP COLUMN geom',
                                        schema_namn, historik_tabell_namn
                                    );
                                    -- Döp om
                                    EXECUTE format(
                                        'ALTER TABLE %I.%I RENAME COLUMN geom_temp0001 TO geom',
                                        schema_namn, historik_tabell_namn
                                    );
                                    
                                    RAISE NOTICE '[hantera_kolumntillagg]   ✓ geom flyttad till slutet av %', historik_tabell_namn;
                                END IF;
                            EXCEPTION
                                WHEN OTHERS THEN
                                    RAISE WARNING '[hantera_kolumntillagg]   ✗ Kunde inte flytta geom i historiktabell: %', SQLERRM;
                            END;
                        END IF;
                    END IF;
                    
                    -- Visa kolumner som finns extra i historik (bara info, ingen åtgärd)
                    IF array_length(extra_i_historik, 1) > 0 THEN
                        RAISE NOTICE '[hantera_kolumntillagg] Extra kolumner i historik (behålls): %s', 
                            array_to_string(extra_i_historik, ', ');
                    END IF;
                    
                    -- Visa kolumner med olika datatyper (kräver manuell åtgärd)
                    IF array_length(typ_skillnader, 1) > 0 THEN
                        RAISE WARNING '[hantera_kolumntillagg] Olika datatyper (kräver manuell åtgärd): %s', 
                            array_to_string(typ_skillnader, ', ');
                    END IF;
                    
                    IF antal_skillnader = 0 THEN
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
            CASE WHEN NOT tabell_namn ~ '_h$' AND har_historiktabell
                 THEN 'Synkroniserad'
                 WHEN NOT tabell_namn ~ '_h$' AND NOT har_historiktabell
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
   historiktabeller (_h).

4. UPPDATERAD: Lägger automatiskt till saknade kolumner i historiktabeller för att
   hålla dem synkroniserade med modertabellen och undvika QA-trigger-krascher.

5. Varnar för typskillnader som kräver manuell åtgärd.

6. Behandlar även historiktabeller direkt för att säkerställa korrekt 
   kolumnordning i dessa tabeller också.

Funktionen använder detaljerad loggning med tydlig funktionsmarkering för att 
underlätta felsökning och omfattar rekursionskontroll för att undvika oändliga 
loopar vid tabellmodifieringar.';
