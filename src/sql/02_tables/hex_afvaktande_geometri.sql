-- TABLE: public.hex_afvaktande_geometri
--
-- Tracks tables that were created by a known system user (see hex_systemanvandare)
-- with a geometry-reserved suffix (_p, _l, _y, _g) but without a geometry column.
-- These tables are awaiting an ALTER TABLE ... ADD COLUMN geom ... from the tool.
--
-- Lifecycle:
--   INSERT: hantera_ny_tabell()      — when system user creates a suffixed table without geom
--   DELETE: hantera_kolumntillagg()  — when geom column is successfully added
--
-- A row lingering here beyond a few hours indicates the tool never completed
-- its second step. Such tables should be reviewed and dropped manually.
--
-- Written by:  hantera_ny_tabell()
-- Deleted by:  hantera_kolumntillagg()

CREATE TABLE IF NOT EXISTS public.hex_afvaktande_geometri (
    schema_namn     text         NOT NULL,
    tabell_namn     text         NOT NULL,
    registrerad     timestamptz  NOT NULL DEFAULT now(),
    registrerad_av  text         NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_namn, tabell_namn)
);

ALTER TABLE public.hex_afvaktande_geometri OWNER TO gis_admin;

-- Event trigger functions run in the calling user's security context.
-- Both read and write access are required from any authenticated user.
GRANT SELECT, INSERT, DELETE ON public.hex_afvaktande_geometri TO PUBLIC;

COMMENT ON TABLE public.hex_afvaktande_geometri IS
    'Tabeller skapade av systemanvändare med geometrisuffix men utan geometrikolumn.
     Registreras av hantera_ny_tabell() och tas bort av hantera_kolumntillagg()
     när geometrikolumnen läggs till. Kvarliggande rader indikerar att verktyget
     aldrig slutförde sitt andra steg.';

COMMENT ON COLUMN public.hex_afvaktande_geometri.schema_namn IS
    'Schema för den afvaktande tabellen.';
COMMENT ON COLUMN public.hex_afvaktande_geometri.tabell_namn IS
    'Namn på den afvaktande tabellen (inkl. geometrisuffix).';
COMMENT ON COLUMN public.hex_afvaktande_geometri.registrerad IS
    'Tidpunkt då tabellen registrerades som afvaktande.';
COMMENT ON COLUMN public.hex_afvaktande_geometri.registrerad_av IS
    'DB-användare (current_user) som registrerade raden.';
