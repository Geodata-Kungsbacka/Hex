CREATE OR REPLACE FUNCTION public.notifiera_geoserver_borttagning()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren
 * när scheman tas bort med en skyddsnivå där publiceras_geoserver = true.
 *
 * Speglar notifiera_geoserver() men för DROP SCHEMA. Python-lyssnaren tar
 * emot notifieringen och tar bort workspace och datastore i GeoServer via
 * REST API, vilket förhindrar att GeoServer gör upprepade anrop mot ett
 * schema som inte längre existerar.
 *
 * FUNKTIONALITET:
 * 1. Identifierar borttagna scheman från DDL-händelsen
 * 2. Filtrerar bort systemscheman och scheman vars skyddsnivå inte publicerats
 * 3. Skickar pg_notify med schemanamnet som payload
 *
 * KANAL: 'geoserver_schema_drop'
 *
 * PAYLOAD-FORMAT: schemanamnet direkt, t.ex. 'sk0_kba_test'
 *
 * Python-lyssnaren tar emot notifieringen och tar bort:
 *   - Workspace i GeoServer med samma namn som schemat (inkl. datastore/lager)
 *
 * TRIGGER: Körs automatiskt vid DROP SCHEMA (SQL_DROP-händelsen)
 ******************************************************************************/
DECLARE
    kommando         record;
    schema_namn      text;
    schema_prefix    text;
    antal_notifieringar integer := 0;
BEGIN
    RAISE NOTICE E'[notifiera_geoserver_borttagning] === START ===';
    RAISE NOTICE '[notifiera_geoserver_borttagning] Kontrollerar om borttaget schema ska avpubliceras från GeoServer';

    FOR kommando IN SELECT * FROM pg_event_trigger_dropped_objects()
    WHERE object_type = 'schema'
    LOOP
        schema_namn := kommando.object_name;

        RAISE NOTICE '[notifiera_geoserver_borttagning] Bearbetar borttaget schema: %', schema_namn;

        -- Hoppa över systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[notifiera_geoserver_borttagning]   Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;

        -- Kontrollera om skyddsnivån för detta schema publicerats till GeoServer.
        -- Schemat är redan borttaget så vi kan inte fråga det direkt – vi identifierar
        -- det via namnprefixet mot standardiserade_skyddsnivaer.
        SELECT prefix INTO schema_prefix
        FROM public.standardiserade_skyddsnivaer
        WHERE publiceras_geoserver = true
          AND schema_namn LIKE prefix || '_%';

        IF schema_prefix IS NULL THEN
            RAISE NOTICE '[notifiera_geoserver_borttagning]   Schema "%" har ingen GeoServer-publicerad skyddsnivå - hoppar över', schema_namn;
            CONTINUE;
        END IF;

        -- Skicka borttagningsnotifiering till Python-lyssnaren
        RAISE NOTICE '[notifiera_geoserver_borttagning]   Skickar borttagningsnotifiering för schema: % (prefix: %)',
            schema_namn, schema_prefix;
        PERFORM pg_notify('geoserver_schema_drop', schema_namn);
        antal_notifieringar := antal_notifieringar + 1;

        RAISE NOTICE '[notifiera_geoserver_borttagning]   Notifiering skickad till kanal "geoserver_schema_drop"';
    END LOOP;

    RAISE NOTICE '[notifiera_geoserver_borttagning] Sammanfattning:';
    RAISE NOTICE '[notifiera_geoserver_borttagning]   Notifieringar skickade: %', antal_notifieringar;
    RAISE NOTICE '[notifiera_geoserver_borttagning] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[notifiera_geoserver_borttagning] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[notifiera_geoserver_borttagning]   Schema: %', COALESCE(schema_namn, 'okänt');
        RAISE NOTICE '[notifiera_geoserver_borttagning]   Felkod: %', SQLSTATE;
        RAISE NOTICE '[notifiera_geoserver_borttagning]   Felmeddelande: %', SQLERRM;
        -- Notifieringen är inte kritisk – låt inte felet påverka borttagningen av schemat
        RAISE WARNING '[notifiera_geoserver_borttagning] GeoServer-borttagningsnotifiering misslyckades, men schemat togs bort korrekt: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION public.notifiera_geoserver_borttagning()
    OWNER TO postgres;

COMMENT ON FUNCTION public.notifiera_geoserver_borttagning()
    IS 'Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren vid DROP SCHEMA.
Skickar notifiering på kanalen geoserver_schema_drop för scheman vars skyddsnivå har
publiceras_geoserver = true (standardkonfiguration: sk0 och sk1). Notifieringen används av
en extern Python-process för att ta bort workspace och datastore i GeoServer via REST API,
vilket förhindrar att GeoServer gör upprepade anrop mot ett schema som inte längre existerar.';
