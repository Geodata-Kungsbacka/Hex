-- Type: kolumnkonfig

DO $$
BEGIN
    CREATE TYPE public.kolumnkonfig AS
    (
        kolumnnamn text,
        ordinal_position integer,
        datatyp text
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;  -- typen finns redan, inget att göra
END;
$$;

ALTER TYPE public.kolumnkonfig
    OWNER TO postgres;
