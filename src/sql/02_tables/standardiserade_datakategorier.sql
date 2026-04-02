-- Table: public.standardiserade_datakategorier

CREATE TABLE IF NOT EXISTS public.standardiserade_datakategorier (
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    prefix text NOT NULL,
    beskrivning text,
    validera_geometri boolean NOT NULL DEFAULT false,

    CONSTRAINT standardiserade_datakategorier_pkey PRIMARY KEY (gid),
    CONSTRAINT standardiserade_datakategorier_prefix_key UNIQUE (prefix),
    CONSTRAINT valid_datakategori_prefix CHECK (prefix ~ '^[a-z][a-z0-9]*$')
);

ALTER TABLE public.standardiserade_datakategorier
    OWNER TO postgres;

COMMENT ON TABLE public.standardiserade_datakategorier
    IS 'Definierar giltiga datakategoriprefix (ext, kba, sys, ...) och deras innebörd.
Tabellen används av validera_schemanamn() för att bygga det tillåtna namnmönstret dynamiskt.
Observera att standardiserade_kolumner.schema_uttryck refererar till kategorier med LIKE-uttryck
(t.ex. LIKE ''%_kba_%'') – uppdatera dessa rader vid behov när en ny kategori läggs till.
Lägg till en ny rad här för att registrera en ny datakategori.';

COMMENT ON COLUMN public.standardiserade_datakategorier.prefix
    IS 'Kortprefixet som ingår i schemanamnet, t.ex. "ext", "kba", "sys". Måste matcha ^[a-z][a-z0-9]*$.';

COMMENT ON COLUMN public.standardiserade_datakategorier.validera_geometri
    IS 'Sant om tabeller i scheman med denna datakategori ska få geometrivalidering (CHECK-constraint + trigger).
Påverkar hantera_ny_tabell(), hantera_kolumntillagg() och reparera_rad_triggers().';

INSERT INTO public.standardiserade_datakategorier
    (prefix, beskrivning, validera_geometri)
VALUES
    ('ext', 'Externa datakällor (t.ex. FME-inläsning, regionala register)', false),
    ('kba', 'Interna kommunala datakällor (manuell redigering, ärendedata)', true),
    ('sys', 'Systemdata och administration',                                 false);

-- Trigger functions run as SECURITY INVOKER, so the calling user needs SELECT on this table.
GRANT SELECT ON public.standardiserade_datakategorier TO PUBLIC;
