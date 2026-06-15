CREATE OR REPLACE FUNCTION public.hex_notifiera_gs()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren
 * när nya scheman skapas med en skyddsnivå där publiceras_geoserver = true.
 *
 * Vilka skyddsnivåer som publiceras styrs av tabellen hex_standardiserade_skyddsnivaer.
 * Standardkonfiguration: sk0 och sk1 publiceras, sk2 och skx publiceras inte.
 *
 * FUNKTIONALITET:
 * 1. Identifierar nya scheman från DDL-händelsen
 * 2. Filtrerar bort systemscheman och scheman vars skyddsnivå inte publiceras
 * 3. Skickar pg_notify med schemanamnet som payload
 *
 * KANAL: 'geoserver_schema'
 *
 * PAYLOAD-FORMAT: schemanamnet direkt, t.ex. 'sk0_kba_test'
 *
 * Python-lyssnaren tar emot notifieringen och skapar:
 *   - Workspace i GeoServer med samma namn som schemat
 *   - Direkt PostGIS-datastore i workspace med autentiseringsuppgifter
 *     från tabellen hex_role_credentials (läsrollen r_{schema})
 *
 * TRIGGER: Kors automatiskt vid CREATE SCHEMA (efter validering och roller)
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    schema_prefix text;
    antal_notifieringar integer := 0;
BEGIN
    RAISE NOTICE E'[hex_notifiera_gs] === START ===';
    RAISE NOTICE '[hex_notifiera_gs] Kontrollerar om nytt schema ska publiceras till GeoServer';

    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

        RAISE NOTICE '[hex_notifiera_gs] Bearbetar schema: %', schema_namn;

        -- Hoppa over systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[hex_notifiera_gs]   Hoppar over systemschema: %', schema_namn;
            CONTINUE;
        END IF;

        -- Kontrollera om skyddsnivån för detta schema ska publiceras till GeoServer
        SELECT prefix INTO schema_prefix
        FROM public.hex_standardiserade_skyddsnivaer
        WHERE publiceras_geoserver = true
          AND schema_namn LIKE prefix || '_%';

        IF schema_prefix IS NULL THEN
            RAISE NOTICE '[hex_notifiera_gs]   Schema "%" har ingen GeoServer-publicerad skyddsnivå - hoppar over', schema_namn;
            CONTINUE;
        END IF;

        -- Skicka notifiering till Python-lyssnaren
        RAISE NOTICE '[hex_notifiera_gs]   Skickar notifiering for schema: % (prefix: %)', schema_namn, schema_prefix;
        PERFORM pg_notify('geoserver_schema', schema_namn);
        antal_notifieringar := antal_notifieringar + 1;

        RAISE NOTICE '[hex_notifiera_gs]   Notifiering skickad till kanal "geoserver_schema"';
    END LOOP;

    RAISE NOTICE '[hex_notifiera_gs] Sammanfattning:';
    RAISE NOTICE '[hex_notifiera_gs]   Notifieringar skickade: %', antal_notifieringar;
    RAISE NOTICE '[hex_notifiera_gs] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hex_notifiera_gs] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_notifiera_gs]   Schema: %', COALESCE(schema_namn, 'okant');
        RAISE NOTICE '[hex_notifiera_gs]   Felkod: %', SQLSTATE;
        RAISE NOTICE '[hex_notifiera_gs]   Felmeddelande: %', SQLERRM;
        -- Notifiering ar inte kritisk - lat inte felet stoppa schema-skapandet
        RAISE WARNING '[hex_notifiera_gs] GeoServer-notifiering misslyckades, men schemat skapades korrekt: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION public.hex_notifiera_gs()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_notifiera_gs()
    IS 'Event trigger-funktion som skickar pg_notify till GeoServer-lyssnaren vid CREATE SCHEMA.
Publicerar scheman vars skyddsnivå har publiceras_geoserver = true i hex_standardiserade_skyddsnivaer
(standardkonfiguration: sk0 och sk1). Notifieringen används av en extern Python-process
för att skapa workspace och direkt PostGIS-datastore i GeoServer via REST API.
Datastore-autentiseringen hämtas från hex_role_credentials (läsrollen r_{schema}).';
