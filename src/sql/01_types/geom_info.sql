-- Type: geom_info

DO $$
BEGIN
    CREATE TYPE public.geom_info AS
    (
        kolumnnamn text,
        typ_ursprunglig text,
        typ_basal text,
        dimensioner integer,
        srid integer,
        suffix text,
        typ_komplett text,
        definition text
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;  -- typen finns redan, inget att göra
END;
$$;

ALTER TYPE public.geom_info
    OWNER TO postgres;
