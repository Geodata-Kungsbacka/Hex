CREATE OR REPLACE FUNCTION public.ta_bort_schemaroller()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
    SECURITY DEFINER
AS $BODY$

/******************************************************************************
 * Tar automatiskt bort roller kopplade till scheman som tas bort.
 * Läser konfiguration från standardiserade_roller istället för hårdkodade rollnamn.
 *
 * SECURITY DEFINER: Körs som funktionens ägare (postgres) för att säkerställa
 * att roller kan tas bort oavsett vilken användare som droppar schemat.
 * I PostgreSQL 16+ krävs CREATEROLE + ADMIN OPTION för att droppa roller,
 * och SECURITY DEFINER garanterar att postgres (superuser) hanterar detta.
 *
 * FUNKTIONALITET:
 * - Tar endast bort roller där ta_bort_med_schema = true
 * - Rensar hex_role_credentials för borttagna LOGIN-roller
 * - Bevarar globala roller (ta_bort_med_schema = false)
 ******************************************************************************/
DECLARE
    kommando            record;
    schema_namn         text;
    rollkonfiguration   record;
    slutligt_rollnamn   text;
    roll_existerar      boolean;
    antal_borttagna     integer := 0;
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
            slutligt_rollnamn := replace(rollkonfiguration.rollnamn, '{schema}', schema_namn);

            RAISE NOTICE '[ta_bort_schemaroller] Kontrollerar roll: %', slutligt_rollnamn;

            SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = slutligt_rollnamn) INTO roll_existerar;

            IF roll_existerar THEN
                BEGIN
                    EXECUTE format('REASSIGN OWNED BY %I TO postgres', slutligt_rollnamn);
                    EXECUTE format('DROP OWNED BY %I', slutligt_rollnamn);
                    EXECUTE format('DROP ROLE %I', slutligt_rollnamn);

                    -- Rensa sparade autentiseringsuppgifter
                    DELETE FROM hex_role_credentials WHERE rolname = slutligt_rollnamn;

                    RAISE NOTICE '[ta_bort_schemaroller]   ✓ Roll borttagen: %', slutligt_rollnamn;
                    antal_borttagna := antal_borttagna + 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        RAISE WARNING '[ta_bort_schemaroller]   ⚠ Kunde inte ta bort roll %: %', slutligt_rollnamn, SQLERRM;
                        RAISE WARNING '[ta_bort_schemaroller]     Rollen äger objekt i annan databas. Ta bort manuellt med: DROP ROLE %;', slutligt_rollnamn;
                END;
            ELSE
                RAISE NOTICE '[ta_bort_schemaroller]   - Roll existerar inte: %', slutligt_rollnamn;
            END IF;
        END LOOP;

        RAISE NOTICE '[ta_bort_schemaroller] Sammanfattning för schema %: % roller borttagna',
            schema_namn, antal_borttagna;
        antal_borttagna := 0;
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
    Rensar även hex_role_credentials för borttagna LOGIN-roller.';
