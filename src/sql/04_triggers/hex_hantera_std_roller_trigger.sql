-- Fil: src/sql/04_triggers/hex_hantera_std_roller_trigger.sql

-- Event Trigger: hex_hantera_std_roller_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_std_roller_trigger;

CREATE EVENT TRIGGER hex_hantera_std_roller_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.hex_hantera_std_roller();

ALTER EVENT TRIGGER hex_hantera_std_roller_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_hantera_std_roller_trigger
    IS 'Skapar automatiskt roller enligt konfiguration i hex_standardiserade_roller när nya scheman skapas.';