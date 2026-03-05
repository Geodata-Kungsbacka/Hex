-- FUNCTION: public.kontrollera_geometri_trigger()

-- DROP FUNCTION IF EXISTS public.kontrollera_geometri_trigger();

CREATE OR REPLACE FUNCTION public.kontrollera_geometri_trigger()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * BEFORE INSERT OR UPDATE trigger som ger meningsfulla felmeddelanden när
 * ogiltig geometri sparas i _kba_-tabeller.
 *
 * Triggernamn på varje tabell: hex_kontrollera_geom
 *
 * Avfyras INNAN CHECK-constrainten validera_geom_<tabell> utvärderas.
 * Det innebär att QGIS och andra klienter ser en förklaring av vad som
 * är fel med geometrin, snarare än det generiska:
 *   "new row for relation … violates check constraint"
 *
 * Triggern installeras automatiskt av hantera_ny_tabell() och
 * hantera_kolumntillagg() på alla _kba_-tabeller med geometrikolumn (geom).
 ******************************************************************************/
DECLARE
    fel text;
BEGIN
    fel := public.forklara_geometrifel(NEW.geom);
    IF fel IS NOT NULL THEN
        RAISE EXCEPTION 'Ogiltig geometri i tabellen "%": %',
            TG_TABLE_NAME, fel
            USING HINT = 'Rätta geometrin i QGIS: Vektor → Geometriverktyg → Fixa geometrier, eller rita om objektet.';
    END IF;
    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION public.kontrollera_geometri_trigger()
    OWNER TO postgres;

COMMENT ON FUNCTION public.kontrollera_geometri_trigger()
    IS 'BEFORE INSERT OR UPDATE trigger som avvisar ogiltig geometri med ett läsbart
felmeddelande. Installeras automatiskt av Hex på alla _kba_-tabeller med geometrikolumn.
Avfyras före CHECK-constrainten validera_geom_<tabell> för att ge QGIS-användare en
tydlig förklaring av felet. Triggernamn per tabell: hex_kontrollera_geom.';
