CREATE OR REPLACE FUNCTION public.hantera_borttagen_tabell()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
/******************************************************************************
 * Rensar upp historiktabeller och triggerfunktioner när en tabell tas bort.
 *
 * När en tabell med historik (t.ex. "byggnader_y") tas bort, tar denna
 * funktion automatiskt bort:
 *   1. Historiktabellen (t.ex. "byggnader_y_h")
 *   2. QA-triggerfunktionen (t.ex. "trg_fn_byggnader_y_qa")
 *
 * REKURSIONSSKYDD:
 * - Hoppar över om tabellstrukturering pågår (byt_ut_tabell droppar
 *   tabeller internt som del av omstruktureringen)
 * - Hoppar över om historikborttagning redan pågår (förhindrar rekursion
 *   när _h-tabellen droppas av denna funktion)
 *
 * UNDANTAG:
 * - Historiktabeller (_h-suffix) ignoreras för att undvika kaskad
 * - Tabeller i public-schemat ignoreras
 * - Temporära tabeller ignoreras
 * - Systemscheman (pg_*) ignoreras
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    tabell_namn text;
    historik_tabell text;
    trigger_funktion text;
BEGIN
    -- Hoppa över under omstrukturering (byt_ut_tabell droppar tabeller internt)
    IF current_setting('temp.tabellstrukturering_pagar', true) = 'true' THEN
        RETURN;
    END IF;

    -- Rekursionsskydd (denna funktion droppar _h-tabeller som triggar samma event)
    IF current_setting('temp.historikborttagning_pagar', true) = 'true' THEN
        RETURN;
    END IF;
    PERFORM set_config('temp.historikborttagning_pagar', 'true', true);

    FOR kommando IN SELECT * FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
        AND NOT is_temporary
    LOOP
        schema_namn := kommando.schema_name;
        tabell_namn := kommando.object_name;

        -- Hoppa över historiktabeller, public och systemscheman
        IF tabell_namn ~ '_h$' OR schema_namn = 'public' OR schema_namn ~ '^pg_' THEN
            CONTINUE;
        END IF;

        historik_tabell := tabell_namn || '_h';
        trigger_funktion := 'trg_fn_' || tabell_namn || '_qa';

        -- Ta bort historiktabell om den finns
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = schema_namn
            AND table_name = historik_tabell
        ) THEN
            EXECUTE format('DROP TABLE %I.%I', schema_namn, historik_tabell);
            RAISE NOTICE '[hantera_borttagen_tabell] ✓ Historiktabell borttagen: %.%',
                schema_namn, historik_tabell;
        END IF;

        -- Ta bort triggerfunktion om den finns
        IF EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = schema_namn
            AND p.proname = trigger_funktion
        ) THEN
            EXECUTE format('DROP FUNCTION %I.%I()', schema_namn, trigger_funktion);
            RAISE NOTICE '[hantera_borttagen_tabell] ✓ Triggerfunktion borttagen: %.%()',
                schema_namn, trigger_funktion;
        END IF;
    END LOOP;

    PERFORM set_config('temp.historikborttagning_pagar', 'false', true);

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('temp.historikborttagning_pagar', 'false', true);
        RAISE NOTICE '[hantera_borttagen_tabell] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hantera_borttagen_tabell]   - Schema: %', schema_namn;
        RAISE NOTICE '[hantera_borttagen_tabell]   - Tabell: %', tabell_namn;
        RAISE NOTICE '[hantera_borttagen_tabell]   - Fel: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_borttagen_tabell()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_borttagen_tabell()
    IS 'Event trigger-funktion som körs vid DROP TABLE för att automatiskt ta bort
tillhörande historiktabell (_h) och QA-triggerfunktion (trg_fn_*_qa). Hoppar
över under tabellomstrukturering (byt_ut_tabell) och förhindrar rekursion vid
borttagning av historiktabeller.';
