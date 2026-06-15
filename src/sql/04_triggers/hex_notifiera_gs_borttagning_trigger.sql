-- Fil: src/sql/04_triggers/hex_notifiera_gs_borttagning_trigger.sql

-- Event Trigger: hex_notifiera_gs_borttagning_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_borttagning_trigger;

CREATE EVENT TRIGGER hex_notifiera_gs_borttagning_trigger ON SQL_DROP
    WHEN TAG IN ('DROP SCHEMA')
    EXECUTE PROCEDURE public.hex_notifiera_gs_borttagning();

ALTER EVENT TRIGGER hex_notifiera_gs_borttagning_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_notifiera_gs_borttagning_trigger
    IS 'Skickar pg_notify till GeoServer-lyssnaren när sk0/sk1-scheman tas bort.
Lyssnaren tar automatiskt bort workspace och PostGIS-datastore i GeoServer via REST API.';
