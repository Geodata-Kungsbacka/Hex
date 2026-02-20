-------------------------------------------------------------------------------
-- STEG 5: Sync-funktionen (upsert från foreign table → lokal tabell)
--
-- Kör detta mot: fdw_test_hex
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sync_trad_fran_dbsync()
RETURNS TABLE (
    insatta     integer,
    uppdaterade integer,
    borttagna   integer
) LANGUAGE plpgsql AS $$
DECLARE
    v_insatta     integer := 0;
    v_uppdaterade integer := 0;
    v_borttagna   integer := 0;
BEGIN
    ---------------------------------------------------------------------------
    -- 1. UPSERT: Nya + ändrade rader
    --    INSERT → skapad_av/skapad_tidpunkt sätts via DEFAULT
    --    UPDATE → QA-triggern sätter andrad_av/andrad_tidpunkt + skriver _h
    ---------------------------------------------------------------------------
    WITH upsert AS (
        INSERT INTO public.trad_p (gid, art, stamdiameter, skick, notering, geom)
        SELECT fid, art, stamdiameter, skick, notering, geom
        FROM dbsync_staging.trad_p
        ON CONFLICT (gid) DO UPDATE
        SET
            art          = EXCLUDED.art,
            stamdiameter = EXCLUDED.stamdiameter,
            skick        = EXCLUDED.skick,
            notering     = EXCLUDED.notering,
            geom         = EXCLUDED.geom
        WHERE
            -- Uppdatera bara om något faktiskt ändrats (undviker onödiga _h-rader)
            trad_p.art          IS DISTINCT FROM EXCLUDED.art
            OR trad_p.stamdiameter IS DISTINCT FROM EXCLUDED.stamdiameter
            OR trad_p.skick        IS DISTINCT FROM EXCLUDED.skick
            OR trad_p.notering     IS DISTINCT FROM EXCLUDED.notering
            OR NOT ST_Equals(trad_p.geom, EXCLUDED.geom)
        RETURNING
            xmax  -- xmax = 0 → INSERT, xmax > 0 → UPDATE
    )
    SELECT
        count(*) FILTER (WHERE xmax = 0),
        count(*) FILTER (WHERE xmax > 0)
    INTO v_insatta, v_uppdaterade
    FROM upsert;

    ---------------------------------------------------------------------------
    -- 2. DELETE: Rader som inte längre finns i db-sync
    --    QA-triggern skriver 'D'-rad till _h
    ---------------------------------------------------------------------------
    WITH borttagna AS (
        DELETE FROM public.trad_p
        WHERE gid NOT IN (SELECT fid FROM dbsync_staging.trad_p)
        RETURNING gid
    )
    SELECT count(*) INTO v_borttagna FROM borttagna;

    ---------------------------------------------------------------------------
    -- 3. Rapportera
    ---------------------------------------------------------------------------
    RAISE NOTICE 'Sync klar: % insatta, % uppdaterade, % borttagna',
        v_insatta, v_uppdaterade, v_borttagna;

    RETURN QUERY SELECT v_insatta, v_uppdaterade, v_borttagna;
END;
$$;
