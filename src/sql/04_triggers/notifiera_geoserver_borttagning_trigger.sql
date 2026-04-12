-- Fil: src/sql/04_triggers/notifiera_geoserver_borttagning_trigger.sql

-- Event Trigger: notifiera_geoserver_borttagning_trigger on database

DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_borttagning_trigger;

CREATE EVENT TRIGGER notifiera_geoserver_borttagning_trigger ON SQL_DROP
    WHEN TAG IN ('DROP SCHEMA')
    EXECUTE PROCEDURE public.notifiera_geoserver_borttagning();

ALTER EVENT TRIGGER notifiera_geoserver_borttagning_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER notifiera_geoserver_borttagning_trigger
    IS 'Skickar pg_notify till GeoServer-lyssnaren när sk0/sk1-scheman tas bort.
Lyssnaren tar automatiskt bort workspace och PostGIS-datastore i GeoServer via REST API.';
