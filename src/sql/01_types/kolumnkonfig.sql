-- Type: kolumnkonfig

-- DROP TYPE IF EXISTS public.kolumnkonfig;

CREATE TYPE public.kolumnkonfig AS
(
	kolumnnamn text,
	ordinal_position integer,
	datatyp text
);

ALTER TYPE public.kolumnkonfig
    OWNER TO postgres;