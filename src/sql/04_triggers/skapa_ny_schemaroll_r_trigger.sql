-- Event Trigger: skapa_ny_schemaroll_r_trigger on database

CREATE EVENT TRIGGER skapa_ny_schemaroll_r_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.skapa_ny_schemaroll_r();

ALTER EVENT TRIGGER skapa_ny_schemaroll_r_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER skapa_ny_schemaroll_r_trigger
    IS 'Skapar automatiskt en roll med läsrättigheter (r_schemanamn) när ett nytt schema skapas.';