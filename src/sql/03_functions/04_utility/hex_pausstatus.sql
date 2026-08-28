-- Returtypen har fått kolumnerna pausmarkor och radtriggers_pa_trots_paus.
-- CREATE OR REPLACE kan inte ändra en RETURNS TABLE-signatur, så funktionen
-- måste droppas först. Samma mönster som i hex_validera_geometri.sql.
DROP FUNCTION IF EXISTS public.hex_pausstatus();

CREATE OR REPLACE FUNCTION public.hex_pausstatus()
    RETURNS TABLE (
        pausad                   boolean,
        pausmarkor               boolean,
        pausad_sedan             timestamptz,
        pausad_av                text,
        anledning                text,
        pausad_till              timestamptz,
        forfallen                boolean,
        event_triggers_pa        integer,
        event_triggers_av        integer,
        radtriggers_av           integer,
        radtriggers_pa_trots_paus integer,
        avvikelse                text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Rapporterar pausläget och letar efter avvikelser mellan bokföringen i
 * hex_paus och det faktiska läget i katalogerna.
 *
 * VARFÖR AVVIKELSEKONTROLLEN BEHÖVS
 * hex_paus säger vad någon avsåg. pg_event_trigger.evtenabled och
 * pg_trigger.tgenabled säger vad som gäller. De kan glida isär på flera sätt
 * som alla är tysta:
 *
 *   1. En dump bär med sig pausen. pg_dump skriver ut
 *      "ALTER EVENT TRIGGER ... DISABLE" för avstängda triggar, och hex_paus
 *      är en vanlig tabell som också följer med. En dump tagen under paus
 *      läses alltså in som pausad – korrekt, men lätt att missa.
 *   2. En ominstallation nollställer avstängningen. Filerna i
 *      src/sql/04_triggers/ gör DROP + CREATE EVENT TRIGGER, vilket ger en
 *      påslagen trigger medan hex_paus-raden ligger kvar.
 *   3. En återläsning raderar bokföringen. pg_restore --clean droppar tabellen
 *      hex_paus och skapar om event-triggarna påslagna. Kvar blir en databas
 *      som ser opausad och felfri ut, mitt i den återläsning pausen skulle
 *      skydda. Pausmarkören (hex_pausmarkor()) ligger utanför objektgrafen
 *      och överlever – finns den utan hex_paus-rad är det det som hänt.
 *   4. Radtriggers slås på bakom pausens rygg. hex_underhall() och en
 *      ominstallation skapar om triggers, och en nyskapad trigger är alltid
 *      påslagen. Bokföringen säger fortfarande att de är avstängda.
 *   5. Någon har kört ALTER EVENT TRIGGER för hand.
 *
 * KOLUMNERNA
 *   pausad                    Finns en rad i hex_paus.
 *   pausmarkor                Är databasinställningen "hex.paus" satt.
 *   forfallen                 pausad_till har passerat.
 *   radtriggers_av            Antal avstängda icke-interna radtriggers i
 *                             Hex-scheman. NULL betyder "kunde inte räkna".
 *   radtriggers_pa_trots_paus Antal radtriggers som pausen stängde av men som
 *                             är påslagna nu. NULL när Hex inte är pausat.
 *   avvikelse                 NULL när allt hänger ihop, annars en beskrivning.
 *
 * Funktionen är läsbar för alla och kräver inte superanvändare. Poängen är
 * att en glömd eller raderad paus ska gå att upptäcka från en övervakningsfråga:
 *
 *   SELECT * FROM hex_pausstatus() WHERE pausad OR avvikelse IS NOT NULL;
 ******************************************************************************/
DECLARE
    paus        record;
    ev_pa       integer;
    ev_av       integer;
    rad_av      integer;
    rad_pa      integer;
    hex_rad_av  integer;
    markor      text;
    avvik       text[] := ARRAY[]::text[];
    regex       text;
BEGIN
    SELECT * INTO paus FROM public.hex_paus;
    pausad     := FOUND;
    markor     := public.hex_pausmarkor();
    pausmarkor := markor IS NOT NULL;

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

    -- NULL-regex matchar ingenting, vilket hade gett rad_av = 0 och sett ut som
    -- "inga avstängda radtriggers". Skilj på "räknade till noll" och "kunde inte
    -- räkna" – annars är den lugnande nollan en lögn.
    IF regex IS NULL THEN
        rad_av     := NULL;
        hex_rad_av := NULL;
        -- ::text behövs. Utan den är "text[] || literal" tvetydig och
        -- PostgreSQL väljer array || array, vilket ger "malformed array literal".
        -- Övriga tillägg nedan går genom format() och har därför redan typen.
        avvik  := avvik || ('hex_schema_regex() gav NULL – '
                            'hex_standardiserade_skyddsnivaer är tom, så radtriggers '
                            'går inte att räkna. Kolumnen radtriggers_av är därför '
                            'NULL, inte noll.')::text;
    ELSE
        -- radtriggers_av räknar allt: det är ett faktapåstående om databasen.
        -- hex_rad_av räknar bara Hex egna triggers, och det är den som får
        -- larma. En trigger som någon annan äger och medvetet stängt av är
        -- inte Hex ensak, och en permanent falsklarm i övervakningsfrågan gör
        -- att ingen läser den.
        SELECT
            count(*),
            count(*) FILTER (
                WHERE tg.tgname LIKE 'hex\_%' OR tg.tgname LIKE 'trg\_%\_qa'
            )
        INTO rad_av, hex_rad_av
        FROM pg_trigger   tg
        JOIN pg_class     c ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT tg.tgisinternal
          AND c.relkind IN ('r', 'p', 'f')
          AND n.nspname ~ regex
          AND tg.tgenabled = 'D';
    END IF;

    event_triggers_pa := ev_pa;
    event_triggers_av := ev_av;
    radtriggers_av    := rad_av;

    IF pausad THEN
        pausad_sedan := paus.pausad_sedan;
        pausad_av    := paus.pausad_av;
        anledning    := paus.anledning;
        pausad_till  := paus.pausad_till;
        forfallen    := paus.pausad_till IS NOT NULL AND paus.pausad_till < now();

        -- Radtriggers som pausen stängde av men som är påslagna nu.
        --
        -- Att bara räkna avstängda radtriggers (radtriggers_av) svarar på fel
        -- fråga under en paus. Efter en uppgradering eller ett hex_underhall()
        -- mitt i pausen är triggarna omskapade och påslagna, och då visar
        -- radtriggers_av en liten lugnande siffra som inte betyder någonting.
        -- Jämförelsen mot tidigare_lage är den som säger om pausen faktiskt
        -- håller.
        SELECT count(*)
        INTO rad_pa
        FROM   jsonb_array_elements(paus.tidigare_lage -> 'radtriggers') AS post
        JOIN   pg_class     c ON c.relname   = post ->> 'tabell'
        JOIN   pg_namespace n ON n.oid       = c.relnamespace
                             AND n.nspname   = post ->> 'schema'
        JOIN   pg_trigger   tg ON tg.tgrelid = c.oid
                             AND tg.tgname   = post ->> 'namn'
        WHERE  (post ->> 'lage') <> 'D'    -- pausen stängde av den
          AND  tg.tgenabled      <> 'D';   -- men den är på igen

        radtriggers_pa_trots_paus := rad_pa;

        IF ev_pa > 0 THEN
            avvik := avvik || format(
                '%s event-trigger(s) är påslagna trots att hex_paus säger pausat '
                '– troligen en ominstallation som gjorde DROP + CREATE EVENT TRIGGER. '
                'Kör hex_ateruppta() för att städa bort bokföringen.', ev_pa);
        END IF;

        IF rad_pa > 0 THEN
            avvik := avvik || format(
                '%s radtrigger(s) som pausen stängde av är påslagna igen – troligen '
                'omskapade av hex_underhall() eller en ominstallation. Pausen håller '
                'alltså inte fullt ut. Kör hex_ateruppta() när återläsningen är klar.',
                rad_pa);
        END IF;

        IF NOT pausmarkor THEN
            avvik := avvik || ('Ingen pausmarkör satt trots rad i hex_paus. Raden '
                               'kommer sannolikt från en dump av en pausad databas, '
                               'eller från en paus tagen före markören fanns.')::text;
        END IF;

        IF forfallen THEN
            avvik := avvik || format(
                'Pausen skulle ha hävts %s. Kör hex_ateruppta().', paus.pausad_till);
        END IF;
    ELSE
        forfallen                 := false;
        radtriggers_pa_trots_paus := NULL;

        -- Det tysta läget som gav den här kolumnen dess existensberättigande:
        -- markören står kvar men tabellen är tom. hex_paus droppades av en
        -- pg_restore --clean, och utan markören hade allt sett friskt ut.
        IF pausmarkor THEN
            avvik := avvik || format(
                'Pausmarkör satt sedan %s, men hex_paus är tom. En återläsning '
                '(pg_restore --clean) har droppat tabellen, och lägena före pausen '
                'gick förlorade med den. Kör hex_ateruppta(): den kör underhållet '
                'som bygger upp roller, rättigheter och GeoServer-uppsättning igen, '
                'och redovisar vad som fortfarande står avstängt.', markor);
        END IF;

        IF ev_av > 0 THEN
            avvik := avvik || format(
                '%s event-trigger(s) är avstängda utan att Hex är pausat. '
                'Kan komma från en dump tagen under paus, eller från ett manuellt '
                'ALTER EVENT TRIGGER. Slå på dem med '
                'ALTER EVENT TRIGGER <namn> ENABLE.', ev_av);
        END IF;

        IF coalesce(hex_rad_av, 0) > 0 THEN
            avvik := avvik || format(
                '%s av Hex egna radtrigger(s) är avstängda utan att Hex är '
                'pausat. Historik och QA-kolumner uppdateras inte för dessa tabeller.',
                hex_rad_av);
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
     läget i pg_event_trigger och pg_trigger, samt med pausmarkören. Kolumnen
     avvikelse är NULL när allt hänger ihop. Fångar bland annat att en
     pg_restore --clean raderat hex_paus och att radtriggers slagits på bakom
     pausens rygg. Kräver inte superanvändare – avsedd för övervakning:
     SELECT * FROM hex_pausstatus() WHERE pausad OR avvikelse IS NOT NULL;';
