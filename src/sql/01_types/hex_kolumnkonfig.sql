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

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TYPE public.hex_kolumnkonfig OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;
