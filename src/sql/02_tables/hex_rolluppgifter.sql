CREATE TABLE IF NOT EXISTS public.hex_rolluppgifter (
    rollnamn        text        NOT NULL,
    losenord        text        NULL,       -- NULL för NOLOGIN-roller (r_*, w_*)
    kan_logga_in    boolean     NOT NULL DEFAULT true,
    skapad_tidpunkt timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT hex_rolluppgifter_pkey PRIMARY KEY (rollnamn)
);

ALTER TABLE public.hex_rolluppgifter
    OWNER TO postgres;

COMMENT ON TABLE public.hex_rolluppgifter
    IS 'Register över alla Hex-skapade roller per schema.
    Täcker fyra rolltyper per schema:
      r_{schema}    – NOLOGIN behörighetsgrupp (läs), kan_logga_in=false, losenord=NULL
      w_{schema}    – NOLOGIN behörighetsgrupp (skriv), kan_logga_in=false, losenord=NULL
      gs_r_{schema} – LOGIN GeoServer läs-tjänstekonto, kan_logga_in=true, losenord satt
      gs_w_{schema} – LOGIN GeoServer skriv-tjänstekonto, kan_logga_in=true, losenord satt
    Skrivs av hex_hantera_std_roller() vid CREATE SCHEMA.
    Läses av hex_listener för att konfigurera direktanslutningar i GeoServer
    (enbart rader med kan_logga_in=true och rollnamn som matchar gs_r_{schema}).
    Används också av hex_underhall() som källa för rollverifiering.';

COMMENT ON COLUMN public.hex_rolluppgifter.kan_logga_in
    IS 'true för LOGIN-roller med lösenord (gs_r_*, gs_w_*).
    false för NOLOGIN-behörighetsgrupper (r_*, w_*) – dessa har losenord=NULL.';

-- Begränsa åtkomst: enbart postgres/gis_admin skriver, hex_listener läser
REVOKE ALL ON public.hex_rolluppgifter FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hex_listener') THEN
        EXECUTE 'GRANT SELECT ON public.hex_rolluppgifter TO hex_listener';
    END IF;
END$$;
