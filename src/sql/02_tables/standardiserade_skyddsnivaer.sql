-- Table: public.standardiserade_skyddsnivaer

CREATE TABLE IF NOT EXISTS public.standardiserade_skyddsnivaer (
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    prefix text NOT NULL,
    beskrivning text,
    publiceras_geoserver boolean NOT NULL DEFAULT false,
    anonym_las boolean NOT NULL DEFAULT false,

    CONSTRAINT standardiserade_skyddsnivaer_pkey PRIMARY KEY (gid),
    CONSTRAINT standardiserade_skyddsnivaer_prefix_key UNIQUE (prefix),
    CONSTRAINT valid_skyddsniva_prefix CHECK (prefix ~ '^sk[a-z0-9]+$')
);

-- Safe for existing installations: adds the column without touching existing rows.
ALTER TABLE public.standardiserade_skyddsnivaer
    ADD COLUMN IF NOT EXISTS anonym_las boolean NOT NULL DEFAULT false;

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

COMMENT ON COLUMN public.standardiserade_skyddsnivaer.anonym_las
    IS 'Sant om WMS/WFS-lager i dessa scheman ska vara läsbara utan inloggning (ROLE_ANONYMOUS läggs till i GeoServer ACL-läsregeln). Förutsätter att åtkomst redan begränsas på nätverksnivå, t.ex. via IP-vitlista i web.xml.';


INSERT INTO public.standardiserade_skyddsnivaer
    (prefix, beskrivning, publiceras_geoserver, anonym_las)
VALUES
    ('sk0', 'Öppen publik data',                                        true,  true),
    ('sk1', 'Kommunal data med begränsad åtkomst',                      true,  false),
    ('sk2', 'Begränsad känslig data',                                   false, false),
    ('skx', 'Okänd / oklassificerad data (endast GIS-administratörer)', false, false)
ON CONFLICT (prefix) DO NOTHING;

-- Migration for existing installations: sk0 is open public data and should
-- allow anonymous WMS/WFS reads now that the anonym_las column exists.
UPDATE public.standardiserade_skyddsnivaer
    SET anonym_las = true
    WHERE prefix = 'sk0' AND NOT anonym_las;

-- Trigger functions (hantera_ny_tabell, validera_schemanamn, notifiera_geoserver) run as
-- SECURITY INVOKER, so the calling user needs SELECT on this table.
GRANT SELECT ON public.standardiserade_skyddsnivaer TO PUBLIC;
