-- Event Trigger: hantera_ny_vy_trigger on database

-- DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger;

CREATE EVENT TRIGGER hantera_ny_vy_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE VIEW')
    EXECUTE PROCEDURE public.hantera_ny_vy();

ALTER EVENT TRIGGER hantera_ny_vy_trigger
    OWNER TO postgres;