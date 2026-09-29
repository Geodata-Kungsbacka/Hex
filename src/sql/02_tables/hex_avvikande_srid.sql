-- TABELL: public.hex_avvikande_srid
--
-- Granskningstabell för geometritabeller skapade med ett annat
-- koordinatsystem än det som står i hex_installningar.srid (hämtas via
-- hex_srid(), standard EPSG 3007 SWEREF99 12 00).
--
-- En rad registreras automatiskt när hex_hantera_ny_tabell() eller
-- hex_hantera_ny_kolumn() (tvåstegsmönstret) stöter på en tabell
-- vars geometrikolumn har SRID ≠ hex_srid(). Tabellen bör ej finnas kvar
-- i databasen – data i fel koordinatsystem måste transformeras och
-- skrivas om innan det är giltigt för produktion.
--
-- Livscykel:
--   INSERT/UPDATE: hex_hantera_ny_tabell()        — tabell skapad direkt med fel SRID
--   INSERT/UPDATE: hex_hantera_ny_kolumn()        — geometrikolumn tillagd med fel SRID (tvåsteg)
--   INSERT/DELETE: hex_underhall()                — ombyggnad mot aktuellt hex_srid()
--   DELETE:        hex_hantera_borttagen_tabell() — tabellen droppas (oavsett anledning)
--
-- En kvarliggande rad innebär att tabellen fortfarande finns i databasen
-- med ett avvikande koordinatsystem.
--
-- Skapas av:   hex_hantera_ny_tabell(), hex_hantera_ny_kolumn(), hex_underhall()
-- Raderas av:  hex_hantera_borttagen_tabell(), hex_underhall()

CREATE TABLE IF NOT EXISTS public.hex_avvikande_srid (
    schema_namn     text         NOT NULL,
    tabell_namn     text         NOT NULL,
    srid            integer      NOT NULL,
    registrerad     timestamptz  NOT NULL DEFAULT now(),
    registrerad_av  text         NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_namn, tabell_namn)
);

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_avvikande_srid OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

-- Händelsetriggerfunktioner körs i den anropande användarens säkerhetskontext.
-- Både läs- och skrivrättigheter krävs från alla autentiserade användare.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hex_avvikande_srid TO PUBLIC;

COMMENT ON TABLE public.hex_avvikande_srid IS
    'Granskningstabell för geometritabeller med avvikande koordinatsystem (SRID ≠ hex_srid()).
     Registreras automatiskt vid CREATE TABLE eller ALTER TABLE ADD COLUMN geom när
     SRID inte är hex_installningar.srid (standard 3007, SWEREF99 12 00). Raden raderas av
     hex_hantera_borttagen_tabell() om tabellen droppas. hex_underhall() bygger om tabellen
     mot aktuell inställning. Kvarliggande rader indikerar tabeller i databasen med fel
     koordinatsystem – dessa måste transformeras och skrivas om före produktionsbruk.';

COMMENT ON COLUMN public.hex_avvikande_srid.schema_namn IS
    'Schema för tabellen med avvikande SRID.';
COMMENT ON COLUMN public.hex_avvikande_srid.tabell_namn IS
    'Namn på tabellen med avvikande SRID.';
COMMENT ON COLUMN public.hex_avvikande_srid.srid IS
    'Det SRID som tabellen faktiskt har (förväntat: hex_srid()).';
COMMENT ON COLUMN public.hex_avvikande_srid.registrerad IS
    'Tidpunkt då avvikelsen registrerades (eller senast uppdaterades).';
COMMENT ON COLUMN public.hex_avvikande_srid.registrerad_av IS
    'DB-användare (current_user) som utlöste registreringen.';
