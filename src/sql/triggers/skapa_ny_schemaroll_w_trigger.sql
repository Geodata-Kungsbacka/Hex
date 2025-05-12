-- Event Trigger: skapa_ny_schemaroll_w_trigger on database

CREATE EVENT TRIGGER skapa_ny_schemaroll_w_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.skapa_ny_schemaroll_w();

ALTER EVENT TRIGGER skapa_ny_schemaroll_w_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER skapa_ny_schemaroll_w_trigger
    IS 'Skapar automatiskt en roll med läs- och skrivrättigheter (w_schemanamn) när ett nytt schema skapas.';