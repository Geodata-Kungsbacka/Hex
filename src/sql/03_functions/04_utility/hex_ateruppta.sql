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
 * Idempotent: är Hex inte pausat skrivs en NOTICE och inga rader returneras.
 ******************************************************************************/
DECLARE
    paus         record;
    post         jsonb;
    antal_ev     integer := 0;
    antal_rad    integer := 0;
    antal_saknas integer := 0;
    underhall    record;
    antal_und    integer := 0;
    sats         text;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Förutsättningar
    -- -------------------------------------------------------------------------
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION
            '[hex_ateruppta] Kräver superanvändare. Aktuell användare: %', current_user
            USING HINT = 'ALTER EVENT TRIGGER kräver ägarskap, och event-triggers '
                         'kan bara ägas av en superanvändare. Kör som postgres.';
    END IF;

    SELECT * INTO paus FROM public.hex_paus;
    IF NOT FOUND THEN
        RAISE NOTICE '[hex_ateruppta] Hex är inte pausat – ingenting att göra.';
        RAISE NOTICE '[hex_ateruppta] Kör SELECT * FROM hex_pausstatus() för att '
                     'se om något ändå står avstängt.';
        RETURN;
    END IF;

    RAISE NOTICE '[hex_ateruppta] === START ===';
    RAISE NOTICE '[hex_ateruppta] Pausad sedan % av % (%)',
        paus.pausad_sedan, paus.pausad_av, coalesce(paus.anledning, 'ingen anledning angiven');

    -- -------------------------------------------------------------------------
    -- 2. Radtriggers
    --    Objekt som försvann under återläsningen hoppas över och rapporteras.
    --    Saknas triggern helt återskapar hex_underhall() den i steg 3.
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- 3. Underhåll, fortfarande med event-triggarna avstängda
    -- -------------------------------------------------------------------------
    IF p_underhall THEN
        RAISE NOTICE '[hex_ateruppta] Steg 2: Kör hex_underhall()';

        FOR underhall IN SELECT * FROM public.hex_underhall() LOOP
            antal_und := antal_und + 1;
        END LOOP;

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
        END IF;

        sats := public.hex_triggerlage_sats(post ->> 'lage');

        EXECUTE format('ALTER EVENT TRIGGER %I %s', post ->> 'namn', sats);
        antal_ev := antal_ev + 1;

        objekt := post ->> 'namn';
        typ    := 'event-trigger';
        atgard := format('%s (läge %s)', lower(sats), post ->> 'lage');
        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 5. Ta bort bokföringen
    -- -------------------------------------------------------------------------
    DELETE FROM public.hex_paus;

    RAISE NOTICE '[hex_ateruppta] Sammanfattning:';
    RAISE NOTICE '[hex_ateruppta]   » Event-triggers återställda: %', antal_ev;
    RAISE NOTICE '[hex_ateruppta]   » Radtriggers återställda:    %', antal_rad;
    RAISE NOTICE '[hex_ateruppta]   » Objekt som saknades:        %', antal_saknas;

    IF antal_saknas > 0 THEN
        RAISE WARNING '[hex_ateruppta] % objekt fanns inte kvar efter pausen. '
                      'Det är väntat när en återläsning ersatt tabeller. Kontrollera '
                      'att hex_underhall() återskapat triggarna: '
                      'SELECT * FROM hex_pausstatus();', antal_saknas;
    END IF;

    RAISE NOTICE '[hex_ateruppta] Hex är igång igen.';
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
     hex_paus-raden. Idempotent. Kräver superanvändare.';
