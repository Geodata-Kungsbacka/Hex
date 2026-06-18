-- Table: public.hex_standardiserade_kolumner

-- DROP TABLE IF EXISTS public.hex_standardiserade_kolumner;

CREATE TABLE IF NOT EXISTS public.hex_standardiserade_kolumner
(
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 2147483647 CACHE 1 ),
    kolumnnamn text COLLATE pg_catalog."default" NOT NULL,
    ordinal_position integer NOT NULL,
    datatyp text COLLATE pg_catalog."default" NOT NULL,
    default_varde text,   
    schema_uttryck text COLLATE pg_catalog."default" NOT NULL DEFAULT 'IS NOT NULL',
    historik_qa boolean DEFAULT false,
    anvandare_kan_redigera boolean DEFAULT true,
    beskrivning text COLLATE pg_catalog."default",
    
    CONSTRAINT hex_standardiserade_kolumner_kolumnnamn_key UNIQUE (kolumnnamn),
    CONSTRAINT valid_kolumnnamn_length CHECK (length(kolumnnamn) <= 63),
    CONSTRAINT valid_ordinal_position CHECK (ordinal_position <> 0),
    CONSTRAINT valid_schema_uttryck CHECK (
        schema_uttryck NOT LIKE '%;%' AND
        length(schema_uttryck) < 200 AND
        schema_uttryck ~* '^(=|<>|!=|<|<=|>|>=|LIKE|NOT|IN|IS)\s'
    )
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.hex_standardiserade_kolumner
    OWNER to postgres;

COMMENT ON TABLE public.hex_standardiserade_kolumner
    IS E'Definierar standardkolumner för tabellstrukturer.\\n\\nordinal_position:\\n  > 0: kolumnen placeras först i angiven ordning\\n  < 0: kolumnen placeras sist i omvänd ordning\\n  NULL/0 är inte tillåtet\\n\\nschema_uttryck:\\n  SQL-uttryck som avgör vilka scheman kolumnen ska appliceras på.\\n  Exempel: "LIKE ''%_ext_%''", "= ''sk0_ext_sgu''", "IS NOT NULL"';

COMMENT ON COLUMN public.hex_standardiserade_kolumner.schema_uttryck
    IS 'SQL-uttryck som avgör vilka scheman kolumnen ska appliceras på. Värdet sätts in efter "WHERE p_schema_namn [detta_värde]". Exempel: "= ''sk0_ext_sgu''", "LIKE ''%_ext_%''", "IN (''sk0_ext_sgu'', ''sk1_ext_region'')"';

-- Lägg till grundläggande standardkolumner
-- ÄNDRING: Använder session_user istället för current_user för att fånga faktisk autentiserad användare
INSERT INTO public.hex_standardiserade_kolumner(
    kolumnnamn, ordinal_position, datatyp, default_varde, beskrivning, schema_uttryck, historik_qa, anvandare_kan_redigera)
VALUES
    ('gid',              1, 'integer GENERATED ALWAYS AS IDENTITY', NULL,           'Primärnyckel',                  'IS NOT NULL',       false, false),
    ('skapad_tidpunkt', -4, 'timestamptz',                          'NOW()',         'Tidpunkt då raden skapades',    'IS NOT NULL',       false, false),
    ('skapad_av',       -3, 'character varying',                    'session_user',  'Användare som skapade raden',   'LIKE ''%_kba_%''',  false, false),
    ('andrad_tidpunkt', -2, 'timestamptz',                          'NOW()',         'Senaste ändringstidpunkt',      'LIKE ''%_kba_%''',  true,  false),
    ('andrad_av',       -1, 'character varying',                    'session_user',  'Användare som senast ändrade',  'LIKE ''%_kba_%''',  true,  false)
ON CONFLICT (kolumnnamn) DO UPDATE SET
    anvandare_kan_redigera = EXCLUDED.anvandare_kan_redigera;

-- Migrering: lägg till anvandare_kan_redigera om kolumnen saknas (idempotent).
ALTER TABLE IF EXISTS public.hex_standardiserade_kolumner
    ADD COLUMN IF NOT EXISTS anvandare_kan_redigera boolean DEFAULT true;

-- Any database user who creates tables needs to read these configuration tables,
-- since the trigger functions (hex_hantera_ny_tabell, hex_hantera_ny_kolumn) run
-- as SECURITY INVOKER (the calling user's privileges).
GRANT SELECT ON public.hex_standardiserade_kolumner TO PUBLIC;
