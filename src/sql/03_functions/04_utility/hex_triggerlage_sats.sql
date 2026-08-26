CREATE OR REPLACE FUNCTION public.hex_triggerlage_sats(p_lage text)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
AS $BODY$
/******************************************************************************
 * Översätter en lägeskod från pg_trigger.tgenabled eller
 * pg_event_trigger.evtenabled till motsvarande ALTER-klausul.
 *
 *   O  →  ENABLE          (origin – normalläget)
 *   D  →  DISABLE
 *   R  →  ENABLE REPLICA  (kör bara när session_replication_role = replica)
 *   A  →  ENABLE ALWAYS   (kör oavsett session_replication_role)
 *
 * Klausulen passar båda satsformerna, eftersom triggernamnet står efter
 * klausulen i tabellvarianten:
 *
 *   ALTER TABLE s.t ENABLE REPLICA TRIGGER g
 *   ALTER EVENT TRIGGER e ENABLE REPLICA
 *
 * Returvärdet är ett nyckelord, inte en identifierare, och kan därför inte
 * skickas genom %I. Whitelistningen är det som gör det säkert att interpolera
 * med %s: en lägeskod som inte är exakt en av de fyra kända kastar fel i
 * stället för att nå EXECUTE.
 *
 * ANVÄNDS AV: hex_ateruppta()
 ******************************************************************************/
DECLARE
    sats text;
BEGIN
    sats := CASE p_lage
        WHEN 'O' THEN 'ENABLE'
        WHEN 'D' THEN 'DISABLE'
        WHEN 'R' THEN 'ENABLE REPLICA'
        WHEN 'A' THEN 'ENABLE ALWAYS'
        ELSE NULL
    END;

    IF sats IS NULL THEN
        RAISE EXCEPTION '[hex_triggerlage_sats] Okänd lägeskod: %', coalesce(p_lage, 'NULL')
            USING HINT = 'Giltiga koder är O (enable), D (disable), R (replica) '
                         'och A (always) – se pg_trigger.tgenabled och '
                         'pg_event_trigger.evtenabled.';
    END IF;

    RETURN sats;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_triggerlage_sats(text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_triggerlage_sats(text) IS
    'Översätter lägeskoderna O/D/R/A från pg_trigger.tgenabled och
     pg_event_trigger.evtenabled till ALTER-klausulerna ENABLE, DISABLE,
     ENABLE REPLICA och ENABLE ALWAYS. Whitelistning – en okänd kod kastar fel
     i stället för att nå EXECUTE. Används av hex_ateruppta().';
