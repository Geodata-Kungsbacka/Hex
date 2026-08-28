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
 * sekvensens nästa värde. Det gäller även när samma gid upprepas över flera
 * rader i en och samma INSERT.
 *
 * HUR KLIENTVÄRDEN KÄNNS IGEN
 * För en vanlig INSERT anropar identity-mekanismen nextval() strax före denna
 * trigger, så currval() = NEW.gid. För OVERRIDING SYSTEM VALUE anropas
 * nextval() inte alls – klientens värde hamnar direkt i NEW.gid, och currval()
 * ligger kvar på värdet från förra raden.
 *
 * currval() ensamt räcker dock inte. Skickar klienten samma gid för flera
 * rader sammanfaller värdet med currval från och med rad två:
 *
 *   INSERT ... OVERRIDING SYSTEM VALUE VALUES (1,'x'),(1,'y'),(1,'z')
 *
 * Rad 1 får gid 1 ur sekvensen; för rad 2 är då currval = 1 = klientens värde,
 * och en ren currval-jämförelse skulle behålla ettan. Därför jämförs också med
 * sekvenspositionen vid triggerns FÖRRA avfyrning, sparad per tabell i en
 * sessionsvariabel. Har sekvensen inte rört sig sedan dess kan identity-
 * mekanismen inte ha kört för den här raden – alltså är värdet klientens.
 *
 * Sessionsvariabeln cachar även sekvensnamnet, så att pg_get_serial_sequence()
 * bara slås upp en gång per session och tabell. Cachen nycklas på TG_RELID och
 * återuppbyggs automatiskt om sekvensen bytt namn (uppdatera_sekvensnamn).
 ******************************************************************************/
DECLARE
    guc_namn  text;
    cache     text;
    avdelare  integer;
    seq_namn  text;
    seq_curr  bigint;
    seq_forra bigint;   -- sekvenspositionen vid triggerns förra avfyrning
BEGIN
    guc_namn := 'hex.gid_' || TG_RELID::text;
    cache    := current_setting(guc_namn, true);

    IF cache IS NULL OR cache = '' THEN
        -- Första avfyrningen i sessionen för denna tabell.
        seq_namn  := pg_get_serial_sequence(
            quote_ident(TG_TABLE_SCHEMA) || '.' || quote_ident(TG_TABLE_NAME),
            'gid'
        );
        seq_forra := NULL;
    ELSE
        avdelare  := strpos(cache, '|');
        seq_namn  := left(cache, avdelare - 1);
        seq_forra := substr(cache, avdelare + 1)::bigint;
    END IF;

    -- Tabellen saknar sekvens (ingen IDENTITY på gid) – inget att göra.
    IF seq_namn IS NULL THEN
        RETURN NEW;
    END IF;

    BEGIN
        seq_curr := currval(seq_namn);
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            -- nextval() har aldrig anropats för sekvensen i denna session.
            -- För en vanlig INSERT hade identity-mekanismen gjort det, så
            -- klienten måste ha använt OVERRIDING SYSTEM VALUE.
            seq_curr := NULL;
        WHEN undefined_table THEN
            -- Det cachade sekvensnamnet är inaktuellt (sekvensen har döpts om
            -- av uppdatera_sekvensnamn under sessionens gång). Slå upp på nytt.
            seq_namn := pg_get_serial_sequence(
                quote_ident(TG_TABLE_SCHEMA) || '.' || quote_ident(TG_TABLE_NAME),
                'gid'
            );
            IF seq_namn IS NULL THEN
                RETURN NEW;
            END IF;
            seq_curr  := NULL;
            seq_forra := NULL;
    END;

    IF seq_curr IS NULL                        -- identity-mekanismen har inte kört
       OR seq_curr IS DISTINCT FROM NEW.gid    -- värdet kommer inte från sekvensen
       OR seq_curr = seq_forra                 -- sekvensen står still → klientvärde
    THEN
        NEW.gid := nextval(seq_namn);
    END IF;

    -- Efter beslutet gäller alltid NEW.gid = sekvensens aktuella position,
    -- så NEW.gid är det värde nästa avfyrning ska jämföra mot.
    PERFORM set_config(guc_namn, seq_namn || '|' || NEW.gid::text, false);

    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION public.tvinga_gid_fran_sekvens()
    OWNER TO postgres;

COMMENT ON FUNCTION public.tvinga_gid_fran_sekvens()
    IS 'BEFORE INSERT-trigger som alltid åsidosätter klientens gid-värde med
nästa sekvensvärde. Förhindrar att klienter (t.ex. QGIS med OVERRIDING SYSTEM
VALUE) kan välja ett godtyckligt gid, även när samma gid upprepas över flera
rader i samma INSERT. Triggeranropet hex_tvinga_gid skapas automatiskt av
hantera_ny_tabell() på alla Hex-hanterade tabeller.';
