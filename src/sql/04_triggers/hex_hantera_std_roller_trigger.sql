-- Fil: src/sql/04_triggers/hex_hantera_std_roller_trigger.sql

-- Event Trigger: hex_hantera_std_roller_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_std_roller_trigger;

CREATE EVENT TRIGGER hex_hantera_std_roller_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.hex_hantera_std_roller();

ALTER EVENT TRIGGER hex_hantera_std_roller_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_hantera_std_roller_trigger
    IS 'Skapar automatiskt roller enligt konfiguration i hex_standardiserade_roller när nya scheman skapas.
Körs först av Hex tre CREATE SCHEMA-triggers (alfabetisk körordning: hex_hantera_std_roller_trigger,
hex_notifiera_gs_trigger, hex_validera_schemanamn_trigger) — alltså före både GeoServer-notifiering
och namnvalidering. Rullas tillbaka tillsammans med schemat om namnvalideringen senare misslyckas.';