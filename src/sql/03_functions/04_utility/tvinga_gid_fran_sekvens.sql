CREATE OR REPLACE FUNCTION public.tvinga_gid_fran_sekvens()
    RETURNS trigger
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Åsidosätter alltid klientens gid med nästa sekvensvärde.
 *
 * QGIS (och många andra klienter) använder OVERRIDING SYSTEM VALUE när de
 * infogar i tabeller med GENERATED ALWAYS AS IDENTITY-kolumner. Det gör att
 * PostgreSQL accepterar klientens gid-värde trots identity-definitionen.
 *
 * Denna BEFORE INSERT-trigger fångar upp raden innan den skrivs och ersätter
 * NEW.gid med nästa värde från kolumnens sekvens – oavsett vad klienten
 * skickade. Klientens värde kastas tyst.
 *
 * Effekten är att sekvensen alltid är den enda källan till gid-värden.
 * En klient som skickar gid=100 får raden tillbaka med gid=3 om det är
 * sekvensens nästa värde.
 ******************************************************************************/
DECLARE
    seq_name text;
BEGIN
    seq_name := pg_get_serial_sequence(
        quote_ident(TG_TABLE_SCHEMA) || '.' || quote_ident(TG_TABLE_NAME),
        'gid'
    );

    IF seq_name IS NOT NULL THEN
        NEW.gid := nextval(seq_name);
    END IF;

    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION public.tvinga_gid_fran_sekvens()
    OWNER TO postgres;

COMMENT ON FUNCTION public.tvinga_gid_fran_sekvens()
    IS 'BEFORE INSERT-trigger som alltid åsidosätter klientens gid-värde med
nästa sekvensvärde. Förhindrar att klienter (t.ex. QGIS med OVERRIDING SYSTEM
VALUE) kan välja ett godtyckligt gid. Triggeranropet hex_tvinga_gid skapas
automatiskt av hantera_ny_tabell() på alla Hex-hanterade tabeller.';
