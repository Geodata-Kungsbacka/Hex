CREATE OR REPLACE FUNCTION public.hex_pausmarkor()
    RETURNS text
    LANGUAGE sql
    STABLE
AS $BODY$
/******************************************************************************
 * Läser pausmarkören – den kopia av pausläget som en återläsning inte kommer åt.
 *
 * VARFÖR MARKÖREN FINNS
 * hex_paus är en vanlig tabell i public. Det gör den synlig och lätt att
 * felsöka, men också åtkomlig för pg_restore:
 *
 *   pg_restore --clean  ->  DROP TABLE public.hex_paus  ->  bokföringen borta
 *
 * Efter en sådan återläsning står Hex igång (dumpens event-triggers skapas om
 * påslagna) med en tom hex_paus. hex_pausstatus() såg då "inte pausat, inga
 * avvikelser" och hex_ateruppta() svarade "ingenting att göra" – trots att
 * pausen var raderad mitt under den återläsning den skulle skydda.
 *
 * Markören är samma besked lagt utanför databasens objektgraf:
 *
 *   ALTER DATABASE <db> SET "hex.paus" = '<tidpunkt>'
 *
 * Den ligger i pg_db_role_setting, som hör till databasobjektet och inte till
 * innehållet. pg_restore --clean rör den inte, och en pg_dump utan --create
 * bär inte med sig den. Överlever markören medan hex_paus försvann är det
 * kvittot på att en återläsning tog bokföringen.
 *
 * VARFÖR pg_db_role_setting OCH INTE current_setting()
 * ALTER DATABASE ... SET slår igenom först i nya sessioner. Sessionen som
 * körde hex_pausa() ser alltså inte sitt eget värde via current_setting().
 * Uppslaget går därför direkt mot katalogen och gäller omedelbart.
 *
 * setrole = 0 betyder "gäller databasen, oavsett roll" – det är raden
 * ALTER DATABASE ... SET skriver. Rollspecifika rader (ALTER ROLE ... IN
 * DATABASE) har setrole <> 0 och ska inte räknas.
 *
 * Värdet är pausad_sedan som text. Innehållet används bara för att kunna
 * skriva ut när pausen började när hex_paus-raden är borta; det är själva
 * existensen som bär informationen.
 *
 * RETURVÄRDE
 *   Markörens värde, eller NULL när ingen markör är satt.
 *
 * SKRIVS AV:  hex_pausa()      – ALTER DATABASE ... SET "hex.paus"
 * RENSAS AV:  hex_ateruppta()  – ALTER DATABASE ... RESET "hex.paus"
 * LÄSES AV:   hex_pausstatus(), hex_ateruppta()
 ******************************************************************************/
    -- substr i stället för split_part: värdet får innehålla '=' utan att
    -- klippas. Posterna i setconfig har formen 'namn=värde'.
    SELECT substr(post, length('hex.paus') + 2)
    FROM   pg_db_role_setting r
    CROSS  JOIN LATERAL unnest(r.setconfig) AS post
    WHERE  r.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND  r.setrole = 0
      AND  post LIKE 'hex.paus=%'
    LIMIT  1;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_pausmarkor() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_pausmarkor() IS
    'Läser pausmarkören ALTER DATABASE ... SET "hex.paus" ur pg_db_role_setting.
     Markören ligger utanför databasens objektgraf och överlever därför
     pg_restore --clean, som droppar tabellen hex_paus. Finns markören men
     ingen hex_paus-rad har en återläsning raderat bokföringen.
     Returnerar NULL när ingen markör är satt.';
