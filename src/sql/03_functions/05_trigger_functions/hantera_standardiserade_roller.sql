CREATE OR REPLACE FUNCTION public.hantera_standardiserade_roller()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Event trigger-funktion som skapar roller automatiskt när nya scheman skapas.
 * 
 * FUNKTIONALITET:
 * 1. Läser konfiguration från standardiserade_roller-tabellen
 * 2. Evaluerar schema_uttryck för att avgöra vilka roller som ska skapas
 * 3. Skapar NOLOGIN-grupproller med rättigheter
 * 4. Skapar LOGIN-roller för specifika applikationer som ärver grupprollernas rättigheter
 *
 * ROLLSTRUKTUR:
 * - Grupproll (NOLOGIN): t.ex. r_sk0_global, w_sk1_kba_bygg
 * - LOGIN-roller: t.ex. r_sk0_global_geoserver, w_sk1_kba_bygg_admin_app
 *
 * TRIGGER: Körs automatiskt vid CREATE SCHEMA
 ******************************************************************************/
DECLARE
    kommando record;                 -- Information om CREATE SCHEMA-kommandot
    schema_namn text;               -- Namnet på det nya schemat
    rollkonfiguration record;       -- Konfiguration från standardiserade_roller
    slutligt_rollnamn text;         -- Namnet på grupproll efter {schema}-ersättning
    matchar boolean;                -- Om schema_uttryck matchar detta schema
    antal_roller integer := 0;      -- Räknare för skapade roller
    antal_login_roller integer := 0; -- Räknare för skapade LOGIN-roller
