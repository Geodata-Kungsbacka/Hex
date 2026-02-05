-- FUNCTION: public.skapa_ny_schemaroll_r()

CREATE OR REPLACE FUNCTION public.skapa_ny_schemaroll_r()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Skapar automatiskt en roll med läsrättigheter (r_) för varje nytt schema.
 * För schema "exempel" skapas rollen "r_exempel" med läsbehörighet.
 *
 * Rättigheter som tilldelas:
 * - USAGE på schemat
 * - SELECT på tabeller, vyer, materialiserade vyer och sekvenser
 * - DEFAULT PRIVILEGES för framtida objekt
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    roll_namn text;
    roll_existerar boolean;
BEGIN
    RAISE NOTICE 'Startar skapa_ny_schemaroll_r()';
    
    -- Identifiera nya scheman från trigger-händelsen
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := split_part(kommando.object_identity, '.', 1);
        roll_namn := 'r_' || schema_namn;
        
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
            -- Ge ägarrollen ADMIN OPTION så den kan hantera denna roll
            EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', roll_namn, system_owner());
            EXECUTE format('COMMENT ON ROLE %I IS ''Läsrättigheter för schema %I''', 
                         roll_namn, schema_namn);
        END IF;
        
        -- Tilldela grundläggande rättigheter
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_namn, roll_namn);
        
        -- Rättigheter för tabeller och vyer
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', schema_namn, roll_namn);
        
        -- Rättigheter för materialiserade vyer (om stöds i denna PostgreSQL-version)
        BEGIN
            EXECUTE format('GRANT SELECT ON ALL MATERIALIZED VIEWS IN SCHEMA %I TO %I', 
                          schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om materialiserade vyer inte stöds
        END;
        
        -- Rättigheter för sekvenser
        EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', schema_namn, roll_namn);
        
        -- Sätt standardrättigheter för framtida objekt
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', 
                       schema_namn, roll_namn);
        
        -- Standardrättigheter för framtida materialiserade vyer
        BEGIN
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON MATERIALIZED VIEWS TO %I', 
                           schema_namn, roll_namn);
        EXCEPTION WHEN OTHERS THEN
            -- Ignorera fel om materialiserade vyer inte stöds
        END;
        
        -- Standardrättigheter för framtida sekvenser
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I', 
                       schema_namn, roll_namn);
        
        RAISE NOTICE 'Slutfört för roll %', roll_namn;
    END LOOP;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'FEL: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.skapa_ny_schemaroll_r()
    OWNER TO postgres;

COMMENT ON FUNCTION public.skapa_ny_schemaroll_r()
    IS 'Skapar automatiskt en roll med läsrättigheter (r_schema) för varje nytt schema.
Rollen får USAGE-behörighet på schemat och SELECT-behörighet på alla objekt
inklusive tabeller, vyer, materialiserade vyer och sekvenser.';
