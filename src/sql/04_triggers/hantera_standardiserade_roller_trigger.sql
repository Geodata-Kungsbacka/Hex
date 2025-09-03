-- Fil: src/sql/04_triggers/hantera_standardiserade_roller_trigger.sql

-- Event Trigger: hantera_standardiserade_roller_trigger on database

-- DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger;

CREATE EVENT TRIGGER hantera_standardiserade_roller_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.hantera_standardiserade_roller();

ALTER EVENT TRIGGER hantera_standardiserade_roller_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hantera_standardiserade_roller_trigger
    IS 'Skapar automatiskt roller enligt konfiguration i standardiserade_roller när nya scheman skapas.';