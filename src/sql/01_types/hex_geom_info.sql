-- Type: hex_geom_info

-- DROP TYPE IF EXISTS public.hex_geom_info;

DO $$
BEGIN
    CREATE TYPE public.hex_geom_info AS
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
    WHEN duplicate_object THEN NULL;
END;
$$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TYPE public.hex_geom_info OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;
