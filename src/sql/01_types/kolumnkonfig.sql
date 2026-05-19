-- Type: kolumnkonfig

-- DROP TYPE IF EXISTS public.kolumnkonfig;

DO $$
BEGIN
    CREATE TYPE public.kolumnkonfig AS
    (
        kolumnnamn text,
        ordinal_position integer,
        datatyp text
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END;
$$;

ALTER TYPE public.kolumnkonfig
    OWNER TO postgres;