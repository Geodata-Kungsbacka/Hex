-- Event Trigger: hantera_kolumntillagg_trigger on database

-- DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger;

CREATE EVENT TRIGGER hantera_kolumntillagg_trigger ON DDL_COMMAND_END
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE PROCEDURE public.hantera_kolumntillagg();

ALTER EVENT TRIGGER hantera_kolumntillagg_trigger
    OWNER TO postgres;