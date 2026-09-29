-- TABELL: public.hex_installningar
--
-- Databasövergripande inställningar för Hex. Tabellen har exakt en rad
-- (id är alltid true), och varje inställning är en egen typad kolumn. Det ger
-- typkontroll och främmande nycklar som en nyckel/värde-tabell inte kan ge,
-- t.ex. att srid måste finnas i spatial_ref_sys.
--
-- Nya inställningar läggs till som kolumner med ett DEFAULT, så att raden som
-- redan finns får ett värde. Glöm inte att lägga kolumnen i PRESERVE_CONFIG i
-- install_hex.py, annars skrivs DBA:ns värde över vid --upgrade.
--
-- Läses av:  hex_srid()                      – förväntat koordinatsystem
--            hex_lagg_till_dummy_geometri()  – referenspunkt för dummy-rader
--            hex_geometrisuffix(),
--            hex_tabellsuffix()              – geometrisuffix i tabell- och vynamn

CREATE TABLE IF NOT EXISTS public.hex_installningar (
    id             boolean          NOT NULL DEFAULT true,
    srid           integer          NOT NULL DEFAULT 3007,
    dummy_x        double precision NOT NULL DEFAULT 160000,
    dummy_y        double precision NOT NULL DEFAULT 6395000,
    dummy_storlek  double precision NOT NULL DEFAULT 100,
    suffix_punkt   text             NOT NULL DEFAULT '_p',
    suffix_linje   text             NOT NULL DEFAULT '_l',
    suffix_yta     text             NOT NULL DEFAULT '_y',
    suffix_ovrigt  text             NOT NULL DEFAULT '_g',

    CONSTRAINT hex_installningar_pkey PRIMARY KEY (id),
    CONSTRAINT hex_installningar_en_rad CHECK (id),
    CONSTRAINT hex_installningar_srid_fkey
        FOREIGN KEY (srid) REFERENCES public.spatial_ref_sys (srid),
    CONSTRAINT hex_installningar_dummy_storlek_positiv CHECK (dummy_storlek > 0),
    -- Ett understreck följt av gemena bokstäver/siffror. Eftersom inget suffix
    -- innehåller ett andra understreck kan inget av dem vara slutet på ett
    -- annat, och hex_tabellsuffix() blir entydig.
    CONSTRAINT hex_installningar_suffix_format CHECK (
        suffix_punkt  ~ '^_[a-z0-9]+$' AND suffix_linje  ~ '^_[a-z0-9]+$' AND
        suffix_yta    ~ '^_[a-z0-9]+$' AND suffix_ovrigt ~ '^_[a-z0-9]+$'
    ),
    CONSTRAINT hex_installningar_suffix_unika CHECK (
        suffix_punkt <> suffix_linje  AND suffix_punkt <> suffix_yta AND
        suffix_punkt <> suffix_ovrigt AND suffix_linje <> suffix_yta AND
        suffix_linje <> suffix_ovrigt AND suffix_yta   <> suffix_ovrigt
    ),
    -- _h är reserverat för historiktabeller (hex_hantera_ny_tabell)
    CONSTRAINT hex_installningar_suffix_ej_h CHECK (
        '_h' NOT IN (suffix_punkt, suffix_linje, suffix_yta, suffix_ovrigt)
    )
);

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_installningar OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

-- Raden skapas bara om den saknas. Invariant: en ominstallation får aldrig
-- skriva över värden DBA:n satt.
INSERT INTO public.hex_installningar (id) VALUES (true)
ON CONFLICT (id) DO NOTHING;

-- Triggerfunktionerna körs som SECURITY INVOKER och behöver kunna läsa
-- inställningarna. Bara ägaren får ändra dem. REVOKE står kvar för en
-- ominstallation över en befintlig tabell (CREATE TABLE IF NOT EXISTS rör inte
-- rättigheterna).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.hex_installningar FROM PUBLIC;
GRANT SELECT ON public.hex_installningar TO PUBLIC;

COMMENT ON TABLE public.hex_installningar IS
    'Databasövergripande inställningar för Hex. Exakt en rad; varje inställning är en kolumn.
Ändra med UPDATE public.hex_installningar SET ... och kör sedan SELECT * FROM hex_underhall()
så att befintliga tabeller stäms av mot de nya värdena.';

COMMENT ON COLUMN public.hex_installningar.id IS
    'Alltid true. Primärnyckel och CHECK tillsammans gör att tabellen bara kan ha en rad.';
COMMENT ON COLUMN public.hex_installningar.srid IS
    'Förväntat koordinatsystem (EPSG-kod) för alla geometritabeller. Tabeller med annat SRID
skapas men registreras i hex_avvikande_srid. Måste finnas i spatial_ref_sys. Standard: 3007
(SWEREF99 12 00).';
COMMENT ON COLUMN public.hex_installningar.dummy_x IS
    'X-koordinat (i srid:s enheter) för nedre vänstra hörnet av dummy-geometrier.';
COMMENT ON COLUMN public.hex_installningar.dummy_y IS
    'Y-koordinat (i srid:s enheter) för nedre vänstra hörnet av dummy-geometrier.';
COMMENT ON COLUMN public.hex_installningar.dummy_storlek IS
    'Sidlängd (i srid:s enheter) för dummy-geometrier. Standard 100, dvs. 100 × 100 m i ett
metriskt system. Sätt ett mindre värde, t.ex. 0.001, för ett geografiskt koordinatsystem.';
COMMENT ON COLUMN public.hex_installningar.suffix_punkt IS
    'Namnsuffix för tabeller och vyer med punktgeometri (POINT, MULTIPOINT). Standard _p.
Gäller nya tabeller och vyer; befintliga döps inte om.';
COMMENT ON COLUMN public.hex_installningar.suffix_linje IS
    'Namnsuffix för linjegeometri (LINESTRING, MULTILINESTRING). Standard _l.';
COMMENT ON COLUMN public.hex_installningar.suffix_yta IS
    'Namnsuffix för ytgeometri (POLYGON, MULTIPOLYGON). Standard _y.';
COMMENT ON COLUMN public.hex_installningar.suffix_ovrigt IS
    'Namnsuffix för övrig geometri (GEOMETRY, GEOMETRYCOLLECTION m.fl.) och för vyer med
flera geometrikolumner. Standard _g.';