BEGIN
    RAISE NOTICE E'[hantera_standardiserade_roller] === START ===';
    RAISE NOTICE '[hantera_standardiserade_roller] Hanterar rollskapande för nya scheman';
    
    -- Hantera alla CREATE SCHEMA-kommandon
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');
        
        RAISE NOTICE E'[hantera_standardiserade_roller] ================';
        RAISE NOTICE '[hantera_standardiserade_roller] Bearbetar schema: %', schema_namn;
        
        -- Hoppa över systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[hantera_standardiserade_roller] Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;
        
        -- Loopa genom alla rollkonfigurationer
        FOR rollkonfiguration IN 
            SELECT * FROM standardiserade_roller ORDER BY gid
        LOOP
            RAISE NOTICE '[hantera_standardiserade_roller] Testar rollkonfiguration: % (typ: %)', 
                rollkonfiguration.rollnamn, rollkonfiguration.rolltyp;
            
            -- Testa om schema_uttryck matchar detta schema
            BEGIN
                EXECUTE format('SELECT %L %s', schema_namn, rollkonfiguration.schema_uttryck) INTO matchar;
                RAISE NOTICE '[hantera_standardiserade_roller]   Schema_uttryck "%s" matchar: %', 
                    rollkonfiguration.schema_uttryck, matchar;
                
                IF matchar THEN
                    -- Ersätt {schema} med faktiskt schemanamn
                    slutligt_rollnamn := replace(rollkonfiguration.rollnamn, '{schema}', schema_namn);
                    RAISE NOTICE '[hantera_standardiserade_roller]   Slutligt rollnamn: %', slutligt_rollnamn;
                    
                    -- 1. Skapa NOLOGIN-grupproll
                    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = slutligt_rollnamn) THEN
                        EXECUTE format('CREATE ROLE %I WITH NOLOGIN', slutligt_rollnamn);
                        -- Ge ägarrollen ADMIN OPTION så den kan hantera denna roll
                        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', slutligt_rollnamn, system_owner());
                        RAISE NOTICE '[hantera_standardiserade_roller]   ✓ Skapade grupproll (NOLOGIN): %', slutligt_rollnamn;
                        antal_roller := antal_roller + 1;
                        
                        -- Tilldela rättigheter till grupproll
                        PERFORM tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                    ELSE
                        RAISE NOTICE '[hantera_standardiserade_roller]   - Grupproll finns redan: %', slutligt_rollnamn;
                        
                        -- Tilldela rättigheter på detta schema även till befintlig roll
                        PERFORM tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                    END IF;
                    
                    -- 2. Skapa LOGIN-roller baserat på login_roller-array
                    FOR i IN 1..COALESCE(array_length(rollkonfiguration.login_roller, 1), 0) LOOP
                        DECLARE
                            login_definition text := rollkonfiguration.login_roller[i];
                            login_rollnamn text;
                        BEGIN
                            -- Kontrollera om det är suffix (börjar med _) eller prefix (slutar med _)
                            IF login_definition ~ '^_' THEN
                                -- Suffix: r_sk0_global + _geoserver = r_sk0_global_geoserver
                                login_rollnamn := slutligt_rollnamn || login_definition;
                            ELSIF login_definition ~ '_$' THEN
                                -- Prefix: geoserver_ + r_sk0_global = geoserver_r_sk0_global
                                login_rollnamn := login_definition || slutligt_rollnamn;
                            ELSE
                                RAISE WARNING '[hantera_standardiserade_roller] LOGIN-roll "%" måste börja eller sluta med understreck', 
                                    login_definition;
                                CONTINUE;
                            END IF;
                            
                            IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = login_rollnamn) THEN
                                -- Skapa LOGIN-roll
                                EXECUTE format('CREATE ROLE %I WITH LOGIN', login_rollnamn);
                                -- Ge ägarrollen ADMIN OPTION så den kan hantera denna roll
                                EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', login_rollnamn, system_owner());
                                RAISE NOTICE '[hantera_standardiserade_roller]   ✓ Skapade LOGIN-roll: %', login_rollnamn;
                                antal_login_roller := antal_login_roller + 1;
                                
                                -- Gör LOGIN-rollen medlem i grupproll (ärver alla rättigheter)
                                EXECUTE format('GRANT %I TO %I', slutligt_rollnamn, login_rollnamn);
                                RAISE NOTICE '[hantera_standardiserade_roller]   ✓ Tilldelade grupproll % till LOGIN-roll %', 
                                    slutligt_rollnamn, login_rollnamn;
                            ELSE
                                RAISE NOTICE '[hantera_standardiserade_roller]   - LOGIN-roll finns redan: %', login_rollnamn;
                            END IF;
                        END;
                    END LOOP;
                ELSE
                    RAISE NOTICE '[hantera_standardiserade_roller]   - Schema_uttryck matchade inte, hoppar över';
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING '[hantera_standardiserade_roller] Fel vid evaluering av schema_uttryck för roll %: %', 
                        rollkonfiguration.rollnamn, SQLERRM;
            END;
        END LOOP;
        
        -- Sammanfattning för detta schema
        RAISE NOTICE '[hantera_standardiserade_roller] Sammanfattning för schema %:', schema_namn;
        RAISE NOTICE '[hantera_standardiserade_roller]   ‚» Grupproller skapade: %', antal_roller;
        RAISE NOTICE '[hantera_standardiserade_roller]   ‚» LOGIN-roller skapade: %', antal_login_roller;
        
        -- Återställ räknare för nästa schema
        antal_roller := 0;
        antal_login_roller := 0;
    END LOOP;
    
    RAISE NOTICE '[hantera_standardiserade_roller] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hantera_standardiserade_roller] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hantera_standardiserade_roller]   - Schema: %', schema_namn;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Rollkonfiguration: %', rollkonfiguration.rollnamn;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_standardiserade_roller()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_standardiserade_roller()
    IS 'Event trigger-funktion för automatisk rollskapande vid CREATE SCHEMA. 
    Läser konfiguration från standardiserade_roller och skapar både NOLOGIN-grupproller 
    och LOGIN-roller för specifika applikationer enligt schema_uttryck-matchning.';
