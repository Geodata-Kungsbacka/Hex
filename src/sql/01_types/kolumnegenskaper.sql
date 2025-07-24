-- Type: kolumnegenskaper

-- DROP TYPE IF EXISTS public.kolumnegenskaper;

CREATE TYPE public.kolumnegenskaper AS
(
	default_defs text[],
	notnull_defs text[],
	check_defs text[],
	identity_defs text[]
);

ALTER TYPE public.kolumnegenskaper
    OWNER TO postgres;

COMMENT ON TYPE public.kolumnegenskaper
    IS 'Kolumnspecifika egenskaper inkl. DEFAULT, NOT NULL, CHECK och IDENTITY.
Används i kombination med tabellregler för att separera kolumn- och 
tabellegenskaper i struktureringssystemet.';