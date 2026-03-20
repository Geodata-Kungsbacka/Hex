CREATE TABLE IF NOT EXISTS public.hex_role_credentials (
    rolname     text        NOT NULL,
    password    text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT hex_role_credentials_pkey PRIMARY KEY (rolname)
);

ALTER TABLE public.hex_role_credentials
    OWNER TO postgres;

COMMENT ON TABLE public.hex_role_credentials
    IS 'Lagrar autogenererade lösenord för LOGIN-roller skapade av Hex.
    Skrivs av hantera_standardiserade_roller() vid CREATE SCHEMA.
    Läses av hex_listener för att konfigurera direktanslutningar i GeoServer.';

-- Begränsa åtkomst: enbart postgres/gis_admin skriver, hex_listener läser
REVOKE ALL ON public.hex_role_credentials FROM PUBLIC;
GRANT SELECT ON public.hex_role_credentials TO hex_listener;
