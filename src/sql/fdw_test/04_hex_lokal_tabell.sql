-------------------------------------------------------------------------------
-- STEG 4: Skapa den lokala "Hex-liknande" tabellen + historik
--
-- Kör detta mot: fdw_test_hex
--
-- I produktion skapar Hex allt detta automatiskt via event triggers.
-- Här bygger vi det manuellt för att testa mekaniken.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- 4a. Lokal trädtabell med revisionskolumner (som Hex skulle skapa)
-------------------------------------------------------------------------------
CREATE TABLE public.trad_p (
    gid                 integer PRIMARY KEY,
    art                 text,
    stamdiameter        integer,
    skick               text,
    notering            text,
    skapad_av           text        DEFAULT session_user,
    skapad_tidpunkt     timestamptz DEFAULT now(),
    andrad_av           text,
    andrad_tidpunkt     timestamptz,
    geom                geometry(Point, 3007)
);

-------------------------------------------------------------------------------
-- 4b. Historiktabell (som Hex:s skapa_historik_qa() skapar)
-------------------------------------------------------------------------------
CREATE TABLE public.trad_p_h (
    h_typ               char(1) NOT NULL CHECK (h_typ IN ('U', 'D')),
    h_tidpunkt          timestamptz NOT NULL DEFAULT now(),
    h_av                text NOT NULL DEFAULT session_user,
    gid                 integer,
    art                 text,
    stamdiameter        integer,
    skick               text,
    notering            text,
    skapad_av           text,
    skapad_tidpunkt     timestamptz,
    andrad_av           text,
    andrad_tidpunkt     timestamptz,
    geom                geometry(Point, 3007)
);

CREATE INDEX trad_p_h_gid_tid_idx
    ON public.trad_p_h (gid, h_tidpunkt DESC);

-------------------------------------------------------------------------------
-- 4c. QA-trigger (som Hex:s trg_fn_{tabell}_qa)
--     Uppdaterar andrad_av/andrad_tidpunkt + kopierar gamla raden till _h
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_fn_trad_p_qa()
RETURNS TRIGGER AS $$
DECLARE
    rad public.trad_p%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        rad := NEW;
        rad.andrad_tidpunkt := now();
        rad.andrad_av := session_user;

        -- Spara den GAMLA raden i historik
        INSERT INTO public.trad_p_h
            (h_typ, h_tidpunkt, h_av,
             gid, art, stamdiameter, skick, notering,
             skapad_av, skapad_tidpunkt, andrad_av, andrad_tidpunkt, geom)
        SELECT 'U', now(), session_user,
             (OLD).gid, (OLD).art, (OLD).stamdiameter, (OLD).skick, (OLD).notering,
             (OLD).skapad_av, (OLD).skapad_tidpunkt, (OLD).andrad_av, (OLD).andrad_tidpunkt, (OLD).geom;

        RETURN rad;

    ELSIF TG_OP = 'DELETE' THEN
        rad := OLD;
        rad.andrad_tidpunkt := now();
        rad.andrad_av := session_user;

        INSERT INTO public.trad_p_h
            (h_typ, h_tidpunkt, h_av,
             gid, art, stamdiameter, skick, notering,
             skapad_av, skapad_tidpunkt, andrad_av, andrad_tidpunkt, geom)
        SELECT 'D', now(), session_user,
             (rad).gid, (rad).art, (rad).stamdiameter, (rad).skick, (rad).notering,
             (rad).skapad_av, (rad).skapad_tidpunkt, (rad).andrad_av, (rad).andrad_tidpunkt, (rad).geom;

        RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trad_p_qa
    BEFORE UPDATE OR DELETE ON public.trad_p
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_fn_trad_p_qa();
