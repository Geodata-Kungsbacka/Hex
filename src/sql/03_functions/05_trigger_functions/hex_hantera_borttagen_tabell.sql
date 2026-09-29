CREATE OR REPLACE FUNCTION public.hex_hantera_borttagen_tabell()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
/******************************************************************************
 * Rensar upp historiktabeller, triggerfunktioner och afvaktande geometriposter
 * när en tabell tas bort.
 *
 * När en tabell med historik (t.ex. "byggnader_y") tas bort, tar denna
 * funktion automatiskt bort:
 *   1. Historiktabellen (t.ex. "byggnader_y_h")
 *   2. QA-triggerfunktionen (t.ex. "trg_fn_byggnader_y_qa")
 *   3. Eventuell afvaktande geometripost i hex_afvaktande_geometri
 *      (uppstår om en systemanvändare, t.ex. FME, droppade tabellen innan
 *      geometrikolumnen hann läggas till via ALTER TABLE)
 *   4. Eventuella rader i hex_avvikande_srid och hex_dummy_geometrier
 *   5. Raden i hex_metadata, via hex_rensa_metadata() efter loopen
 *
 * DROP SCHEMA ... CASCADE:
 *   Triggern lyssnar även på DROP SCHEMA. Schemats tabeller rapporteras då av
 *   pg_event_trigger_dropped_objects() under taggen DROP SCHEMA och städas på
 *   samma sätt som vid DROP TABLE. Historiktabeller och triggerfunktioner är
 *   redan borttagna av CASCADE, så EXISTS-kontrollerna nedan blir falska.
 *   Därefter rensas alla kvarvarande Hex-rader för själva schemat, så att inga
 *   inaktuella OID:er (som kan återanvändas av en ny tabell) blir kvar.
 *
 * REKURSIONSSKYDD:
 * - Hoppar över om tabellstrukturering pågår (hex_byt_ut_tabell droppar
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
    -- Hoppa över under omstrukturering (hex_byt_ut_tabell droppar tabeller internt)
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

        -- Slå upp faktiska namn via OID (stabilt genom RENAME TO).
        -- Faller tillbaka på namnkonvention om posten saknas i metadata
        -- (t.ex. tabeller skapade innan hex_metadata introducerades).
        DECLARE
            meta_rad record;
        BEGIN
            SELECT * INTO meta_rad
            FROM hex_metadata
            WHERE parent_oid = kommando.objid;

            IF FOUND THEN
                historik_tabell  := meta_rad.history_table;
                trigger_funktion := COALESCE(meta_rad.trigger_funktion,
                                             'trg_fn_' || tabell_namn || '_qa');
            ELSE
                historik_tabell  := tabell_namn || '_h';
                trigger_funktion := 'trg_fn_' || tabell_namn || '_qa';
            END IF;
        END;

        -- Ta bort historiktabell om den finns
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = schema_namn
            AND table_name = historik_tabell
        ) THEN
            EXECUTE format('DROP TABLE %I.%I', schema_namn, historik_tabell);
            RAISE NOTICE '[hex_hantera_borttagen_tabell] ✓ Historiktabell borttagen: %.%',
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
            RAISE NOTICE '[hex_hantera_borttagen_tabell] ✓ Triggerfunktion borttagen: %.%()',
                schema_namn, trigger_funktion;
        END IF;

        -- Metadataraden rensas efter loopen av hex_rensa_metadata()

        -- Rensa eventuell afvaktande geometripost (FME-tvåstegsmönster)
        -- Uppstår om systemanvändaren droppade tabellen innan geometrin hann läggas till.
        -- EXECUTE USING krävs: schema_namn/tabell_namn är kolumnnamn i hex_afvaktande_geometri
        -- OCH lokala variabelnamn – statisk SQL ger tvetydighetsfel.
        EXECUTE 'DELETE FROM public.hex_afvaktande_geometri WHERE schema_namn = $1 AND tabell_namn = $2'
            USING schema_namn, tabell_namn;
        IF FOUND THEN
            RAISE NOTICE '[hex_hantera_borttagen_tabell] ✓ Afvaktande geometripost borttagen: %.%',
                schema_namn, tabell_namn;
        END IF;

        -- Rensa eventuell SRID-avvikelsepost
        EXECUTE 'DELETE FROM public.hex_avvikande_srid WHERE schema_namn = $1 AND tabell_namn = $2'
            USING schema_namn, tabell_namn;
        IF FOUND THEN
            RAISE NOTICE '[hex_hantera_borttagen_tabell] ✓ SRID-avvikelsepost borttagen: %.%',
                schema_namn, tabell_namn;
        END IF;

        -- Rensa eventuella dummy-geometriposter (triggern hex_ta_bort_dummy
        -- droppas automatiskt av PostgreSQL när tabellen tas bort)
        EXECUTE 'DELETE FROM public.hex_dummy_geometrier WHERE schema_namn = $1 AND tabell_namn = $2'
            USING schema_namn, tabell_namn;
        IF FOUND THEN
            RAISE NOTICE '[hex_hantera_borttagen_tabell] ✓ Dummy-geometripost borttagen: %.%',
                schema_namn, tabell_namn;
        END IF;
    END LOOP;

    -- Rensa alla Hex-rader för borttagna scheman (DROP SCHEMA ... CASCADE).
    -- Fångar även rader som inte matchades per tabell ovan.
    FOR kommando IN SELECT * FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'schema'
    LOOP
        schema_namn := kommando.object_name;
        tabell_namn := NULL;

        IF schema_namn = 'public' OR schema_namn ~ '^pg_' THEN
            CONTINUE;
        END IF;

        -- EXECUTE USING av samma skäl som ovan (kolumnnamn = variabelnamn)
        EXECUTE 'DELETE FROM public.hex_afvaktande_geometri WHERE schema_namn = $1'
            USING schema_namn;
        EXECUTE 'DELETE FROM public.hex_avvikande_srid WHERE schema_namn = $1'
            USING schema_namn;
        EXECUTE 'DELETE FROM public.hex_dummy_geometrier WHERE schema_namn = $1'
            USING schema_namn;
    END LOOP;

    -- hex_metadata är inte skrivbar för PUBLIC. hex_rensa_metadata() (SECURITY
    -- DEFINER) tar bort rader vars tabell inte längre finns i pg_class – vid
    -- sql_drop precis de nyss borttagna, både vid DROP TABLE och DROP SCHEMA.
    PERFORM public.hex_rensa_metadata();

    PERFORM set_config('temp.historikborttagning_pagar', 'false', true);

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('temp.historikborttagning_pagar', 'false', true);
        RAISE NOTICE '[hex_hantera_borttagen_tabell] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_hantera_borttagen_tabell]   - Schema: %', schema_namn;
        RAISE NOTICE '[hex_hantera_borttagen_tabell]   - Tabell: %', tabell_namn;
        RAISE NOTICE '[hex_hantera_borttagen_tabell]   - Fel: %', SQLERRM;
        RAISE;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_hantera_borttagen_tabell() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_hantera_borttagen_tabell()
    IS 'Händelsetriggerfunktion som körs vid DROP TABLE och DROP SCHEMA och automatiskt tar bort
tillhörande historiktabell (_h), QA-triggerfunktion (trg_fn_*_qa) samt eventuell
afvaktande geometripost i hex_afvaktande_geometri (uppstår vid FME-tvåstegsmönster
om tabellen droppas innan geometrikolumnen hunnit läggas till). Vid DROP SCHEMA
rensas även alla rader för schemat i hex_metadata, hex_afvaktande_geometri,
hex_avvikande_srid och hex_dummy_geometrier. Hoppar över under
tabellomstrukturering (hex_byt_ut_tabell) och förhindrar rekursion vid borttagning
av historiktabeller.';
