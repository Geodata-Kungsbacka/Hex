-- TABELL: public.hex_metadata
--
-- Register över alla Hex-tabeller, nycklat på OID, med historiktabell och
-- QA-triggerfunktion för de tabeller som har historik. OID:er överlever ALTER
-- TABLE RENAME TO, så registret ger alltid tabellens gamla namn vid ett
-- namnbyte – oavsett om tabellen har historik. Det används för att döpa om
-- historiktabellen och för att flytta de namnnycklade raderna i
-- hex_dummy_geometrier, hex_afvaktande_geometri och hex_avvikande_srid.
--
-- history_schema och history_table är NULL för tabeller utan historik. En rad
-- betyder alltså "Hex-tabell", inte "har historik" – läsare som bara gäller
-- historik filtrerar på history_table IS NOT NULL.
--
-- Skrivs av:      hex_registrera_metadata()      (via hex_hantera_ny_tabell och
--                                                 hex_skapa_historik_qa)
--                 hex_komplettera_metadata()     (via hex_underhall, för tabeller
--                                                 som saknar rad)
-- Uppdateras av:  hex_uppdatera_metadata_namn()  (via hex_hantera_ny_kolumn vid RENAME TO)
-- Raderas av:     hex_rensa_metadata()           (via hex_hantera_borttagen_tabell vid
--                                                 DROP TABLE och DROP SCHEMA)

CREATE TABLE IF NOT EXISTS public.hex_metadata (
    parent_oid       oid          PRIMARY KEY,
    parent_schema    text         NOT NULL,
    parent_table     text         NOT NULL,
    history_schema   text,        -- NULL om tabellen saknar historik
    history_table    text,        -- NULL om tabellen saknar historik
    trigger_funktion text,        -- NULL om tabellen saknar historik
    created_at       timestamptz  NOT NULL DEFAULT now(),
    -- session_user, inte current_user: event-triggern kan köras med en annan
    -- aktiv roll (SET ROLE), men det är inloggningen som skapade tabellen.
    created_by       text         DEFAULT session_user
);

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_metadata OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

-- Alla får läsa, ingen utom ägaren får skriva direkt. Event-triggrarna körs
-- som den användare som gör DDL:en och skriver därför via SECURITY
-- DEFINER-funktionerna hex_registrera_metadata(), hex_uppdatera_metadata_namn()
-- och hex_rensa_metadata(), som härleder allt de skriver ur systemkatalogen.
--
-- REVOKE står kvar för en ominstallation över en befintlig tabell (CREATE
-- TABLE IF NOT EXISTS rör inte rättigheterna). Invariant: PUBLIC ska aldrig
-- kunna skriva här, oavsett hur databasen installerades.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.hex_metadata FROM PUBLIC;
GRANT SELECT ON public.hex_metadata TO PUBLIC;

COMMENT ON TABLE public.hex_metadata IS
    'Register över alla Hex-tabeller (OID → namn), med historiktabell och QA-trigger
     för tabeller som har historik. OID:er är stabila vid ALTER TABLE RENAME TO, vilket
     gör tabellen till auktoritativ källa för rensning och namnpropagering.';

COMMENT ON COLUMN public.hex_metadata.parent_oid IS
    'pg_class.oid för föräldertabellen. Stabil vid omdöpning.';
COMMENT ON COLUMN public.hex_metadata.parent_schema IS
    'Schemanamnet för föräldertabellen. Uppdateras vid ALTER TABLE RENAME TO.';
COMMENT ON COLUMN public.hex_metadata.parent_table IS
    'Tabellnamnet för föräldertabellen. Uppdateras vid ALTER TABLE RENAME TO.';
COMMENT ON COLUMN public.hex_metadata.history_schema IS
    'Schemanamnet för historiktabellen – alltid samma som föräldertabellens schema.
     NULL om tabellen saknar historik.';
COMMENT ON COLUMN public.hex_metadata.history_table IS
    'Faktiskt namn på historiktabellen som lagrat i pg_class (kan skilja sig från
     parent_table||''_h'' när föräldertabellens namn är 62+ tecken och PostgreSQL
     trunkerar identifieraren till 63 byte). NULL om tabellen saknar historik.';
COMMENT ON COLUMN public.hex_metadata.trigger_funktion IS
    'Namn på QA-triggerfunktionen (trg_fn_<tabell>_qa). Döps om och uppdateras
     tillsammans med föräldertabellen vid RENAME TO, utom när det nya namnet
     skulle bli längre än 63 tecken – då behålls det gamla.';
COMMENT ON COLUMN public.hex_metadata.created_at IS
    'Tidpunkt då posten registrerades i hex_metadata.';
COMMENT ON COLUMN public.hex_metadata.created_by IS
    'Inloggningsrollen (session_user) som skapade tabellen. NULL när den är okänd:
     poster registrerade innan kolumnen fanns och poster som hex_underhall()
     lagt till i efterhand. Ändras inte vid ON CONFLICT DO UPDATE i
     hex_registrera_metadata(), så den som skapade tabellen först står kvar.';
