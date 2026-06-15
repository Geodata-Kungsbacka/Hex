-- Fil: src/sql/04_triggers/hex_notifiera_gs_trigger.sql

-- Event Trigger: hex_notifiera_gs_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_trigger;

CREATE EVENT TRIGGER hex_notifiera_gs_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.hex_notifiera_gs();

ALTER EVENT TRIGGER hex_notifiera_gs_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_notifiera_gs_trigger
    IS 'Skickar pg_notify till GeoServer-lyssnaren nar nya sk0/sk1-scheman skapas.
Lyssnaren skapar automatiskt workspace och PostGIS-datastore i GeoServer.';
