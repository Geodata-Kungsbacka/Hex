-- Event Trigger: hex_hantera_ny_kolumn_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_kolumn_trigger;

CREATE EVENT TRIGGER hex_hantera_ny_kolumn_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE PROCEDURE public.hex_hantera_ny_kolumn();

ALTER EVENT TRIGGER hex_hantera_ny_kolumn_trigger
    OWNER TO postgres;