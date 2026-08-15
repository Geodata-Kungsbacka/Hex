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

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TYPE public.hex_kolumnegenskaper OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON TYPE public.hex_kolumnegenskaper
    IS 'Kolumnspecifika egenskaper inkl. DEFAULT, NOT NULL, CHECK och IDENTITY.
Används i kombination med hex_tabellregler för att separera kolumn- och 
tabellegenskaper i struktureringssystemet.';