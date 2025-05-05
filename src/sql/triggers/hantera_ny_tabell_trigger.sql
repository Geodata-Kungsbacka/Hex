-- Event Trigger: hantera_ny_tabell_trigger on database

-- DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger;

CREATE EVENT TRIGGER hantera_ny_tabell_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE TABLE')
    EXECUTE PROCEDURE public.hantera_ny_tabell();

ALTER EVENT TRIGGER hantera_ny_tabell_trigger
    OWNER TO postgres;