-- TABELL: public.hex_metadata
--
-- Kopplar varje Hex-hanterad föräldertabell (via OID) till dess historiktabell
-- och QA-triggerfunktion. OID:er överlever ALTER TABLE RENAME TO, vilket gör att
-- mappningen förblir giltig även när en tabell döps om – till skillnad från den
-- gamla namnkonventionsuppslaget (tabell_h) som slutar fungera direkt.
--
-- Skrivs av:      skapa_historik_qa()        (vid skapande av historiktabell)
-- Uppdateras av:  hantera_kolumntillagg()    (vid ALTER TABLE RENAME TO)
-- Raderas av:     hantera_borttagen_tabell() (vid DROP TABLE)

CREATE TABLE IF NOT EXISTS public.hex_metadata (
    parent_oid       oid          PRIMARY KEY,
    parent_schema    text         NOT NULL,
    parent_table     text         NOT NULL,
    history_schema   text         NOT NULL,
    history_table    text         NOT NULL,
    trigger_funktion text,        -- NULL om skapa_historik_qa returnerade false
    created_at       timestamptz  NOT NULL DEFAULT now()
);

ALTER TABLE public.hex_metadata OWNER TO gis_admin;

-- Tillåter alla autentiserade användare att hantera sina egna metadata-poster.
-- Alla skrivningar sker via händelsetriggerfunktioner som körs i den anropande
-- användarens säkerhetskontext, varför PUBLIC-behörighet krävs.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hex_metadata TO PUBLIC;

COMMENT ON TABLE public.hex_metadata IS
    'OID → mappning till historiktabell och QA-trigger för alla Hex-hanterade tabeller.
     OID:er är stabila vid ALTER TABLE RENAME TO, vilket gör tabellen till auktoritativ
     källa för rensning och namnpropagering.';

COMMENT ON COLUMN public.hex_metadata.parent_oid IS
    'pg_class.oid för föräldertabellen. Stabil vid omdöpning.';
COMMENT ON COLUMN public.hex_metadata.history_table IS
    'Faktiskt namn på historiktabellen som lagrat i pg_class (kan skilja sig från
     parent_table||''_h'' när föräldertabellens namn är 62+ tecken och PostgreSQL
     trunkerar identifieraren till 63 byte).';
COMMENT ON COLUMN public.hex_metadata.trigger_funktion IS
    'Namn på QA-triggerfunktionen (trg_fn_<originalnamn>_qa).
     Ändras INTE när föräldertabellen döps om.';
