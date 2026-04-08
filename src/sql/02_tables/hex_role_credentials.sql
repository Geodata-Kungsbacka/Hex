CREATE TABLE IF NOT EXISTS public.hex_role_credentials (
    rolname     text        NOT NULL,
    password    text        NULL,       -- NULL för NOLOGIN-roller (r_*, w_*)
    rolcanlogin boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT hex_role_credentials_pkey PRIMARY KEY (rolname)
);

ALTER TABLE public.hex_role_credentials
    OWNER TO postgres;

COMMENT ON TABLE public.hex_role_credentials
    IS 'Register över alla Hex-skapade roller per schema.
    Täcker fyra rolltyper per schema:
      r_{schema}    – NOLOGIN behörighetsgrupp (läs), rolcanlogin=false, password=NULL
      w_{schema}    – NOLOGIN behörighetsgrupp (skriv), rolcanlogin=false, password=NULL
      gs_r_{schema} – LOGIN GeoServer läs-tjänstekonto, rolcanlogin=true, password satt
      gs_w_{schema} – LOGIN GeoServer skriv-tjänstekonto, rolcanlogin=true, password satt
    Skrivs av hantera_standardiserade_roller() vid CREATE SCHEMA.
    Läses av hex_listener för att konfigurera direktanslutningar i GeoServer
    (enbart rader med rolcanlogin=true och rolnamn som matchar gs_r_{schema}).
    Används också av underhall_hex() som källa för rollverifiering.';

COMMENT ON COLUMN public.hex_role_credentials.rolcanlogin
    IS 'true för LOGIN-roller med lösenord (gs_r_*, gs_w_*).
    false för NOLOGIN-behörighetsgrupper (r_*, w_*) – dessa har password=NULL.';

-- Begränsa åtkomst: enbart postgres/gis_admin skriver, hex_listener läser
REVOKE ALL ON public.hex_role_credentials FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hex_listener') THEN
        EXECUTE 'GRANT SELECT ON public.hex_role_credentials TO hex_listener';
    END IF;
END$$;
