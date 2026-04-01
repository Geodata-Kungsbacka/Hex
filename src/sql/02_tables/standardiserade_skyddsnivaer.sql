-- Table: public.standardiserade_skyddsnivaer

CREATE TABLE IF NOT EXISTS public.standardiserade_skyddsnivaer (
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    prefix text NOT NULL,
    beskrivning text,
    publiceras_geoserver boolean NOT NULL DEFAULT false,

    CONSTRAINT standardiserade_skyddsnivaer_pkey PRIMARY KEY (gid),
    CONSTRAINT standardiserade_skyddsnivaer_prefix_key UNIQUE (prefix),
    CONSTRAINT valid_skyddsniva_prefix CHECK (prefix ~ '^sk[a-z0-9]+$')
);

ALTER TABLE public.standardiserade_skyddsnivaer
    OWNER TO postgres;

COMMENT ON TABLE public.standardiserade_skyddsnivaer
    IS 'Definierar giltiga säkerhetsnivåprefix (sk0, sk1, sk2, skx, ...) och deras egenskaper.
Tabellen används av validera_schemanamn() för att bygga det tillåtna namnmönstret dynamiskt,
och av notifiera_geoserver() för att avgöra vilka scheman som ska publiceras.
Lägg till en ny rad här för att registrera en ny säkerhetsnivå.';

COMMENT ON COLUMN public.standardiserade_skyddsnivaer.prefix
    IS 'Kortprefixet som ingår i schemanamnet, t.ex. "sk0", "sk1", "skx". Måste matcha ^sk[a-z0-9]+$.';

COMMENT ON COLUMN public.standardiserade_skyddsnivaer.publiceras_geoserver
    IS 'Sant om scheman med detta prefix ska publiceras automatiskt till GeoServer via pg_notify.';


INSERT INTO public.standardiserade_skyddsnivaer
    (prefix, beskrivning, publiceras_geoserver)
VALUES
    ('sk0', 'Öppen publik data',                                       true),
    ('sk1', 'Kommunal data med begränsad åtkomst',                     true),
    ('sk2', 'Begränsad känslig data',                                  false),
    ('skx', 'Okänd / oklassificerad data (endast GIS-administratörer)', false);

-- Trigger functions (hantera_ny_tabell, validera_schemanamn, notifiera_geoserver) run as
-- SECURITY INVOKER, so the calling user needs SELECT on this table.
GRANT SELECT ON public.standardiserade_skyddsnivaer TO PUBLIC;
