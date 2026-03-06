-- FUNCTION: public.ta_bort_dummy_rad()

CREATE OR REPLACE FUNCTION public.ta_bort_dummy_rad()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
/******************************************************************************
 * AFTER INSERT trigger som automatiskt tar bort dummy-geometriraden när den
 * första riktiga raden läggs till i en geometritabell.
 *
 * Triggernamn på varje tabell: hex_ta_bort_dummy
 * Installeras av: lagg_till_dummy_geometri()
 *
 * Flöde:
 *   1. Om hex_dummy_geometrier inte har poster för denna tabell – gör ingenting.
 *   2. Om den nyinsatta raden ÄR en dummy (gid finns i hex_dummy_geometrier) –
 *      gör ingenting (skyddar mot att triggern avfyras på sin egen dummy-insert).
 *   3. Annars: ta bort alla dummy-rader ur tabellen och rensa hex_dummy_geometrier.
 *
 * OBS: Om tabellen har en QA-trigger (trg_*_qa) kommer DELETE av dummy-raden
 * att skapa en 'D'-post i historiktabellen. Detta är acceptabelt systembrus –
 * posten är identifierbar via gid och tidpunkt.
 ******************************************************************************/
DECLARE
    schema_n  text   := TG_TABLE_SCHEMA;
    tabell_n  text   := TG_TABLE_NAME;
    dummy_gid bigint;
BEGIN
    -- Snabbkontroll: finns det ens en dummy för denna tabell?
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = schema_n AND tabell_namn = tabell_n
    ) THEN
        RETURN NEW;
    END IF;

    -- Är det dummy-raden SJÄLV som precis infogades? (skyddar mot rekursion)
    IF EXISTS (
        SELECT 1 FROM public.hex_dummy_geometrier
        WHERE schema_namn = schema_n
          AND tabell_namn = tabell_n
          AND gid = NEW.gid
    ) THEN
        RETURN NEW;
    END IF;

    -- En riktig rad har anlänt – ta bort dummy-rader
    FOR dummy_gid IN
        SELECT gid FROM public.hex_dummy_geometrier
        WHERE schema_namn = schema_n AND tabell_namn = tabell_n
    LOOP
        EXECUTE format(
            'DELETE FROM %I.%I WHERE gid = $1',
            schema_n, tabell_n
        ) USING dummy_gid;

        DELETE FROM public.hex_dummy_geometrier
        WHERE schema_namn = schema_n
          AND tabell_namn = tabell_n
          AND gid = dummy_gid;

        RAISE NOTICE '[ta_bort_dummy_rad] ✓ Dummy-rad borttagen ur %.% (gid: %)',
            schema_n, tabell_n, dummy_gid;
    END LOOP;

    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION public.ta_bort_dummy_rad()
    OWNER TO postgres;

COMMENT ON FUNCTION public.ta_bort_dummy_rad()
    IS 'AFTER INSERT trigger som tar bort Hex-dummy-geometriraden när den första
riktiga raden läggs in i en geometritabell. Installeras automatiskt av
lagg_till_dummy_geometri() via hantera_ny_tabell() och hantera_kolumntillagg().
Triggernamn per tabell: hex_ta_bort_dummy. Triggern är harmlös efter att dummyn
tagits bort (hex_dummy_geometrier tom → tidig retur utan åtgärd).';
