-- FUNCTION: public.skapa_ny_schemaroll_w()

CREATE OR REPLACE FUNCTION public.skapa_ny_schemaroll_w()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Skapar automatiskt en roll med läs- och skrivrättigheter (w_) för varje nytt schema.
 * För schema "exempel" skapas rollen "w_exempel" med fullständiga rättigheter.
 *
 * Rättigheter som tilldelas:
 * - USAGE på schemat
 * - ALL PRIVILEGES på tabeller, vyer och materialiserade vyer
 * - USAGE, SELECT, UPDATE på sekvenser
 * - EXECUTE på funktioner och procedurer
 * - DEFAULT PRIVILEGES för framtida objekt
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    roll_namn text;
    roll_existerar boolean;
BEGIN
    RAISE NOTICE 'Startar skapa_ny_schemaroll_w()';
    
    -- Identifiera nya scheman från trigger-händelsen
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := split_part(kommando.object_identity, '.', 1);
        roll_namn := 'w_' || schema_namn;
        
        RAISE NOTICE 'Bearbetar schema: %, roll: %', schema_namn, roll_namn;
        
        -- Hoppa över systemscheman
        IF schema_namn = 'public' OR schema_namn LIKE 'pg\_%' OR schema_namn = 'information_schema' THEN
            RAISE NOTICE 'Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;
        
        -- Kontrollera om rollen redan existerar
        SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = roll_namn) INTO roll_existerar;
        
        -- Skapa roll om den inte existerar
        IF NOT roll_existerar THEN
            EXECUTE format('CREATE ROLE %I WITH NOLOGIN', roll_namn);
            EXECUTE format('COMMENT ON ROLE %I IS ''Läs- och skrivrättigheter för schema %I''', 
                         roll_namn, schema_namn);
        END IF;
        
        -- Tilldela grundläggande rättigheter
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_namn, roll_namn);
        
        -- Rättigheter för tabeller och vyer
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %I', 
                      schema_namn, roll_namn);
        
        -- Rättigheter för materialiserade vyer
        BEGIN
            EXECUTE format('GRANT ALL PRIVILEGES ON ALL MATERIALIZED VIEWS IN SCHEMA %I TO %I', 
                          schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om materialiserade vyer inte stöds
        END;
        
        -- Rättigheter för sekvenser
        EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', 
                      schema_namn, roll_namn);
        
        -- Lägg till funktions- och procedurutförande
        BEGIN
            EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', 
                          schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om det inte finns några funktioner
        END;
        
        BEGIN
            EXECUTE format('GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA %I TO %I', 
                          schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel (inga procedurer eller PostgreSQL < 11)
        END;
        
        -- Sätt standardrättigheter för framtida objekt
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL PRIVILEGES ON TABLES TO %I', 
                       schema_namn, roll_namn);
        
        -- Standardrättigheter för framtida materialiserade vyer
        BEGIN
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL PRIVILEGES ON MATERIALIZED VIEWS TO %I', 
                           schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om materialiserade vyer inte stöds
        END;
        
        -- Standardrättigheter för framtida sekvenser
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', 
                       schema_namn, roll_namn);
        
        -- Standardrättigheter för framtida funktioner
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', 
                       schema_namn, roll_namn);
        
        -- Standardrättigheter för framtida procedurer
        BEGIN
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON PROCEDURES TO %I', 
                           schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om PostgreSQL < 11
        END;
        
        RAISE NOTICE 'Slutfört för roll %', roll_namn;
    END LOOP;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'FEL: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.skapa_ny_schemaroll_w()
    OWNER TO postgres;

COMMENT ON FUNCTION public.skapa_ny_schemaroll_w()
    IS 'Skapar automatiskt en roll med läs- och skrivrättigheter (w_schema) för varje nytt schema.
Rollen får fullständiga rättigheter på alla objekt i schemat inklusive tabeller, vyer, 
materialiserade vyer, sekvenser, funktioner och procedurer.';