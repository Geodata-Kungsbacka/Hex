CREATE TABLE IF NOT EXISTS public.hex_standardiserade_roller (
    gid             integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    rollnamn        text    NOT NULL,
    rolltyp         text    NOT NULL CHECK (rolltyp IN ('read', 'write')),
    schema_uttryck  text    NOT NULL DEFAULT 'IS NOT NULL',
    ta_bort_med_schema boolean DEFAULT true,
    with_login      boolean DEFAULT false,
    arvs_fran       text    DEFAULT NULL,
    beskrivning     text,

    CONSTRAINT hex_standardiserade_roller_pkey PRIMARY KEY (gid),
    CONSTRAINT hex_standardiserade_roller_rollnamn_key UNIQUE (rollnamn)
);

-- Backfill the unique constraint on existing installations.
DO $$
BEGIN
    ALTER TABLE public.hex_standardiserade_roller
        ADD CONSTRAINT hex_standardiserade_roller_rollnamn_key UNIQUE (rollnamn);
EXCEPTION
    WHEN duplicate_table THEN NULL;
END;
$$;

-- Backfill the arvs_fran column added in the 4-role refactor.
-- CREATE TABLE IF NOT EXISTS does not alter existing tables, so upgrades need this.
DO $$
BEGIN
    ALTER TABLE public.hex_standardiserade_roller
        ADD COLUMN arvs_fran text DEFAULT NULL;
EXCEPTION
    WHEN duplicate_column THEN NULL;
END;
$$;

ALTER TABLE public.hex_standardiserade_roller
    OWNER TO postgres;

COMMENT ON TABLE public.hex_standardiserade_roller
    IS 'Definierar vilka roller som ska skapas automatiskt för nya scheman.
    Stöder både schemaspecifika och globala roller.';

COMMENT ON COLUMN public.hex_standardiserade_roller.with_login
    IS 'Om true skapas rollen med LOGIN och ett autogenererat lösenord (via pgcrypto).
    Lösenordet sparas i hex_role_credentials.
    Om false skapas rollen som NOLOGIN (behörighetsgrupp för t.ex. AD-användare).';

COMMENT ON COLUMN public.hex_standardiserade_roller.arvs_fran
    IS 'Om satt, beviljas denna roll till den nya rollen via GRANT istället för att
    hex_tilldela_rollrattigheter() anropas direkt. Stödjer {schema}-substitution.
    Används för att låta gs_r_{schema} och gs_w_{schema} ärva rättigheter från
    r_{schema} respektive w_{schema}, så att behörigheterna hålls synkroniserade.';

-- Fyra roller per schema:
--   r_  / w_     – NOLOGIN behörighetsgrupper, tilldelas AD-användare och AD-grupper
--   gs_r_ / gs_w_ – LOGIN tjänstekonton för GeoServer, ärver från r_/w_
INSERT INTO hex_standardiserade_roller (rollnamn, rolltyp, schema_uttryck, with_login, arvs_fran, beskrivning) VALUES
    ('r_{schema}',    'read',  'IS NOT NULL', false, NULL,          'Läsbehörighetsgrupp – tilldelas AD-användare och AD-grupper'),
    ('w_{schema}',    'write', 'IS NOT NULL', false, NULL,          'Skrivbehörighetsgrupp – tilldelas AD-användare och AD-grupper'),
    ('gs_r_{schema}', 'read',  'IS NOT NULL', true,  'r_{schema}',  'GeoServer läs-tjänstekonto – ärver behörigheter från r_{schema}'),
    ('gs_w_{schema}', 'write', 'IS NOT NULL', true,  'w_{schema}',  'GeoServer skriv-tjänstekonto – ärver behörigheter från w_{schema}')
ON CONFLICT (rollnamn) DO UPDATE
    SET with_login  = EXCLUDED.with_login,
        arvs_fran   = EXCLUDED.arvs_fran,
        rolltyp     = EXCLUDED.rolltyp,
        beskrivning = EXCLUDED.beskrivning;

-- Any database user who creates tables needs to read these configuration tables,
-- since the trigger functions (hex_hantera_ny_tabell, hex_hantera_ny_kolumn) run
-- as SECURITY INVOKER (the calling user's privileges).
GRANT SELECT ON public.hex_standardiserade_roller TO PUBLIC;
