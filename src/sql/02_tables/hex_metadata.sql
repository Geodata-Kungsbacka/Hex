-- TABLE: public.hex_metadata
--
-- Maps each Hex-managed parent table (by OID) to its history table and
-- QA trigger function. OIDs survive ALTER TABLE RENAME TO, so this
-- mapping stays valid even when the user renames a table - unlike the
-- old naming-convention lookup (tabell_h) which breaks immediately.
--
-- Written by:  skapa_historik_qa()   (on history table creation)
-- Updated by:  hantera_kolumntillagg() (on ALTER TABLE RENAME TO)
-- Deleted by:  hantera_borttagen_tabell() (on DROP TABLE)

CREATE TABLE IF NOT EXISTS public.hex_metadata (
    parent_oid       oid          PRIMARY KEY,
    parent_schema    text         NOT NULL,
    parent_table     text         NOT NULL,
    history_schema   text         NOT NULL,
    history_table    text         NOT NULL,
    trigger_funktion text,        -- NULL if skapa_historik_qa returned false
    created_at       timestamptz  NOT NULL DEFAULT now()
);

ALTER TABLE public.hex_metadata OWNER TO gis_admin;

-- Allow any authenticated user to manage their own metadata entries.
-- All writes come from event trigger functions that run in the calling
-- user's security context, so PUBLIC access is required.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hex_metadata TO PUBLIC;

COMMENT ON TABLE public.hex_metadata IS
    'OID → history table + QA trigger mapping for all Hex-managed tables.
     OIDs are stable through ALTER TABLE RENAME TO, making this the
     authoritative source for cleanup and rename propagation.';

COMMENT ON COLUMN public.hex_metadata.parent_oid IS
    'pg_class.oid of the parent table. Stable through renames.';
COMMENT ON COLUMN public.hex_metadata.history_table IS
    'Actual name of the history table as stored in pg_class (may differ
     from parent_table||''_h'' when the parent name is 62+ characters
     and PostgreSQL truncates the identifier to 63 bytes).';
COMMENT ON COLUMN public.hex_metadata.trigger_funktion IS
    'Name of the QA trigger function (trg_fn_<original_name>_qa).
     Does NOT change when the parent table is renamed.';
