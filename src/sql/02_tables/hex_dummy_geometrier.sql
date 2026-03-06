-- TABELL: public.hex_dummy_geometrier
--
-- Spårar de temporära dummy-geometrirader som Hex lägger till i varje
-- geometritabell vid skapandet. Dessa dummies finns till för att QGIS
-- ska kunna identifiera geometritypen direkt via "normal" DB-anslutning
-- utan att användaren behöver deklarera geometrikolumn och SRID manuellt.
--
-- QGIS (med "Använd uppskattad tabellmetadata" av) kör
--   SELECT DISTINCT geometrytype(geom) FROM tabell LIMIT 1
-- för att identifiera geometrityp. En tom tabell ger NULL och QGIS
-- faller tillbaka på en manuell dialogruta. En dummy-rad löser detta.
--
-- Dummy-raden tas automatiskt bort av triggern hex_ta_bort_dummy när
-- den första riktiga raden läggs in i tabellen. Dessförinnan kan den
-- tas bort manuellt – triggern hex_ta_bort_dummy inaktiveras då också
-- automatiskt via hex_dummy_geometrier (tom = triggern gör ingenting).
--
-- Observera: om en dummy tas bort av den automatiska triggern skapas
-- en 'D'-post i historiktabellen (om tabellen har historik). Raden är
-- identifierbar via sin gid som inte längre finns i tabellen.
--
-- Livscykel:
--   INSERT: lagg_till_dummy_geometri()   — anropas av hantera_ny_tabell()
--                                          och hantera_kolumntillagg()
--   DELETE: ta_bort_dummy_rad()          — automatisk, vid första riktiga INSERT
--   DELETE: hantera_borttagen_tabell()   — tabellen droppas

CREATE TABLE IF NOT EXISTS public.hex_dummy_geometrier (
    schema_namn text        NOT NULL,
    tabell_namn text        NOT NULL,
    gid         bigint      NOT NULL,
    registrerad timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_namn, tabell_namn, gid)
);

ALTER TABLE public.hex_dummy_geometrier OWNER TO gis_admin;

-- Händelsetriggerfunktioner och radtriggrar körs i den anropande
-- användarens säkerhetskontext. Skrivrättigheter krävs från alla.
GRANT SELECT, INSERT, DELETE ON public.hex_dummy_geometrier TO PUBLIC;

COMMENT ON TABLE public.hex_dummy_geometrier IS
    'Spårar dummy-geometrirader som Hex sätter in i tomma geometritabeller
     för att QGIS ska kunna identifiera geometrityp via normal DB-anslutning.
     Raden tas automatiskt bort (av triggern hex_ta_bort_dummy) när den
     första riktiga raden läggs in. Posten raderas även av hantera_borttagen_tabell
     om tabellen droppas.';

COMMENT ON COLUMN public.hex_dummy_geometrier.schema_namn IS
    'Schema för tabellen som innehåller dummy-raden.';
COMMENT ON COLUMN public.hex_dummy_geometrier.tabell_namn IS
    'Namn på tabellen som innehåller dummy-raden.';
COMMENT ON COLUMN public.hex_dummy_geometrier.gid IS
    'gid-värde för dummy-raden i tabellen (tilldelat av IDENTITY-sekvensen).';
COMMENT ON COLUMN public.hex_dummy_geometrier.registrerad IS
    'Tidpunkt då dummy-raden registrerades.';
