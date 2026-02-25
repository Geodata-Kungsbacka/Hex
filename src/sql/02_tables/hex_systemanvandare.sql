-- TABLE: public.hex_systemanvandare
--
-- Registry of known system users/tools that create tables in two steps:
--   1. CREATE TABLE ... (columns, no geometry)
--   2. ALTER TABLE ... ADD COLUMN geom geometry(...)
--
-- When a session matches an entry here (by session_user, current_user, or
-- application_name), the hantera_ny_tabell trigger allows tables with
-- geometry suffixes (_p, _l, _y, _g) to be created without geometry and
-- registers them in hex_afvaktande_geometri instead of raising an error.
-- The geometry-specific post-processing (GiST index, validation constraint)
-- is then completed by hantera_kolumntillagg when the geometry column arrives.
--
-- Written by:  DBA / system administrator
-- Read by:     hantera_ny_tabell(), hantera_kolumntillagg()

CREATE TABLE IF NOT EXISTS public.hex_systemanvandare (
    anvandare    text  PRIMARY KEY,
    beskrivning  text
);

ALTER TABLE public.hex_systemanvandare OWNER TO gis_admin;

-- Event trigger functions run in the calling user's security context.
-- Read access is required by trigger functions executing as any user.
GRANT SELECT ON public.hex_systemanvandare TO PUBLIC;
GRANT INSERT, UPDATE, DELETE ON public.hex_systemanvandare TO gis_admin;

-- Seed: FME Desktop / FME Server
INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)
VALUES ('fme', 'FME Desktop/Server – skapar tabeller i två steg: CREATE TABLE följt av ALTER TABLE ADD COLUMN geom')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE public.hex_systemanvandare IS
    'Kända systemanvändare/-verktyg som skapar tabeller i två steg (CREATE TABLE utan geometri,
     sedan ALTER TABLE ADD COLUMN geom). Matchning sker mot session_user, current_user
     och application_name. Läggs till av DBA vid behov.';
