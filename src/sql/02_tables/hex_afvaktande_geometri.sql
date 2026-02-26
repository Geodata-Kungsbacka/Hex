-- TABELL: public.hex_afvaktande_geometri
--
-- Håller reda på tabeller som skapats av en känd systemanvändare
-- (se hex_systemanvandare) med ett geometrireserverat suffix (_p, _l, _y, _g)
-- men utan någon geometrikolumn. Dessa tabeller väntar på att verktyget ska
-- lägga till geometrin via ALTER TABLE ... ADD COLUMN geom ...
--
-- Livscykel:
--   INSERT: hantera_ny_tabell()        — systemanvändare skapar tabell med suffix men utan geom
--   DELETE: hantera_kolumntillagg()    — geometrikolumnen har lagts till, posten städas bort
--   DELETE: hantera_borttagen_tabell() — tabellen droppades innan geometrin hann läggas till
--
-- En rad som dröjer kvar längre tid indikerar att verktyget aldrig slutförde
-- sitt andra steg. Sådana tabeller bör granskas och vid behov droppas manuellt.
--
-- Skapas av:   hantera_ny_tabell()
-- Raderas av:  hantera_kolumntillagg(), hantera_borttagen_tabell()

CREATE TABLE IF NOT EXISTS public.hex_afvaktande_geometri (
    schema_namn     text         NOT NULL,
    tabell_namn     text         NOT NULL,
    registrerad     timestamptz  NOT NULL DEFAULT now(),
    registrerad_av  text         NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_namn, tabell_namn)
);

ALTER TABLE public.hex_afvaktande_geometri OWNER TO gis_admin;

-- Händelsetriggerfunktioner körs i den anropande användarens säkerhetskontext.
-- Både läs- och skrivrättigheter krävs från alla autentiserade användare.
GRANT SELECT, INSERT, DELETE ON public.hex_afvaktande_geometri TO PUBLIC;

COMMENT ON TABLE public.hex_afvaktande_geometri IS
    'Tabeller skapade av systemanvändare med geometrisuffix men utan geometrikolumn.
     Registreras av hantera_ny_tabell() och tas bort av hantera_kolumntillagg()
     när geometrikolumnen läggs till, eller av hantera_borttagen_tabell() om
     tabellen droppas innan geometrin hunnit läggas till. Kvarliggande rader
     indikerar att verktyget aldrig slutförde sitt andra steg.';

COMMENT ON COLUMN public.hex_afvaktande_geometri.schema_namn IS
    'Schema för den afvaktande tabellen.';
COMMENT ON COLUMN public.hex_afvaktande_geometri.tabell_namn IS
    'Namn på den afvaktande tabellen (inkl. geometrisuffix).';
COMMENT ON COLUMN public.hex_afvaktande_geometri.registrerad IS
    'Tidpunkt då tabellen registrerades som afvaktande.';
COMMENT ON COLUMN public.hex_afvaktande_geometri.registrerad_av IS
    'DB-användare (current_user) som registrerade raden.';
