-- Event Trigger: validera_schemanamn_trigger on database

-- DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger;

CREATE EVENT TRIGGER validera_schemanamn_trigger ON ddl_command_end
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.validera_schemanamn();

ALTER EVENT TRIGGER validera_schemanamn_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER validera_schemanamn_trigger
    IS 'Validerar schemanamn mot Praxis namngivningskonvention innan roller skapas.
Blockerar scheman som inte matchar sk[0-2]_(ext|kba|sys)_*.';
