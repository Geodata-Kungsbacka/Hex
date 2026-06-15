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

ALTER TYPE public.hex_tabellregler
    OWNER TO postgres;