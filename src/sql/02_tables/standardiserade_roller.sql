CREATE TABLE IF NOT EXISTS public.standardiserade_roller (
    gid             integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    rollnamn        text    NOT NULL,
    rolltyp         text    NOT NULL CHECK (rolltyp IN ('read', 'write')),
    schema_uttryck  text    NOT NULL DEFAULT 'IS NOT NULL',
    ta_bort_med_schema boolean DEFAULT true,
    with_login      boolean DEFAULT false,
    beskrivning     text,

    CONSTRAINT standardiserade_roller_pkey PRIMARY KEY (gid)
);

ALTER TABLE public.standardiserade_roller
    OWNER TO postgres;

COMMENT ON TABLE public.standardiserade_roller
    IS 'Definierar vilka roller som ska skapas automatiskt för nya scheman.
    Stöder både schemaspecifika och globala roller.';

COMMENT ON COLUMN public.standardiserade_roller.with_login
    IS 'Om true skapas rollen med LOGIN och ett autogenererat lösenord (via pgcrypto).
    Lösenordet sparas i hex_role_credentials för GeoServer-lyssnaren.
    Om false skapas rollen som NOLOGIN (ren behörighetsgrupp).';

-- Schemaspecifika roller - skapas per schema, tas bort med schemat
INSERT INTO standardiserade_roller (rollnamn, rolltyp, schema_uttryck, with_login, beskrivning) VALUES
    ('r_{schema}', 'read',  'IS NOT NULL', true, 'Schemaspecifik läsroll'),
    ('w_{schema}', 'write', 'IS NOT NULL', true, 'Schemaspecifik skrivroll');

-- Any database user who creates tables needs to read these configuration tables,
-- since the trigger functions (hantera_ny_tabell, hantera_kolumntillagg) run
-- as SECURITY INVOKER (the calling user's privileges).
GRANT SELECT ON public.standardiserade_roller TO PUBLIC;
