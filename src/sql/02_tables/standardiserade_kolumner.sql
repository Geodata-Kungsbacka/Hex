-- Table: public.standardiserade_kolumner

-- DROP TABLE IF EXISTS public.standardiserade_kolumner;

CREATE TABLE IF NOT EXISTS public.standardiserade_kolumner
(
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 2147483647 CACHE 1 ),
    kolumnnamn text COLLATE pg_catalog."default" NOT NULL,
    ordinal_position integer NOT NULL,
    datatyp text COLLATE pg_catalog."default" NOT NULL,
    default_varde text,   
    schema_uttryck text COLLATE pg_catalog."default" NOT NULL DEFAULT 'IS NOT NULL',
    historik_qa boolean DEFAULT false,
    beskrivning text COLLATE pg_catalog."default",
    
    CONSTRAINT standardiserade_kolumner_kolumnnamn_key UNIQUE (kolumnnamn),
    CONSTRAINT valid_kolumnnamn_length CHECK (length(kolumnnamn) <= 63),
    CONSTRAINT valid_ordinal_position CHECK (ordinal_position <> 0),
    CONSTRAINT valid_schema_uttryck CHECK (
        schema_uttryck NOT LIKE '%;%' AND
        length(schema_uttryck) < 200 AND
        schema_uttryck ~* '^(=|<>|!=|<|<=|>|>=|LIKE|NOT|IN|IS)\s'
    )
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.standardiserade_kolumner
    OWNER to postgres;

COMMENT ON TABLE public.standardiserade_kolumner
    IS E'Definierar standardkolumner för tabellstrukturer.\\n\\nordinal_position:\\n  > 0: kolumnen placeras först i angiven ordning\\n  < 0: kolumnen placeras sist i omvänd ordning\\n  NULL/0 är inte tillåtet\\n\\nschema_uttryck:\\n  SQL-uttryck som avgör vilka scheman kolumnen ska appliceras på.\\n  Exempel: "LIKE ''%_ext_%''", "= ''sk0_ext_sgu''", "IS NOT NULL"';

COMMENT ON COLUMN public.standardiserade_kolumner.schema_uttryck
    IS 'SQL-uttryck som avgör vilka scheman kolumnen ska appliceras på. Värdet sätts in efter "WHERE p_schema_namn [detta_värde]". Exempel: "= ''sk0_ext_sgu''", "LIKE ''%_ext_%''", "IN (''sk0_ext_sgu'', ''sk1_ext_region'')"';

-- Lägg till grundläggande standardkolumner
INSERT INTO public.standardiserade_kolumner(
    kolumnnamn, ordinal_position, datatyp, default_varde, beskrivning, schema_uttryck, historik_qa)
VALUES 
    ('gid', 1, 'integer GENERATED ALWAYS AS IDENTITY', NULL, 'Primärnyckel', 'IS NOT NULL', false),
	('skapad_tidpunkt', -4, 'timestamptz', 'NOW()', 'Tidpunkt då raden skapades', 'IS NOT NULL', false),
	('skapad_av', -3, 'character varying', 'current_user', 'Användare som skapade raden', 'LIKE ''%_kba_%''', false),
	('andrad_tidpunkt', -2, 'timestamptz', 'NOW()', 'Senaste ändringstidpunkt', 'LIKE ''%_kba_%''', true),
	('andrad_av', -1, 'character varying', 'current_user', 'Användare som senast ändrade', 'LIKE ''%_kba_%''', true);