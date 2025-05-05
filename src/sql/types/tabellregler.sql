-- Type: tabellregler

-- DROP TYPE IF EXISTS public.tabellregler;

CREATE TYPE public.tabellregler AS
(
	index_defs text[],
	fk_defs text[],
	constraint_defs text[],
	default_defs text[],
	generated_defs text[]
);

ALTER TYPE public.tabellregler
    OWNER TO postgres;