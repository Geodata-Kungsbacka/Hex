-- Table: public.hex_standardiserade_skyddsnivaer

CREATE TABLE IF NOT EXISTS public.hex_standardiserade_skyddsnivaer (
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    prefix text NOT NULL,
    beskrivning text,
    publiceras_geoserver boolean NOT NULL DEFAULT false,
    anonym_las boolean NOT NULL DEFAULT false,

    CONSTRAINT hex_standardiserade_skyddsnivaer_pkey PRIMARY KEY (gid),
    CONSTRAINT hex_standardiserade_skyddsnivaer_prefix_key UNIQUE (prefix),
    CONSTRAINT valid_skyddsniva_prefix CHECK (prefix ~ '^sk[a-z0-9]+$')
);

-- Safe for existing installations: adds the column without touching existing rows.
--
-- Backfyllningen av sk0 nedan är en ENGÅNGSMIGRERING och får bara köras samma
-- gång som kolumnen faktiskt tillkom. Kördes den varje installation skulle en
-- DBA som medvetet stängt av anonym läsning för sk0 få den påtvingad tillbaka
-- vid nästa `python install_hex.py`. Vi noterar därför om kolumnen fanns innan.
DO $$
DECLARE
    kolumnen_fanns boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'hex_standardiserade_skyddsnivaer'
          AND column_name  = 'anonym_las'
    ) INTO kolumnen_fanns;

    ALTER TABLE public.hex_standardiserade_skyddsnivaer
        ADD COLUMN IF NOT EXISTS anonym_las boolean NOT NULL DEFAULT false;

    -- sk0 är öppen publik data och ska tillåta anonyma WMS/WFS-läsningar.
    -- Vid en ny installation finns kolumnen redan i CREATE TABLE ovan, och
    -- INSERT-satsen längre ned sätter sk0 till true på egen hand.
    IF NOT kolumnen_fanns THEN
        UPDATE public.hex_standardiserade_skyddsnivaer
            SET anonym_las = true
            WHERE prefix = 'sk0';
    END IF;
END;
$$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_standardiserade_skyddsnivaer OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON TABLE public.hex_standardiserade_skyddsnivaer
    IS 'Definierar giltiga säkerhetsnivåprefix (sk0, sk1, sk2, skx, ...) och deras egenskaper.
Tabellen används av hex_validera_schemanamn() för att bygga det tillåtna namnmönstret dynamiskt,
och av hex_notifiera_gs() för att avgöra vilka scheman som ska publiceras.
Lägg till en ny rad här för att registrera en ny säkerhetsnivå.';

COMMENT ON COLUMN public.hex_standardiserade_skyddsnivaer.prefix
    IS 'Kortprefixet som ingår i schemanamnet, t.ex. "sk0", "sk1", "skx". Måste matcha ^sk[a-z0-9]+$.';

COMMENT ON COLUMN public.hex_standardiserade_skyddsnivaer.publiceras_geoserver
    IS 'Sant om scheman med detta prefix ska publiceras automatiskt till GeoServer via pg_notify.';

COMMENT ON COLUMN public.hex_standardiserade_skyddsnivaer.anonym_las
    IS 'Sant om WMS/WFS-lager i dessa scheman ska vara läsbara utan inloggning (ROLE_ANONYMOUS läggs till i GeoServer ACL-läsregeln). Förutsätter att åtkomst redan begränsas på nätverksnivå, t.ex. via IP-vitlista i web.xml.';


INSERT INTO public.hex_standardiserade_skyddsnivaer
    (prefix, beskrivning, publiceras_geoserver, anonym_las)
VALUES
    ('sk0', 'Öppen publik data',                                        true,  true),
    ('sk1', 'Kommunal data med begränsad åtkomst',                      true,  false),
    ('sk2', 'Begränsad känslig data',                                   false, false),
    ('skx', 'Okänd / oklassificerad data (endast GIS-administratörer)', false, false)
ON CONFLICT (prefix) DO NOTHING;

-- Trigger functions (hex_hantera_ny_tabell, hex_validera_schemanamn, hex_notifiera_gs) run as
-- SECURITY INVOKER, so the calling user needs SELECT on this table.
GRANT SELECT ON public.hex_standardiserade_skyddsnivaer TO PUBLIC;
