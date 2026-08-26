CREATE OR REPLACE FUNCTION public.hex_pausstatus()
    RETURNS TABLE (
        pausad             boolean,
        pausad_sedan       timestamptz,
        pausad_av          text,
        anledning          text,
        pausad_till        timestamptz,
        forfallen          boolean,
        event_triggers_pa  integer,
        event_triggers_av  integer,
        radtriggers_av     integer,
        avvikelse          text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Rapporterar pausläget och letar efter avvikelser mellan bokföringen i
 * hex_paus och det faktiska läget i katalogerna.
 *
 * VARFÖR AVVIKELSEKONTROLLEN BEHÖVS
 * hex_paus säger vad någon avsåg. pg_event_trigger.evtenabled säger vad som
 * gäller. De kan glida isär på tre sätt som alla är tysta:
 *
 *   1. En dump bär med sig pausen. pg_dump skriver ut
 *      "ALTER EVENT TRIGGER ... DISABLE" för avstängda triggar, och hex_paus
 *      är en vanlig tabell som också följer med. En dump tagen under paus
 *      läses alltså in som pausad – korrekt, men lätt att missa.
 *   2. En ominstallation nollställer avstängningen. Filerna i
 *      src/sql/04_triggers/ gör DROP + CREATE EVENT TRIGGER, vilket ger en
 *      påslagen trigger medan hex_paus-raden ligger kvar.
 *   3. Någon har kört ALTER EVENT TRIGGER för hand.
 *
 * Kolumnen avvikelse är NULL när allt hänger ihop, annars en beskrivning.
 * Kolumnen forfallen är true när pausad_till har passerat – gränsen som
 * hex_pausa() satte via p_max_timmar.
 *
 * Funktionen är läsbar för alla och kräver inte superanvändare. Poängen är
 * att en glömd paus ska gå att upptäcka från en övervakningsfråga:
 *
 *   SELECT * FROM hex_pausstatus() WHERE pausad OR avvikelse IS NOT NULL;
 ******************************************************************************/
DECLARE
    paus        record;
    ev_pa       integer;
    ev_av       integer;
    rad_av      integer;
    avvik       text[] := ARRAY[]::text[];
    regex       text;
BEGIN
    SELECT * INTO paus FROM public.hex_paus;
    pausad := FOUND;

    -- Faktiskt läge i katalogerna. Urvalet går på funktionen, precis som i
    -- hex_pausa(), så att omdöpta event-triggers räknas med.
    SELECT
        count(*) FILTER (WHERE et.evtenabled <> 'D'),
        count(*) FILTER (WHERE et.evtenabled  = 'D')
    INTO ev_pa, ev_av
    FROM pg_event_trigger et
    JOIN pg_proc          p ON p.oid = et.evtfoid
    JOIN pg_namespace     n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'hex\_%';

    regex := public.hex_schema_regex();

    SELECT count(*)
    INTO rad_av
    FROM pg_trigger   tg
    JOIN pg_class     c ON c.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT tg.tgisinternal
      AND c.relkind IN ('r', 'p')
      AND n.nspname ~ regex
      AND tg.tgenabled = 'D';

    event_triggers_pa := ev_pa;
    event_triggers_av := ev_av;
    radtriggers_av    := rad_av;

    IF pausad THEN
        pausad_sedan := paus.pausad_sedan;
        pausad_av    := paus.pausad_av;
        anledning    := paus.anledning;
        pausad_till  := paus.pausad_till;
        forfallen    := paus.pausad_till IS NOT NULL AND paus.pausad_till < now();

        IF ev_pa > 0 THEN
            avvik := avvik || format(
                '%s event-trigger(s) är påslagna trots att hex_paus säger pausat '
                '– troligen en ominstallation som gjorde DROP + CREATE EVENT TRIGGER. '
                'Kör hex_ateruppta() för att städa bort bokföringen.', ev_pa);
        END IF;

        IF forfallen THEN
            avvik := avvik || format(
                'Pausen skulle ha hävts %s. Kör hex_ateruppta().', paus.pausad_till);
        END IF;
    ELSE
        forfallen := false;

        IF ev_av > 0 THEN
            avvik := avvik || format(
                '%s event-trigger(s) är avstängda utan att Hex är pausat. '
                'Kan komma från en dump tagen under paus, eller från ett manuellt '
                'ALTER EVENT TRIGGER. Slå på dem med '
                'ALTER EVENT TRIGGER <namn> ENABLE.', ev_av);
        END IF;

        IF rad_av > 0 THEN
            avvik := avvik || format(
                '%s radtrigger(s) på Hex-tabeller är avstängda utan att Hex är '
                'pausat. Historik och QA-kolumner uppdateras inte för dessa tabeller.',
                rad_av);
        END IF;
    END IF;

    IF array_length(avvik, 1) IS NULL THEN
        avvikelse := NULL;
    ELSE
        avvikelse := array_to_string(avvik, ' | ');
    END IF;

    RETURN NEXT;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_pausstatus() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_pausstatus() IS
    'Rapporterar pausläget och jämför bokföringen i hex_paus med det faktiska
     läget i pg_event_trigger och pg_trigger. Kolumnen avvikelse är NULL när
     allt hänger ihop. Kräver inte superanvändare – avsedd för övervakning:
     SELECT * FROM hex_pausstatus() WHERE pausad OR avvikelse IS NOT NULL;';
