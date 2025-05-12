-- FUNCTION: public.ta_bort_schemaroller()

CREATE OR REPLACE FUNCTION public.ta_bort_schemaroller()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Tar automatiskt bort roller kopplade till scheman som tas bort.
 * För borttaget schema "exempel" tas rollerna "r_exempel" och "w_exempel" bort.
 *
 * Funktionen:
 * - Identifierar scheman som tas bort
 * - Tar bort motsvarande r_ och w_ roller
 * - Undviker systemscheman
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    r_roll_namn text;
    w_roll_namn text;
    r_roll_existerar boolean;
    w_roll_existerar boolean;
BEGIN
    RAISE NOTICE 'Startar ta_bort_schemaroller()';
    
    -- Identifiera borttagna scheman från trigger-händelsen
    FOR kommando IN SELECT * FROM pg_event_trigger_dropped_objects()
    WHERE object_type = 'schema'
    LOOP
        schema_namn := kommando.object_name;
        r_roll_namn := 'r_' || schema_namn;
        w_roll_namn := 'w_' || schema_namn;
        
        RAISE NOTICE 'Schema borttaget: %, kontrollerar roller: % och %', 
                     schema_namn, r_roll_namn, w_roll_namn;
        
        -- Hoppa över systemscheman
        IF schema_namn = 'public' OR schema_namn LIKE 'pg\_%' OR schema_namn = 'information_schema' THEN
            RAISE NOTICE 'Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;
        
        -- Kontrollera om rollerna existerar
        SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = r_roll_namn) INTO r_roll_existerar;
        SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = w_roll_namn) INTO w_roll_existerar;
        
        -- Ta bort r_roll om den existerar
        IF r_roll_existerar THEN
            EXECUTE format('DROP ROLE %I', r_roll_namn);
            RAISE NOTICE 'Roll % borttagen', r_roll_namn;
        ELSE
            RAISE NOTICE 'Roll % existerar inte, ingen åtgärd', r_roll_namn;
        END IF;
        
        -- Ta bort w_roll om den existerar
        IF w_roll_existerar THEN
            EXECUTE format('DROP ROLE %I', w_roll_namn);
            RAISE NOTICE 'Roll % borttagen', w_roll_namn;
        ELSE
            RAISE NOTICE 'Roll % existerar inte, ingen åtgärd', w_roll_namn;
        END IF;
        
        RAISE NOTICE 'Upprensning slutförd för schema: %', schema_namn;
    END LOOP;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'FEL vid borttagning av roller: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.ta_bort_schemaroller()
    OWNER TO postgres;

COMMENT ON FUNCTION public.ta_bort_schemaroller()
    IS 'Tar automatiskt bort roller (r_schema och w_schema) när motsvarande schema tas bort.
Denna funktion behåller databasen ren från oanvända roller.';
