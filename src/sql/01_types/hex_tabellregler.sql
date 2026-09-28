-- Type: hex_tabellregler

-- DROP TYPE IF EXISTS public.hex_tabellregler;

DO $$
BEGIN
    CREATE TYPE public.hex_tabellregler AS
    (
        index_defs text[],
        fk_defs text[],
        constraint_defs text[],
        default_defs text[],
        generated_defs text[]
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
        'ALTER TYPE public.hex_tabellregler OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;
