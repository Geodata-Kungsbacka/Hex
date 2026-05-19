-- Event Trigger: blockera_schema_namnbyte_trigger on database

DROP EVENT TRIGGER IF EXISTS blockera_schema_namnbyte_trigger;

CREATE EVENT TRIGGER blockera_schema_namnbyte_trigger ON ddl_command_end
    WHEN TAG IN ('ALTER SCHEMA')
    EXECUTE PROCEDURE public.blockera_schema_namnbyte();

ALTER EVENT TRIGGER blockera_schema_namnbyte_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER blockera_schema_namnbyte_trigger
    IS 'Blockerar ALTER SCHEMA ... RENAME TO.
Schemanamnet är identitetsnyckeln för GeoServer-workspace, databasroller
och hex_metadata – ett namnbyte river sönder alla dessa kopplingar utan
möjlighet till automatisk återställning. Rätt tillvägagångssätt är
DROP SCHEMA CASCADE följt av CREATE SCHEMA med det nya namnet.';
