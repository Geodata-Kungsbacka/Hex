CREATE OR REPLACE FUNCTION public.ta_bort_schemaroller()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
    SECURITY DEFINER
AS $BODY$

/******************************************************************************
 * Tar automatiskt bort roller kopplade till scheman som tas bort.
 * Läser nu konfiguration från standardiserade_roller istället för hårdkodade rollnamn.
 *
 * SECURITY DEFINER: Körs som funktionens ägare (postgres) för att säkerställa
 * att roller kan tas bort oavsett vilken användare som droppar schemat.
 * I PostgreSQL 16+ krävs CREATEROLE + ADMIN OPTION för att droppa roller,
 * och SECURITY DEFINER garanterar att postgres (superuser) hanterar detta.
 *
 * UPPDATERAD FUNKTIONALITET:
 * - Tar endast bort roller där ta_bort_med_schema = true
 * - Hanterar både grupproller och LOGIN-roller
 * - Bevarar globala roller (ta_bort_med_schema = false)
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    rollkonfiguration record;
    slutligt_rollnamn text;
    login_rollnamn text;
    roll_existerar boolean;
    antal_borttagna integer := 0;
BEGIN
    RAISE NOTICE E'[ta_bort_schemaroller] === START ===';
    RAISE NOTICE '[ta_bort_schemaroller] Hanterar rollborttagning för borttagna scheman';
    
    -- Identifiera borttagna scheman från trigger-händelsen
    FOR kommando IN SELECT * FROM pg_event_trigger_dropped_objects()
    WHERE object_type = 'schema'
    LOOP
        schema_namn := kommando.object_name;
        
        RAISE NOTICE E'[ta_bort_schemaroller] ================';
        RAISE NOTICE '[ta_bort_schemaroller] Schema borttaget: %', schema_namn;
        
        -- Hoppa över systemscheman
        IF schema_namn = 'public' OR schema_namn ~ '^pg_' OR schema_namn = 'information_schema' THEN
            RAISE NOTICE '[ta_bort_schemaroller] Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;
        
        -- Loopa genom rollkonfigurationer som ska tas bort med schema
        FOR rollkonfiguration IN 
            SELECT * FROM standardiserade_roller 
            WHERE ta_bort_med_schema = true
            ORDER BY gid
        LOOP
            -- Bygg rollnamn
            slutligt_rollnamn := replace(rollkonfiguration.rollnamn, '{schema}', schema_namn);
            
            RAISE NOTICE '[ta_bort_schemaroller] Kontrollerar roll: %', slutligt_rollnamn;
            
            -- Ta bort LOGIN-roller först (de har beroenden till grupproll)
            FOR i IN 1..COALESCE(array_length(rollkonfiguration.login_roller, 1), 0) LOOP
                DECLARE
                    login_definition text := rollkonfiguration.login_roller[i];
                BEGIN
                    -- Bygg LOGIN-rollnamn
                    IF login_definition ~ '^_' THEN
                        login_rollnamn := slutligt_rollnamn || login_definition;
                    ELSIF login_definition ~ '_$' THEN
                        login_rollnamn := login_definition || slutligt_rollnamn;
                    ELSE
                        CONTINUE; -- Hoppa över ogiltiga format
                    END IF;
                    
                    -- Kontrollera om LOGIN-roll existerar
                    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = login_rollnamn) INTO roll_existerar;
                    
                    IF roll_existerar THEN
                        EXECUTE format('REASSIGN OWNED BY %I TO postgres', login_rollnamn);
                        EXECUTE format('DROP OWNED BY %I', login_rollnamn);
                        EXECUTE format('DROP ROLE %I', login_rollnamn);
                        RAISE NOTICE '[ta_bort_schemaroller]   ✓ LOGIN-roll borttagen: %', login_rollnamn;
                        antal_borttagna := antal_borttagna + 1;
                    ELSE
                        RAISE NOTICE '[ta_bort_schemaroller]   - LOGIN-roll existerar inte: %', login_rollnamn;
                    END IF;
                END;
            END LOOP;
            
            -- Ta bort grupproll
            SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = slutligt_rollnamn) INTO roll_existerar;
            
            IF roll_existerar THEN
                EXECUTE format('REASSIGN OWNED BY %I TO postgres', slutligt_rollnamn);
                EXECUTE format('DROP OWNED BY %I', slutligt_rollnamn);
                EXECUTE format('DROP ROLE %I', slutligt_rollnamn);
                RAISE NOTICE '[ta_bort_schemaroller]   ✓ Grupproll borttagen: %', slutligt_rollnamn;
                antal_borttagna := antal_borttagna + 1;
            ELSE
                RAISE NOTICE '[ta_bort_schemaroller]   - Grupproll existerar inte: %', slutligt_rollnamn;
            END IF;
        END LOOP;
        
        RAISE NOTICE '[ta_bort_schemaroller] Sammanfattning för schema %: % roller borttagna', 
            schema_namn, antal_borttagna;
        antal_borttagna := 0; -- Återställ för nästa schema
    END LOOP;

    RAISE NOTICE '[ta_bort_schemaroller] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[ta_bort_schemaroller] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[ta_bort_schemaroller]   - Schema: %', schema_namn;
        RAISE NOTICE '[ta_bort_schemaroller]   - Fel: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.ta_bort_schemaroller()
    OWNER TO postgres;

COMMENT ON FUNCTION public.ta_bort_schemaroller()
    IS 'Tar automatiskt bort roller när scheman tas bort. Läser konfiguration från 
    standardiserade_roller och tar endast bort roller där ta_bort_med_schema = true. 
    Hanterar både grupproller och LOGIN-roller i korrekt ordning.';
