-- Event Trigger: ta_bort_schemaroller_trigger on database

CREATE EVENT TRIGGER ta_bort_schemaroller_trigger ON SQL_DROP
    WHEN TAG IN ('DROP SCHEMA')
    EXECUTE PROCEDURE public.ta_bort_schemaroller();

ALTER EVENT TRIGGER ta_bort_schemaroller_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER ta_bort_schemaroller_trigger
    IS 'Tar automatiskt bort roller för scheman när de tas bort.';