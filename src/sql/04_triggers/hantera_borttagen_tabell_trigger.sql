-- Event Trigger: hantera_borttagen_tabell_trigger on database

-- DROP EVENT TRIGGER IF EXISTS hantera_borttagen_tabell_trigger;

CREATE EVENT TRIGGER hantera_borttagen_tabell_trigger ON SQL_DROP
    WHEN TAG IN ('DROP TABLE')
    EXECUTE PROCEDURE public.hantera_borttagen_tabell();

ALTER EVENT TRIGGER hantera_borttagen_tabell_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hantera_borttagen_tabell_trigger
    IS 'Tar automatiskt bort historiktabeller och QA-triggerfunktioner när
en tabell tas bort. Hoppar över under tabellomstrukturering.';
