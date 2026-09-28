-- Event Trigger: hex_hantera_ny_tabell_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_tabell_trigger;

CREATE EVENT TRIGGER hex_hantera_ny_tabell_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE TABLE')
    EXECUTE PROCEDURE public.hex_hantera_ny_tabell();

ALTER EVENT TRIGGER hex_hantera_ny_tabell_trigger
    OWNER TO postgres;