-- Fil: src/sql/04_triggers/notifiera_geoserver_trigger.sql

-- Event Trigger: notifiera_geoserver_trigger on database

-- DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_trigger;

CREATE EVENT TRIGGER notifiera_geoserver_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.notifiera_geoserver();

ALTER EVENT TRIGGER notifiera_geoserver_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER notifiera_geoserver_trigger
    IS 'Skickar pg_notify till GeoServer-lyssnaren nar nya sk0/sk1-scheman skapas.
Lyssnaren skapar automatiskt workspace och JNDI-datastore i GeoServer.';
