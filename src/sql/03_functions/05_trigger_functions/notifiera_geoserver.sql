CREATE OR REPLACE FUNCTION public.notifiera_geoserver()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren
 * när nya scheman skapas med prefix sk0 eller sk1.
 *
 * FUNKTIONALITET:
 * 1. Identifierar nya scheman från DDL-händelsen
 * 2. Filtrerar bort systemscheman och sk2-scheman
 * 3. Skickar pg_notify med schemanamnet som payload
 *
 * KANAL: 'geoserver_schema'
 *
 * PAYLOAD-FORMAT: schemanamnet direkt, t.ex. 'sk0_kba_test'
 *
 * Python-lyssnaren tar emot notifieringen och skapar:
 *   - Workspace i GeoServer med samma namn som schemat
 *   - JNDI-datastore i workspace med samma namn som schemat
 *
 * TRIGGER: Kors automatiskt vid CREATE SCHEMA (efter validering och roller)
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    schema_prefix text;
    antal_notifieringar integer := 0;
BEGIN
    RAISE NOTICE E'[notifiera_geoserver] === START ===';
    RAISE NOTICE '[notifiera_geoserver] Kontrollerar om nytt schema ska publiceras till GeoServer';

    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

        RAISE NOTICE '[notifiera_geoserver] Bearbetar schema: %', schema_namn;

        -- Hoppa over systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[notifiera_geoserver]   Hoppar over systemschema: %', schema_namn;
            CONTINUE;
        END IF;

        -- Extrahera prefix (sk0 eller sk1)
        schema_prefix := substring(schema_namn from '^(sk[01])_');

        IF schema_prefix IS NULL THEN
            RAISE NOTICE '[notifiera_geoserver]   Schema "%" har inte prefix sk0/sk1 - hoppar over', schema_namn;
            CONTINUE;
        END IF;

        -- Skicka notifiering till Python-lyssnaren
        RAISE NOTICE '[notifiera_geoserver]   Skickar notifiering for schema: % (prefix: %)', schema_namn, schema_prefix;
        PERFORM pg_notify('geoserver_schema', schema_namn);
        antal_notifieringar := antal_notifieringar + 1;

        RAISE NOTICE '[notifiera_geoserver]   Notifiering skickad till kanal "geoserver_schema"';
    END LOOP;

    RAISE NOTICE '[notifiera_geoserver] Sammanfattning:';
    RAISE NOTICE '[notifiera_geoserver]   Notifieringar skickade: %', antal_notifieringar;
    RAISE NOTICE '[notifiera_geoserver] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[notifiera_geoserver] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[notifiera_geoserver]   Schema: %', COALESCE(schema_namn, 'okant');
        RAISE NOTICE '[notifiera_geoserver]   Felkod: %', SQLSTATE;
        RAISE NOTICE '[notifiera_geoserver]   Felmeddelande: %', SQLERRM;
        -- Notifiering ar inte kritisk - lat inte felet stoppa schema-skapandet
        RAISE WARNING '[notifiera_geoserver] GeoServer-notifiering misslyckades, men schemat skapades korrekt: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION public.notifiera_geoserver()
    OWNER TO postgres;

COMMENT ON FUNCTION public.notifiera_geoserver()
    IS 'Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren vid CREATE SCHEMA.
Filtrerar till enbart sk0 och sk1 scheman. Notifieringen anvands av en extern Python-process
for att skapa workspace och datastore i GeoServer via REST API.';
