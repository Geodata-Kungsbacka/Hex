CREATE OR REPLACE FUNCTION public.reparera_gid_dubbletter(
    p_schema_namn text,
    p_tabell_namn text,
    p_utfor       boolean DEFAULT false
)
    RETURNS TABLE (
        gid_varde   integer,
        antal_rader bigint,
        atgard      text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Hittar – och på begäran åtgärdar – dubbletter i gid.
 *
 * Tabeller som skapades innan Hex lade PRIMARY KEY på gid saknar unikt index.
 * Där kan tvinga_gid_fran_sekvens() ha släppt igenom ett klientvalt gid som
 * råkade sammanfalla med currval(), och raden skrevs utan fel. Konsekvensen är
 * att QGIS – som använder gid som objekt-id – redigerar eller raderar flera
 * rader när användaren ändrar en.
 *
 * SÄKERHET
 * Funktionen är en TORRKÖRNING som standard (p_utfor = false) och rapporterar
 * bara vad den skulle göra. Omnumrering ändrar användarens data och kan inte
 * ångras, så den kräver ett uttryckligt p_utfor = true.
 *
 * OMNUMRERING
 * Per dubblettgrupp behålls raden med lägst ctid – den behåller sitt gid, så
 * att externa referenser till "första" raden överlever. Övriga rader får
 * gid = DEFAULT, dvs nästa värde ur sekvensen.
 *
 * OBS: gid = DEFAULT är den ENDA tilldelning PostgreSQL accepterar i en UPDATE
 * mot en GENERATED ALWAYS-kolumn. Varje litteralt värde – även samma värde som
 * raden redan har – ger "column gid can only be updated to DEFAULT".
 *
 * QA-triggern lämnas påslagen: omnumreringen är en riktig dataändring och ska
 * synas i historiktabellen.
 *
 * ANVÄNDNING
 *   SELECT * FROM public.reparera_gid_dubbletter('sk1_kba_geo', 'vagar');
 *   SELECT * FROM public.reparera_gid_dubbletter('sk1_kba_geo', 'vagar', true);
 *   SELECT public.sakerstall_gid_primarnyckel('sk1_kba_geo', 'vagar');
 ******************************************************************************/
DECLARE
    tabell_oid  oid;
    r           record;
    antal_kvar  bigint;
BEGIN
    SELECT c.oid
    INTO   tabell_oid
    FROM   pg_class     c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = p_schema_namn
      AND  c.relname = p_tabell_namn
      AND  c.relkind = 'r';

    IF tabell_oid IS NULL THEN
        RAISE EXCEPTION '[reparera_gid_dubbletter] Tabellen %.% finns inte',
            p_schema_namn, p_tabell_namn;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM   pg_attribute a
        WHERE  a.attrelid = tabell_oid
          AND  a.attname  = 'gid'
          AND  NOT a.attisdropped
    ) THEN
        RAISE EXCEPTION '[reparera_gid_dubbletter] Tabellen %.% saknar gid-kolumn',
            p_schema_namn, p_tabell_namn;
    END IF;

    -- Steg 1: Rapportera dubblettgrupperna som de ser ut nu.
    FOR r IN EXECUTE format(
        'SELECT gid AS g, count(*) AS n FROM %I.%I GROUP BY gid HAVING count(*) > 1 ORDER BY gid',
        p_schema_namn, p_tabell_namn
    )
    LOOP
        gid_varde   := r.g;
        antal_rader := r.n;
        atgard      := CASE
                           WHEN p_utfor THEN format('%s rad(er) omnumrerade', r.n - 1)
                           ELSE format('%s rad(er) skulle omnumreras', r.n - 1)
                       END;
        RETURN NEXT;
    END LOOP;

    IF NOT FOUND THEN
        gid_varde   := NULL;
        antal_rader := 0;
        atgard      := 'inga dubbletter';
        RETURN NEXT;
        RETURN;
    END IF;

    IF NOT p_utfor THEN
        RAISE NOTICE '[reparera_gid_dubbletter] Torrkörning. Kör om med '
            'p_utfor = true för att omnumrera.';
        RETURN;
    END IF;

    -- Steg 2: Omnumrera. Delfrågorna läser transaktionens ögonblicksbild, så
    -- ctid-jämförelsen och dubblettlistan påverkas inte av de UPDATE:ar som
    -- satsen själv utför.
    EXECUTE format(
        'UPDATE %I.%I t
            SET gid = DEFAULT
          WHERE t.gid IN (
                    SELECT gid FROM %I.%I GROUP BY gid HAVING count(*) > 1
                )
            AND t.ctid <> (
                    SELECT min(x.ctid) FROM %I.%I x WHERE x.gid = t.gid
                )',
        p_schema_namn, p_tabell_namn,
        p_schema_namn, p_tabell_namn,
        p_schema_namn, p_tabell_namn
    );

    -- Steg 3: Verifiera att inget blev kvar.
    EXECUTE format(
        'SELECT count(*) FROM (SELECT gid FROM %I.%I GROUP BY gid HAVING count(*) > 1) d',
        p_schema_namn, p_tabell_namn
    ) INTO antal_kvar;

    IF antal_kvar > 0 THEN
        RAISE EXCEPTION '[reparera_gid_dubbletter] % dubblettgrupper kvarstår i %.% '
            'efter omnumrering', antal_kvar, p_schema_namn, p_tabell_namn;
    END IF;

    -- RAISE saknar %L; citera literalerna så att hinten går att klistra in.
    RAISE NOTICE '[reparera_gid_dubbletter] %.% är dubblettfri. Kör nu: '
        'SELECT public.sakerstall_gid_primarnyckel(%, %);',
        p_schema_namn, p_tabell_namn,
        quote_literal(p_schema_namn), quote_literal(p_tabell_namn);
    RETURN;
END;
$BODY$;

ALTER FUNCTION public.reparera_gid_dubbletter(text, text, boolean)
    OWNER TO postgres;

COMMENT ON FUNCTION public.reparera_gid_dubbletter(text, text, boolean)
    IS 'Rapporterar dubbletter i gid, och omnumrerar dem när p_utfor = true.
Torrkörning som standard eftersom omnumrering ändrar data och inte kan ångras.
Raden med lägst ctid i varje grupp behåller sitt gid; övriga får nästa
sekvensvärde. Körs före sakerstall_gid_primarnyckel() på tabeller där denna
rapporterat "dubbletter: N".';
