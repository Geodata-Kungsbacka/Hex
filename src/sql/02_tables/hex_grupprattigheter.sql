-- TABELL: public.hex_grupprattigheter
--
-- DBA-hanterad mappningstabell: vilka AD-synkade grupproller ska beviljas
-- vilka Hex-schemaroller.
-- Applicera mappningarna med: SELECT tillämpa_grupprattigheter();
--
-- Underhålls av:  DBA / systemadministratör
-- Appliceras av:  tillämpa_grupprattigheter()

CREATE TABLE IF NOT EXISTS public.hex_grupprattigheter (
    id              serial          PRIMARY KEY,
    ad_grupproll    text            NOT NULL,   -- AD-synkad NOLOGIN-grupproll (t.ex. 'karttjanst_gis')
    hex_roll        text            NOT NULL,   -- Hex-schemaroll att bevilja (t.ex. 'r_sk1_global')
    beskrivning     text,                       -- Valfri DBA-anteckning
    skapad          timestamptz     NOT NULL DEFAULT now(),
    skapad_av       text            NOT NULL DEFAULT session_user,
    UNIQUE (ad_grupproll, hex_roll)
);

ALTER TABLE public.hex_grupprattigheter OWNER TO gis_admin;

COMMENT ON TABLE public.hex_grupprattigheter IS
    'DBA-hanterad mappning: vilka AD-synkade grupproller ska beviljas vilka Hex-schemaroller.
     Applicera med: SELECT tillämpa_grupprattigheter();';

COMMENT ON COLUMN public.hex_grupprattigheter.ad_grupproll IS
    'AD-synkad NOLOGIN-grupproll i PostgreSQL (t.ex. karttjanst_gis).';
COMMENT ON COLUMN public.hex_grupprattigheter.hex_roll IS
    'Hex-schemaroll som ska beviljas till ad_grupproll (t.ex. r_sk1_global).';
COMMENT ON COLUMN public.hex_grupprattigheter.beskrivning IS
    'Valfri DBA-anteckning om varför mappningen finns.';

-- Återkalla alla rättigheter från PUBLIC.
-- Ge skrivrättigheter enbart till ägarrollen (system_owner).
-- Triggerfunktioner behöver inte läsa tabellen direkt.
REVOKE ALL ON public.hex_grupprattigheter FROM PUBLIC;

DO $$
BEGIN
    EXECUTE format(
        'GRANT SELECT, INSERT, UPDATE, DELETE ON public.hex_grupprattigheter TO %I',
        public.system_owner()
    );
END;
$$;
