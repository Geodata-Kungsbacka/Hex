-- TABELL: public.hex_avvikande_srid
--
-- Granskningstabell för geometritabeller skapade med ett annat
-- koordinatsystem än EPSG 3007 (SWEREF99 12 00), vilket är det
-- enda koordinatsystem som ska användas i databasen.
--
-- En rad registreras automatiskt när hantera_ny_tabell() eller
-- hantera_kolumntillagg() (tvåstegsmönstret) stöter på en tabell
-- vars geometrikolumn har SRID ≠ 3007. Tabellen bör ej finnas kvar
-- i databasen – data i fel koordinatsystem måste transformeras och
-- skrivas om innan det är giltigt för produktion.
--
-- Livscykel:
--   INSERT/UPDATE: hantera_ny_tabell()        — tabell skapad direkt med fel SRID
--   INSERT/UPDATE: hantera_kolumntillagg()    — geometrikolumn tillagd med fel SRID (tvåsteg)
--   DELETE:        hantera_borttagen_tabell() — tabellen droppas (oavsett anledning)
--
-- En kvarliggande rad innebär att tabellen fortfarande finns i databasen
-- med ett avvikande koordinatsystem.
--
-- Skapas av:   hantera_ny_tabell(), hantera_kolumntillagg()
-- Raderas av:  hantera_borttagen_tabell()

CREATE TABLE IF NOT EXISTS public.hex_avvikande_srid (
    schema_namn     text         NOT NULL,
    tabell_namn     text         NOT NULL,
    srid            integer      NOT NULL,
    registrerad     timestamptz  NOT NULL DEFAULT now(),
    registrerad_av  text         NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_namn, tabell_namn)
);

ALTER TABLE public.hex_avvikande_srid OWNER TO gis_admin;

-- Händelsetriggerfunktioner körs i den anropande användarens säkerhetskontext.
-- Både läs- och skrivrättigheter krävs från alla autentiserade användare.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hex_avvikande_srid TO PUBLIC;

COMMENT ON TABLE public.hex_avvikande_srid IS
    'Granskningstabell för geometritabeller med avvikande koordinatsystem (SRID ≠ 3007).
     Registreras automatiskt vid CREATE TABLE eller ALTER TABLE ADD COLUMN geom när
     SRID inte är 3007 (SWEREF99 12 00). Tabellen raderas av hantera_borttagen_tabell()
     om den droppas. Kvarliggande rader indikerar tabeller i databasen med fel
     koordinatsystem – dessa måste transformeras och skrivas om före produktionsbruk.';

COMMENT ON COLUMN public.hex_avvikande_srid.schema_namn IS
    'Schema för tabellen med avvikande SRID.';
COMMENT ON COLUMN public.hex_avvikande_srid.tabell_namn IS
    'Namn på tabellen med avvikande SRID.';
COMMENT ON COLUMN public.hex_avvikande_srid.srid IS
    'Det SRID som tabellen faktiskt har (förväntat: 3007).';
COMMENT ON COLUMN public.hex_avvikande_srid.registrerad IS
    'Tidpunkt då avvikelsen registrerades (eller senast uppdaterades).';
COMMENT ON COLUMN public.hex_avvikande_srid.registrerad_av IS
    'DB-användare (current_user) som utlöste registreringen.';
