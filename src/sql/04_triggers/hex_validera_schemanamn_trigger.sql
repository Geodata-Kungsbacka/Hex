-- Event Trigger: hex_validera_schemanamn_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_validera_schemanamn_trigger;

CREATE EVENT TRIGGER hex_validera_schemanamn_trigger ON ddl_command_end
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE public.hex_validera_schemanamn();

ALTER EVENT TRIGGER hex_validera_schemanamn_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_validera_schemanamn_trigger
    IS 'Validerar schemanamn mot Hex namngivningskonvention. Körs sist av Hex tre
CREATE SCHEMA-triggers (alfabetisk körordning: hex_hantera_std_roller_trigger,
hex_notifiera_gs_trigger, hex_validera_schemanamn_trigger) — ett ogiltigt namn
rullar därför tillbaka redan skapade roller och köad GeoServer-notifiering
tillsammans med schemat. Blockerar scheman som inte matchar mönstret byggt
dynamiskt från hex_standardiserade_skyddsnivaer och hex_standardiserade_datakategorier.';
