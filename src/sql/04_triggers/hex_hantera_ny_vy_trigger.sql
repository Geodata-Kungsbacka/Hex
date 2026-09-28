-- Event Trigger: hex_hantera_ny_vy_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_vy_trigger;

CREATE EVENT TRIGGER hex_hantera_ny_vy_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE VIEW')
    EXECUTE PROCEDURE public.hex_hantera_ny_vy();

ALTER EVENT TRIGGER hex_hantera_ny_vy_trigger
    OWNER TO postgres;