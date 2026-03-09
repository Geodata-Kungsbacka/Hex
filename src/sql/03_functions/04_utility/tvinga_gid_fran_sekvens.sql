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
    seq_curr bigint;
BEGIN
    seq_name := pg_get_serial_sequence(
        quote_ident(TG_TABLE_SCHEMA) || '.' || quote_ident(TG_TABLE_NAME),
        'gid'
    );

    IF seq_name IS NOT NULL THEN
        -- For a normal INSERT, the identity mechanism calls nextval() before this
        -- trigger fires and sets NEW.gid to that value. currval() will match NEW.gid.
        --
        -- For OVERRIDING SYSTEM VALUE (e.g. QGIS), the identity mechanism does NOT
        -- call nextval() – the client's value is placed directly in NEW.gid.
        -- currval() will therefore NOT match NEW.gid, and we override it.
        BEGIN
            seq_curr := currval(seq_name);
            IF seq_curr IS DISTINCT FROM NEW.gid THEN
                NEW.gid := nextval(seq_name);
            END IF;
        EXCEPTION WHEN object_not_in_prerequisite_state THEN
            -- nextval() has never been called in this session for this sequence.
            -- For a normal INSERT, the identity mechanism would have called nextval()
            -- (which makes currval() available), so reaching this handler proves
            -- the identity mechanism did NOT advance the sequence – meaning the
            -- client used OVERRIDING SYSTEM VALUE. Replace the client's value.
            NEW.gid := nextval(seq_name);
        END;
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
