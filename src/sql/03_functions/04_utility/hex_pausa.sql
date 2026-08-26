CREATE OR REPLACE FUNCTION public.hex_pausa(
    p_anledning   text    DEFAULT NULL,
    p_max_timmar  integer DEFAULT 24,
    p_radtriggers boolean DEFAULT true
)
    RETURNS TABLE (
        objekt text,
        typ    text,
        atgard text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Pausar Hex inför en pg_dump/pg_restore eller annan massiv DDL- och
 * DML-omgång.
 *
 * BAKGRUND
 * Hex reagerar på DDL genom tio event-triggers. Under en återläsning kommer
 * varje CREATE TABLE, ALTER TABLE och DROP SCHEMA i dumpen att gå genom dem.
 * Det är inte bara långsamt – det är destruktivt:
 *
 *   - hex_hantera_ny_tabell() omstrukturerar varje återläst tabell och skapar
 *     historiktabell, sekvens, index och radtriggers. pg_restore försöker
 *     sedan skapa samma objekt och får "already exists". pg_restore räknar
 *     det som en ignorerad varning och avslutar med kod 0.
 *   - COPY-steget kan misslyckas mot de nyskapade triggarna medan
 *     pg_restore ändå rapporterar framgång. Resultatet är en tabell som
 *     finns, ser rimlig ut och är tom.
 *   - hex_ta_bort_schemaroller() tar bort schemats fyra roller vid DROP
 *     SCHEMA, och hex_notifiera_gs_borttagning() ber GeoServer radera
 *     workspace och datastore. En återläsning med --clean river alltså både
 *     roller och GeoServer-uppsättning innan den börjar läsa in något.
 *
 * VAD FUNKTIONEN GÖR
 *   1. Stänger av alla event-triggers som pekar på en public.hex_*-funktion.
 *      Det stoppar hela DDL-vågen.
 *   2. Stänger av radtriggers (icke-interna) på alla tabeller i Hex-scheman,
 *      om p_radtriggers = true. Behövs bara vid data-only-återläsning i
 *      befintliga tabeller – vid full återläsning skapar pg_dump triggarna
 *      efter datat ändå.
 *   3. Skriver en rad i hex_paus med lägena före pausen.
 *
 * VAD FUNKTIONEN INTE GÖR
 *   - CHECK-villkor stängs inte av. Geometrivalideringen
 *     validera_geom_<tabell> sitter kvar och gäller varje INSERT. Data som
 *     passerade valideringen i källdatabasen passerar den även vid
 *     återläsning; äldre data som aldrig validerats gör det inte.
 *   - Främmande nycklar rörs inte. Interna triggar lämnas påslagna med
 *     flit – en paus ska inte kunna smuggla in referensbrott.
 *   - Roller är globala i klustret och ligger inte i en pg_dump. Vid
 *     återläsning i ett nytt kluster saknas r_/w_/gs_-rollerna helt.
 *     hex_ateruppta() kör hex_underhall(), som återskapar dem från
 *     hex_standardiserade_roller och hex_rolluppgifter.
 *
 * PARAMETRAR
 *   p_anledning   Fritext som skrivs till hex_paus, t.ex. ärendenummer.
 *   p_max_timmar  Varningsgräns i timmar. Skrivs som pausad_till och gör att
 *                 hex_pausstatus() flaggar en glömd paus. NULL = ingen gräns.
 *   p_radtriggers Stäng även av radtriggers på Hex-tabeller. Standard true.
 *
 * KRÄVER SUPERANVÄNDARE. ALTER EVENT TRIGGER kräver ägarskap, och enbart
 * superanvändare får äga event-triggers. Funktionen är därför medvetet inte
 * SECURITY DEFINER: att pausa Hex ska inte gå att delegera till ägarrollen.
 *
 * ANVÄNDNING
 *   SELECT * FROM hex_pausa('pg_restore av prod till test', 8);
 *   -- ... pg_dump / pg_restore ...
 *   SELECT * FROM hex_ateruppta();
 *
 * Returnerar en rad per avstängt objekt. Är Hex redan pausat kastas ett fel –
 * en andra paus skulle skriva över kvittot på hur det såg ut från början.
 ******************************************************************************/
DECLARE
    r                record;
    ev_lagen         jsonb := '[]'::jsonb;
    rad_lagen        jsonb := '[]'::jsonb;
    antal_ev         integer := 0;
    antal_rad        integer := 0;
    schema_regex     text;
    befintlig_paus   record;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Förutsättningar
    -- -------------------------------------------------------------------------
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION
            '[hex_pausa] Kräver superanvändare. Aktuell användare: %', current_user
            USING HINT = 'ALTER EVENT TRIGGER kräver ägarskap, och event-triggers '
                         'kan bara ägas av en superanvändare. Kör som postgres.';
    END IF;

    SELECT * INTO befintlig_paus FROM public.hex_paus;
    IF FOUND THEN
        RAISE EXCEPTION
            '[hex_pausa] Hex är redan pausat sedan % av %',
            befintlig_paus.pausad_sedan, befintlig_paus.pausad_av
            USING HINT = 'Kör hex_ateruppta() först. En andra paus skulle skriva '
                         'över hex_paus.tidigare_lage, och då går det ursprungliga '
                         'läget inte att lägga tillbaka.';
    END IF;

    RAISE NOTICE '[hex_pausa] === START ===';

    -- -------------------------------------------------------------------------
    -- 2. Event-triggers
    --    Urvalet går på funktionen, inte på triggerns namn. En event-trigger
    --    som döpts om pekar fortfarande på sin public.hex_*-funktion och
    --    fångas därför ändå.
    -- -------------------------------------------------------------------------
    RAISE NOTICE '[hex_pausa] Steg 1: Stänger av event-triggers';

    FOR r IN
        SELECT et.evtname, et.evtenabled
        FROM   pg_event_trigger et
        JOIN   pg_proc          p ON p.oid = et.evtfoid
        JOIN   pg_namespace     n ON n.oid = p.pronamespace
        WHERE  n.nspname = 'public'
          AND  p.proname LIKE 'hex\_%'
        ORDER  BY et.evtname
    LOOP
        ev_lagen := ev_lagen || jsonb_build_object(
            'namn', r.evtname,
            'lage', r.evtenabled
        );

        IF r.evtenabled = 'D' THEN
            objekt := r.evtname;
            typ    := 'event-trigger';
            atgard := 'redan avstängd';
            RETURN NEXT;
            CONTINUE;
        END IF;

        EXECUTE format('ALTER EVENT TRIGGER %I DISABLE', r.evtname);
        antal_ev := antal_ev + 1;

        objekt := r.evtname;
        typ    := 'event-trigger';
        atgard := 'avstängd';
        RETURN NEXT;
    END LOOP;

    IF antal_ev = 0 AND jsonb_array_length(ev_lagen) = 0 THEN
        RAISE WARNING '[hex_pausa] Hittade inga event-triggers som pekar på '
                      'public.hex_*-funktioner. Är Hex installerat i den här databasen?';
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Radtriggers på Hex-tabeller
    --    Ordningen är avsiktlig: event-triggarna är redan avstängda, så
    --    ALTER TABLE nedan går inte genom hex_hantera_ny_kolumn().
    --
    --    Alla icke-interna triggar stängs av, inte bara Hex egna. Poängen med
    --    pausen är att ingenting ska skriva om raderna som läses in. Interna
    --    triggar (främmande nycklar, uppskjutna villkor) lämnas påslagna.
    -- -------------------------------------------------------------------------
    IF p_radtriggers THEN
        RAISE NOTICE '[hex_pausa] Steg 2: Stänger av radtriggers på Hex-tabeller';

        schema_regex := public.hex_schema_regex();

        FOR r IN
            SELECT n.nspname AS s, c.relname AS t, tg.tgname AS g, tg.tgenabled AS lage
            FROM   pg_trigger   tg
            JOIN   pg_class     c ON c.oid = tg.tgrelid
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  NOT tg.tgisinternal
              AND  c.relkind IN ('r', 'p')
              AND  n.nspname ~ schema_regex
            -- Partitionerade tabeller först (tgparentid = 0), partitionernas
            -- kopior sedan. ALTER TABLE på en partitionerad förälder slår
            -- igenom på alla partitioner, så ordningen avgör vem som vinner
            -- när hex_ateruppta() spelar upp listan: föräldern sätts först och
            -- partitionens egen kod skriver därefter över kaskaden. Utan
            -- ordningen skulle en partition som medvetet stängts av kunna slås
            -- på igen, eftersom ett partitionsnamn inte behöver sortera efter
            -- förälderns.
            ORDER  BY (tg.tgparentid <> 0), n.nspname, c.relname, tg.tgname
        LOOP
            rad_lagen := rad_lagen || jsonb_build_object(
                'schema', r.s,
                'tabell', r.t,
                'namn',   r.g,
                'lage',   r.lage
            );

            IF r.lage = 'D' THEN
                objekt := format('%s.%s.%s', r.s, r.t, r.g);
                typ    := 'radtrigger';
                atgard := 'redan avstängd';
                RETURN NEXT;
                CONTINUE;
            END IF;

            EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER %I', r.s, r.t, r.g);
            antal_rad := antal_rad + 1;

            objekt := format('%s.%s.%s', r.s, r.t, r.g);
            typ    := 'radtrigger';
            atgard := 'avstängd';
            RETURN NEXT;
        END LOOP;
    ELSE
        RAISE NOTICE '[hex_pausa] Steg 2: Hoppar över radtriggers (p_radtriggers = false)';
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Bokför pausen
    -- -------------------------------------------------------------------------
    INSERT INTO public.hex_paus (anledning, pausad_till, tidigare_lage)
    VALUES (
        p_anledning,
        CASE WHEN p_max_timmar IS NULL
             THEN NULL
             ELSE now() + make_interval(hours => p_max_timmar)
        END,
        jsonb_build_object(
            'event_triggers', ev_lagen,
            'radtriggers',    rad_lagen
        )
    );

    RAISE NOTICE '[hex_pausa] Sammanfattning:';
    RAISE NOTICE '[hex_pausa]   » Event-triggers avstängda: %', antal_ev;
    RAISE NOTICE '[hex_pausa]   » Radtriggers avstängda:    %', antal_rad;
    RAISE NOTICE '[hex_pausa]   » Anledning:                %', coalesce(p_anledning, '(ingen angiven)');
    RAISE NOTICE '[hex_pausa] Hex är pausat. Kör hex_ateruppta() när återläsningen är klar.';
    RAISE NOTICE '[hex_pausa] === SLUT ===';

    RETURN;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_pausa(text, integer, boolean) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

-- Enbart superanvändare kommer förbi kontrollen i funktionen ändå. REVOKE här
-- gör att en obehörig anropare får ett rättighetsfel i stället för ett
-- funktionsfel, vilket är tydligare.
REVOKE ALL ON FUNCTION public.hex_pausa(text, integer, boolean) FROM PUBLIC;

COMMENT ON FUNCTION public.hex_pausa(text, integer, boolean) IS
    'Pausar Hex inför pg_dump/pg_restore genom att stänga av alla event-triggers
     och (valfritt) radtriggers på Hex-tabeller. Lägena före pausen sparas i
     hex_paus.tidigare_lage så att hex_ateruppta() kan lägga tillbaka exakt
     samma läge. Kräver superanvändare.
     Stänger INTE av CHECK-villkor eller främmande nycklar.';
