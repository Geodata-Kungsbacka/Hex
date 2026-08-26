CREATE OR REPLACE FUNCTION public.hex_ateruppta(
    p_underhall boolean DEFAULT true
)
    RETURNS TABLE (
        objekt text,
        typ    text,
        atgard text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Återupptar Hex efter en paus.
 *
 * Lägger tillbaka exakt de lägen hex_pausa() sparade i hex_paus.tidigare_lage
 * – inte "allt på". En event-trigger eller radtrigger som var avstängd redan
 * före pausen förblir avstängd.
 *
 * FUNKTIONEN ÄR ALDRIG EN TYST NULLÅTGÄRD
 * Saknas bokföringsraden körs underhållet ändå. Skälet är att raden kan ha
 * försvunnit i just den återläsning den skulle skydda:
 *
 *   pg_restore --clean  ->  DROP TABLE public.hex_paus
 *
 * Efter en sådan körning står Hex igång med tom hex_paus, och den tidigare
 * versionen svarade "Hex är inte pausat – ingenting att göra" och gick hem.
 * hex_underhall() kördes alltså aldrig: rollerna, ägarskapet, rättigheterna
 * och GeoServer-notifieringarna byggdes inte upp igen, och ingenting sade
 * ifrån. Samma sak gäller en återläsning i en tom måldatabas, där det aldrig
 * gick att pausa från början eftersom Hex inte fanns där än.
 *
 * Steget i driftrutinen ska därför alltid utföra reparationen. Finns
 * bokföringen läggs triggerlägena tillbaka först; saknas den körs underhållet
 * ensamt och funktionen redovisar vad som fortfarande står avstängt.
 * p_underhall => false stänger av det för den som medvetet bara vill lägga
 * tillbaka lägena.
 *
 * ORDNING (och varför)
 *   1. Radtriggers återställs först.
 *   2. hex_underhall() körs medan event-triggarna fortfarande är avstängda.
 *      Underhållet gör själv ALTER TABLE och CREATE TRIGGER. Vore
 *      event-triggarna påslagna skulle varje sådan sats gå genom
 *      hex_hantera_ny_kolumn() och riskera att omstrukturera nyss återlästa
 *      tabeller. Underhållet behöver inte event-triggarna: det skapar
 *      triggar, roller och rättigheter med egna satser.
 *   3. Event-triggarna slås på sist.
 *   4. Raden i hex_paus tas bort.
 *
 * VAD hex_underhall() REPARERAR EFTER EN ÅTERLÄSNING
 *   - Roller. r_/w_/gs_-rollerna är globala i klustret och följer inte med i
 *     en pg_dump. Efter återläsning i ett nytt kluster saknas de helt.
 *     Underhållet återskapar dem från hex_standardiserade_roller, som ligger
 *     i databasen och därför följer med dumpen.
 *   - Ägarskap och rättigheter på scheman, tabeller, sekvenser och funktioner.
 *   - Saknade radtriggers på tabeller som pg_restore lagt in utan dem.
 *   - pg_notify till GeoServer-lyssnaren för varje publicerat schema, så att
 *     workspace och datastore ställs om mot den återlästa databasen.
 *
 * OBS om GeoServer-lösenord: saknas en gs_-roll helt i klustret genererar
 * hex_underhall() ett nytt lösenord och skriver över raden i
 * hex_rolluppgifter. Efter en återläsning i ett nytt kluster gäller alltså
 * inte de lösenord som låg i dumpen. Lyssnaren läser hex_rolluppgifter och
 * plockar upp de nya vid notifieringen i steg 2.
 *
 * PARAMETRAR
 *   p_underhall  Kör hex_underhall() som del av återupptagandet. Standard
 *                true. Sätt false bara när pausen inte omgav en återläsning
 *                och ingenting behöver repareras.
 *
 * KRÄVER SUPERANVÄNDARE, av samma skäl som hex_pausa().
 *
 * Idempotent i den meningen att den går att köra om: hex_underhall() är
 * själv idempotent, och triggerlägen som redan ligger rätt sätts om till
 * samma värde.
 ******************************************************************************/
DECLARE
    paus         record;
    har_paus     boolean;
    markor       text;
    post         jsonb;
    r            record;
    antal_ev     integer := 0;
    antal_rad    integer := 0;
    antal_saknas integer := 0;
    antal_kvar   integer := 0;
    underhall    record;
    antal_und    integer := 0;
    sats         text;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Förutsättningar
    -- -------------------------------------------------------------------------
    -- coalesce: saknas raden helt blir uttrycket NULL, och IF NULL är falskt –
    -- vakten hade då släppt igenom i stället för att stoppa.
    IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) THEN
        RAISE EXCEPTION
            '[hex_ateruppta] Kräver superanvändare. Aktuell användare: %', current_user
            USING HINT = 'ALTER EVENT TRIGGER kräver ägarskap, och event-triggers '
                         'kan bara ägas av en superanvändare. Kör som postgres.';
    END IF;

    SELECT * INTO paus FROM public.hex_paus;
    har_paus := FOUND;
    markor   := public.hex_pausmarkor();

    RAISE NOTICE '[hex_ateruppta] === START ===';

    IF har_paus THEN
        RAISE NOTICE '[hex_ateruppta] Pausad sedan % av % (%)',
            paus.pausad_sedan, paus.pausad_av,
            coalesce(paus.anledning, 'ingen anledning angiven');

        IF markor IS NULL THEN
            -- Raden finns men markören saknas. Vanligast är att raden kommit
            -- med i en dump från en pausad källa: innehållet följde med,
            -- databasinställningen gjorde det inte.
            RAISE NOTICE '[hex_ateruppta] Ingen pausmarkör satt. Raden i hex_paus '
                         'kommer sannolikt från en dump av en pausad databas.';
        END IF;

    ELSIF markor IS NOT NULL THEN
        -- Det tysta läget: markören står kvar men tabellen är tom. Enda rimliga
        -- förklaringen är att en återläsning droppade hex_paus, och då är
        -- tidigare_lage borta för gott.
        RAISE WARNING '[hex_ateruppta] Pausmarkör satt sedan %, men hex_paus är tom. '
                      'En återläsning (pg_restore --clean) har droppat tabellen. '
                      'Lägena före pausen går inte att lägga tillbaka – de stod '
                      'bara i tidigare_lage. Underhållet körs, och det som '
                      'fortfarande är avstängt redovisas nedan.', markor;
    ELSE
        RAISE NOTICE '[hex_ateruppta] Hex är inte pausat. Kör underhållet ändå – '
                     'det är reparationssteget efter en återläsning, och en '
                     'återläsning i en tom måldatabas hinner aldrig pausas.';
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Radtriggers
    --    Objekt som försvann under återläsningen hoppas över och rapporteras.
    --    Saknas triggern helt återskapar hex_underhall() den i steg 3.
    -- -------------------------------------------------------------------------
    IF har_paus THEN
        RAISE NOTICE '[hex_ateruppta] Steg 1: Återställer radtriggers';

        FOR post IN
            SELECT * FROM jsonb_array_elements(paus.tidigare_lage -> 'radtriggers')
        LOOP
            IF NOT EXISTS (
                SELECT 1
                FROM   pg_trigger   tg
                JOIN   pg_class     c ON c.oid = tg.tgrelid
                JOIN   pg_namespace n ON n.oid = c.relnamespace
                WHERE  n.nspname = post ->> 'schema'
                  AND  c.relname = post ->> 'tabell'
                  AND  tg.tgname = post ->> 'namn'
            ) THEN
                antal_saknas := antal_saknas + 1;
                objekt := format('%s.%s.%s', post ->> 'schema', post ->> 'tabell', post ->> 'namn');
                typ    := 'radtrigger';
                atgard := 'saknas – hoppas över';
                RETURN NEXT;
                CONTINUE;
    
    ELSE
        RAISE NOTICE '[hex_ateruppta] Steg 1: Hoppas över – ingen bokföring '
                     'att lägga tillbaka.';
    END IF;

        sats := public.hex_triggerlage_sats(post ->> 'lage');

        EXECUTE format('ALTER TABLE %I.%I %s TRIGGER %I',
            post ->> 'schema', post ->> 'tabell', sats, post ->> 'namn');
        antal_rad := antal_rad + 1;

        objekt := format('%s.%s.%s', post ->> 'schema', post ->> 'tabell', post ->> 'namn');
        typ    := 'radtrigger';
        atgard := format('%s (läge %s)', lower(sats), post ->> 'lage');
        RETURN NEXT;
    END LOOP;

    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Underhåll, fortfarande med event-triggarna avstängda
    -- -------------------------------------------------------------------------
    IF p_underhall THEN
        RAISE NOTICE '[hex_ateruppta] Steg 2: Kör hex_underhall()';

        -- Flaggan tystar hex_underhall()s pausvarning. Underhållet varnar med
        -- flit när det körs mot en pausad databas, men här är det själva
        -- poängen: hex_ateruppta() kör det medvetet innan pausen hävs. Utan
        -- flaggan skrev varenda korrekt återupptagning ut en uppmaning att
        -- avbryta, och en varning som alltid syns slutar betyda något.
        --
        -- is_local => true binder värdet till transaktionen. Den nollställs
        -- ändå explicit efteråt, så att ett hex_underhall()-anrop senare i
        -- samma transaktion får sin varning.
        PERFORM set_config('hex.ateruppta_pagar', 'true', true);

        FOR underhall IN SELECT * FROM public.hex_underhall() LOOP
            antal_und := antal_und + 1;
        END LOOP;

        PERFORM set_config('hex.ateruppta_pagar', '', true);

        objekt := 'hex_underhall()';
        typ    := 'underhåll';
        atgard := format('%s åtgärder granskade', antal_und);
        RETURN NEXT;
    ELSE
        RAISE NOTICE '[hex_ateruppta] Steg 2: Hoppar över underhåll (p_underhall = false)';
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Event-triggers sist
    -- -------------------------------------------------------------------------
    IF har_paus THEN
        RAISE NOTICE '[hex_ateruppta] Steg 3: Slår på event-triggers';

        FOR post IN
            SELECT * FROM jsonb_array_elements(paus.tidigare_lage -> 'event_triggers')
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_event_trigger WHERE evtname = post ->> 'namn'
            ) THEN
                antal_saknas := antal_saknas + 1;
                objekt := post ->> 'namn';
                typ    := 'event-trigger';
                atgard := 'saknas – hoppas över';
                RETURN NEXT;
                CONTINUE;
    
    ELSE
        RAISE NOTICE '[hex_ateruppta] Steg 3: Hoppas över – ingen bokföring '
                     'att lägga tillbaka.';
    END IF;

        sats := public.hex_triggerlage_sats(post ->> 'lage');

        EXECUTE format('ALTER EVENT TRIGGER %I %s', post ->> 'namn', sats);
        antal_ev := antal_ev + 1;

        objekt := post ->> 'namn';
        typ    := 'event-trigger';
        atgard := format('%s (läge %s)', lower(sats), post ->> 'lage');
        RETURN NEXT;
    END LOOP;

    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Utan bokföring: redovisa vad som fortfarande står avstängt
    --
    --    Det finns inget sparat läge att lägga tillbaka, och att gissa "allt
    --    på" vore fel – en DBA kan ha stängt av något med flit. Men att lämna
    --    det outsagt är sämre: det var precis så historiken dog tyst. Varje
    --    avstängt Hex-objekt listas därför med besked om att det måste
    --    bedömas för hand.
    -- -------------------------------------------------------------------------
    IF NOT har_paus THEN
        FOR r IN
            SELECT et.evtname AS namn
            FROM   pg_event_trigger et
            JOIN   pg_proc        pr ON pr.oid = et.evtfoid
            JOIN   pg_namespace   n  ON n.oid  = pr.pronamespace
            WHERE  n.nspname = 'public'
              AND  pr.proname LIKE 'hex\_%'
              AND  et.evtenabled = 'D'
            ORDER  BY et.evtname
        LOOP
            antal_kvar := antal_kvar + 1;
            objekt := r.namn;
            typ    := 'event-trigger';
            atgard := 'avstängd – ingen bokföring, bedöm för hand';
            RETURN NEXT;
        END LOOP;

        -- Bara Hex egna radtriggers. En avstängd trigger som någon annan äger
        -- är inte Hex ensak att uttala sig om.
        IF public.hex_schema_regex() IS NOT NULL THEN
            FOR r IN
                SELECT n.nspname AS s, c.relname AS t, tg.tgname AS g
                FROM   pg_trigger   tg
                JOIN   pg_class     c ON c.oid = tg.tgrelid
                JOIN   pg_namespace n ON n.oid = c.relnamespace
                WHERE  NOT tg.tgisinternal
                  AND  c.relkind IN ('r', 'p', 'f')
                  AND  n.nspname ~ public.hex_schema_regex()
                  AND  tg.tgenabled = 'D'
                  AND  (tg.tgname LIKE 'hex\_%' OR tg.tgname LIKE 'trg\_%\_qa')
                ORDER  BY n.nspname, c.relname, tg.tgname
            LOOP
                antal_kvar := antal_kvar + 1;
                objekt := format('%s.%s.%s', r.s, r.t, r.g);
                typ    := 'radtrigger';
                atgard := 'avstängd – ingen bokföring, bedöm för hand';
                RETURN NEXT;
            END LOOP;
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Ta bort bokföringen och markören
    -- -------------------------------------------------------------------------
    IF har_paus THEN
        DELETE FROM public.hex_paus;
    END IF;

    IF markor IS NOT NULL THEN
        EXECUTE format(
            'ALTER DATABASE %I RESET %I', current_database(), 'hex.paus'
        );
    END IF;

    RAISE NOTICE '[hex_ateruppta] Sammanfattning:';
    RAISE NOTICE '[hex_ateruppta]   » Event-triggers återställda: %', antal_ev;
    RAISE NOTICE '[hex_ateruppta]   » Radtriggers återställda:    %', antal_rad;
    RAISE NOTICE '[hex_ateruppta]   » Objekt som saknades:        %', antal_saknas;
    RAISE NOTICE '[hex_ateruppta]   » Avstängda utan bokföring:   %', antal_kvar;

    IF antal_saknas > 0 THEN
        RAISE WARNING '[hex_ateruppta] % objekt fanns inte kvar efter pausen. '
                      'Det är väntat när en återläsning ersatt tabeller. Kontrollera '
                      'att hex_underhall() återskapat triggarna: '
                      'SELECT * FROM hex_pausstatus();', antal_saknas;
    END IF;

    IF antal_kvar > 0 THEN
        RAISE WARNING '[hex_ateruppta] % Hex-objekt står avstängda utan att någon '
                      'bokföring säger varför. Historik och QA-kolumner uppdateras '
                      'inte på de tabellerna. Gå igenom listan ovan och slå på det '
                      'som ska vara på: ALTER TABLE ... ENABLE TRIGGER ... '
                      'respektive ALTER EVENT TRIGGER ... ENABLE.', antal_kvar;
    END IF;

    IF har_paus THEN
        RAISE NOTICE '[hex_ateruppta] Hex är igång igen.';
    ELSE
        RAISE NOTICE '[hex_ateruppta] Underhållet är kört. Hex var inte pausat, så '
                     'inga triggerlägen lades tillbaka.';
    END IF;
    RAISE NOTICE '[hex_ateruppta] === SLUT ===';

    RETURN;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_ateruppta(boolean) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

REVOKE ALL ON FUNCTION public.hex_ateruppta(boolean) FROM PUBLIC;

COMMENT ON FUNCTION public.hex_ateruppta(boolean) IS
    'Återupptar Hex efter hex_pausa(). Lägger tillbaka de lägen som sparades i
     hex_paus.tidigare_lage, kör hex_underhall() medan event-triggarna
     fortfarande är avstängda, slår på event-triggarna sist och tar bort
     hex_paus-raden och pausmarkören. Saknas bokföringen körs underhållet ändå
     – raden kan ha droppats av just den pg_restore --clean den skulle skydda –
     och det som står avstängt redovisas i stället för att lämnas outsagt.
     Kräver superanvändare.';
