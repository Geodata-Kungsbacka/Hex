-- Type: hex_kolumnkonfig

-- DROP TYPE IF EXISTS public.hex_kolumnkonfig;

DO $$
BEGIN
    CREATE TYPE public.hex_kolumnkonfig AS
    (
        kolumnnamn text,
        ordinal_position integer,
        datatyp text
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END;
$$;

ALTER TYPE public.hex_kolumnkonfig
    OWNER TO postgres;