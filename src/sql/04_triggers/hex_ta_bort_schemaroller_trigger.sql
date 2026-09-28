-- Event Trigger: hex_ta_bort_schemaroller_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_ta_bort_schemaroller_trigger;

CREATE EVENT TRIGGER hex_ta_bort_schemaroller_trigger ON SQL_DROP
    WHEN TAG IN ('DROP SCHEMA')
    EXECUTE PROCEDURE public.hex_ta_bort_schemaroller();

ALTER EVENT TRIGGER hex_ta_bort_schemaroller_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_ta_bort_schemaroller_trigger
    IS 'Tar automatiskt bort roller för scheman när de tas bort.';