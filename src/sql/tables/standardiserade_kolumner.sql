-- Table: public.standardiserade_kolumner

-- DROP TABLE IF EXISTS public.standardiserade_kolumner;

CREATE TABLE IF NOT EXISTS public.standardiserade_kolumner
(
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 2147483647 CACHE 1 ),
    kolumnnamn text COLLATE pg_catalog."default" NOT NULL,
    ordinal_position integer NOT NULL,
    datatyp text COLLATE pg_catalog."default" NOT NULL,
    schema_uttryck text COLLATE pg_catalog."default" DEFAULT 'LIKE ''%'''::text,
    beskrivning text COLLATE pg_catalog."default",
    CONSTRAINT standardiserade_kolumner_kolumnnamn_key UNIQUE (kolumnnamn),
    CONSTRAINT valid_kolumnnamn_length CHECK (length(kolumnnamn) <= 63),
    CONSTRAINT valid_ordinal_position CHECK (ordinal_position <> 0)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.standardiserade_kolumner
    OWNER to gis_admin;

COMMENT ON TABLE public.standardiserade_kolumner
    IS 'Definierar standardkolumner för tabellstrukturer.
- "ordinal_position": 
> 0: kolumnen placeras först i angiven ordning
< 0: kolumnen placeras sist i omvänd ordning
NULL/0 är inte tillåtet
- "schema_uttryck":
SQL-uttryck för att matcha scheman där kolumnen ska appliceras, 
    t.ex. "= ''''sk0_kba_bm''''" för exakt matchning eller 
    "LIKE ''''%_ext_%''''" för mönstermatchning';

INSERT INTO public.standardiserade_kolumner(
	kolumnnamn, ordinal_position, datatyp, schema_uttryck, beskrivning)
	VALUES ('gid', 1, 'integer GENERATED ALWAYS AS IDENTITY', 'LIKE ''%''', 'Primärnyckel'),
	('skapad_tidpunkt', -1, 'timestamptz DEFAULT NOW()', 'LIKE ''%''', 'Tidpunkt för radens skapande');