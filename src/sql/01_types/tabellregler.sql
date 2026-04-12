-- Type: tabellregler

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
    WHEN duplicate_object THEN NULL;  -- typen finns redan, inget att göra
END;
$$;

ALTER TYPE public.tabellregler
    OWNER TO postgres;
