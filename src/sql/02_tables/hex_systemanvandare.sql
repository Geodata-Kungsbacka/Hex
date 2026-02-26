-- TABELL: public.hex_systemanvandare
--
-- Register över kända systemanvändare och verktyg som skapar tabeller i två steg:
--   1. CREATE TABLE ... (datakolumner, ingen geometri)
--   2. ALTER TABLE ... ADD COLUMN geom geometry(...)
--
-- När en session matchar en post här (via session_user, current_user eller
-- application_name) tillåter händelsetriggern hantera_ny_tabell att tabeller
-- med geometrisuffix (_p, _l, _y, _g) skapas utan geometrikolumn. Tabellen
-- registreras istället i hex_afvaktande_geometri i stället för att ett fel
-- kastas. Geometrispecifik efterbehandling (GiST-index, valideringsbegränsning)
-- slutförs av hantera_kolumntillagg när geometrikolumnen anländer.
--
-- Underhålls av:  DBA / systemadministratör
-- Läses av:       hantera_ny_tabell(), hantera_kolumntillagg()

CREATE TABLE IF NOT EXISTS public.hex_systemanvandare (
    anvandare    text  PRIMARY KEY,
    beskrivning  text
);

ALTER TABLE public.hex_systemanvandare OWNER TO gis_admin;

-- Händelsetriggerfunktioner körs i den anropande användarens säkerhetskontext.
-- Läsrättighet krävs av triggerfunktioner som körs som vilken användare som helst.
GRANT SELECT ON public.hex_systemanvandare TO PUBLIC;
GRANT INSERT, UPDATE, DELETE ON public.hex_systemanvandare TO gis_admin;

-- Förval: FME Desktop / FME Server
INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)
VALUES ('fme', 'FME Desktop/Server – skapar tabeller i två steg: CREATE TABLE följt av ALTER TABLE ADD COLUMN geom')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE public.hex_systemanvandare IS
    'Kända systemanvändare/-verktyg som skapar tabeller i två steg (CREATE TABLE utan geometri,
     sedan ALTER TABLE ADD COLUMN geom). Matchning sker mot session_user, current_user
     och application_name. Läggs till av DBA vid behov.';
