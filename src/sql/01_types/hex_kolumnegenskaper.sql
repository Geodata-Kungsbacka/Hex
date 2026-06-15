-- Type: hex_kolumnegenskaper

-- DROP TYPE IF EXISTS public.hex_kolumnegenskaper;

DO $$
BEGIN
    CREATE TYPE public.hex_kolumnegenskaper AS
    (
        default_defs text[],
        notnull_defs text[],
        check_defs text[],
        identity_defs text[]
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END;
$$;

ALTER TYPE public.hex_kolumnegenskaper
    OWNER TO postgres;

COMMENT ON TYPE public.hex_kolumnegenskaper
    IS 'Kolumnspecifika egenskaper inkl. DEFAULT, NOT NULL, CHECK och IDENTITY.
Används i kombination med hex_tabellregler för att separera kolumn- och 
tabellegenskaper i struktureringssystemet.';