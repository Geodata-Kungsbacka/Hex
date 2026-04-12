-- Type: tabellregler

-- DROP TYPE IF EXISTS public.tabellregler;

DO $$
BEGIN
    CREATE TYPE public.tabellregler AS
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

ALTER TYPE public.tabellregler
    OWNER TO postgres;