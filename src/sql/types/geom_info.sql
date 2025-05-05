-- Type: geom_info

-- DROP TYPE IF EXISTS public.geom_info;

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

ALTER TYPE public.geom_info
    OWNER TO postgres;