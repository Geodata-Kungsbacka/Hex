-- Event Trigger: hex_hantera_borttagen_tabell_trigger on database

DROP EVENT TRIGGER IF EXISTS hex_hantera_borttagen_tabell_trigger;

CREATE EVENT TRIGGER hex_hantera_borttagen_tabell_trigger ON SQL_DROP
    WHEN TAG IN ('DROP TABLE', 'DROP SCHEMA')
    EXECUTE PROCEDURE public.hex_hantera_borttagen_tabell();

ALTER EVENT TRIGGER hex_hantera_borttagen_tabell_trigger
    OWNER TO postgres;

COMMENT ON EVENT TRIGGER hex_hantera_borttagen_tabell_trigger
    IS 'Tar automatiskt bort historiktabeller och QA-triggerfunktioner när
en tabell tas bort, även när tabellen försvinner via DROP SCHEMA ... CASCADE.
Hoppar över under tabellomstrukturering.';
