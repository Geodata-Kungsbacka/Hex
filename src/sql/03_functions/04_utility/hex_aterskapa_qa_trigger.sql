CREATE OR REPLACE FUNCTION public.hex_aterskapa_qa_trigger(
    p_schema_namn text,
    p_tabell_namn text,
    p_historik_tabell text
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Återskapar QA-triggerfunktionen (trg_fn_<tabell>_qa) med aktuell kolumnlista.
 *
 * SYFTE:
 * Triggerfunktionens kropp innehåller en explicit kolumnlista för INSERT mot
 * historiktabellen. Ändras modertabellens kolumner - genom ADD COLUMN,
 * RENAME COLUMN eller DROP COLUMN - blir listan inaktuell och triggern kraschar vid nästa
 * UPDATE/DELETE. Denna funktion bygger om funktionskroppen från modertabellens
 * nuvarande struktur.
 *
 * Kolumnnamn citeras med %I så att reserverade ord (left, order, select ...)
 * fungerar i den genererade funktionskroppen.
 *
 * ANVÄNDS AV:
 * - hex_synka_historik(), som i sin tur anropas av hex_hantera_ny_kolumn()
 *   efter varje ALTER TABLE och av hex_underhall()
 *
 * PARAMETRAR:
 * - p_schema_namn:     Schemat som modertabellen ligger i
 * - p_tabell_namn:     Modertabellens namn
 * - p_historik_tabell: Historiktabellens namn (normalt <tabell>_h)
 *
 * RETURVÄRDE:
 * - true om triggerfunktionen återskapades, annars false (fel loggas som WARNING
 *   men kastas inte vidare - anroparen ska inte rulla tillbaka DDL:en för detta)
 ******************************************************************************/
DECLARE
    kolumn_lista          text;
    old_kolumn_lista      text;
    trigger_funktionsnamn text;
    qa_kolumner           text[];
    qa_uttryck            text[];
    trigger_satser        text := '';
    i                     integer;
BEGIN
    -- Bygg om den funktion som triggern faktiskt anropar. Efter ALTER TABLE
    -- RENAME TO heter den fortfarande trg_fn_<gammalt namn>_qa, och det
    -- härledda namnet skulle skapa en ny funktion som ingen trigger använder.
    SELECT p.proname INTO trigger_funktionsnamn
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE t.tgrelid = to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn))
      AND NOT t.tgisinternal
      AND p.proname ~ '^trg_fn_.+_qa$'
    LIMIT 1;
    trigger_funktionsnamn := coalesce(trigger_funktionsnamn, 'trg_fn_' || p_tabell_namn || '_qa');

    -- Aktuell kolumnlista från modertabellen. pg_attribute i stället för
    -- information_schema.columns: den senare visar bara kolumner som den
    -- aktuella rollen har rättigheter på, och en kolumn som inte syns skulle
    -- tyst falla ur triggern.
    SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
    INTO kolumn_lista
    FROM pg_attribute a
    WHERE a.attrelid = to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn))
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF kolumn_lista IS NULL THEN
        RAISE WARNING '[hex_aterskapa_qa_trigger] Hittade inga kolumner för %.% - hoppar över',
            p_schema_namn, p_tabell_namn;
        RETURN false;
    END IF;

    -- Matchande OLD.-lista i samma ordning
    SELECT string_agg(format('OLD.%I', a.attname), ', ' ORDER BY a.attnum)
    INTO old_kolumn_lista
    FROM pg_attribute a
    WHERE a.attrelid = to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn))
      AND a.attnum > 0
      AND NOT a.attisdropped;

    -- QA-kolumner som finns på tabellen och har ett uttryck
    SELECT
        array_agg(sk.kolumnnamn ORDER BY sk.ordinal_position),
        array_agg(sk.default_varde ORDER BY sk.ordinal_position)
    INTO qa_kolumner, qa_uttryck
    FROM hex_standardiserade_kolumner sk
    WHERE sk.historik_qa = true
      AND sk.default_varde IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM pg_attribute a
          WHERE a.attrelid = to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn))
            AND a.attname = sk.kolumnnamn
            AND a.attnum > 0
            AND NOT a.attisdropped
      );

    FOR i IN 1..COALESCE(array_length(qa_kolumner, 1), 0) LOOP
        trigger_satser := trigger_satser || format(
            E'        rad.%I = %s;\n',
            qa_kolumner[i], qa_uttryck[i]
        );
    END LOOP;

    EXECUTE format($TRIG$
        CREATE OR REPLACE FUNCTION %I.%I()
        RETURNS TRIGGER AS $$
        DECLARE
            rad %I.%I%%ROWTYPE;
        BEGIN
            IF TG_OP = 'UPDATE' THEN
                rad := NEW;

                -- Sätt QA-värden
%s
                -- Kopiera gamla värdet till historik
                INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                SELECT 'U', NOW(), session_user, %s;

                RETURN rad;
            ELSE -- DELETE
                rad := OLD;

                -- Sätt QA-värden även för DELETE (för konsistens)
%s
                -- Kopiera till historik
                INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                SELECT 'D', NOW(), session_user, %s;

                RETURN OLD;
            END IF;
        END;
        $$ LANGUAGE plpgsql;
    $TRIG$,
        p_schema_namn, trigger_funktionsnamn,
        p_schema_namn, p_tabell_namn,
        trigger_satser,
        p_schema_namn, p_historik_tabell, kolumn_lista, old_kolumn_lista,
        trigger_satser,
        p_schema_namn, p_historik_tabell, kolumn_lista, old_kolumn_lista
    );

    RAISE NOTICE '[hex_aterskapa_qa_trigger]   ✓ Trigger-funktion % återskapad', trigger_funktionsnamn;
    RETURN true;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '[hex_aterskapa_qa_trigger]   ✗ Kunde inte återskapa trigger-funktion %: %',
            trigger_funktionsnamn, SQLERRM;
        RETURN false;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_aterskapa_qa_trigger(text, text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_aterskapa_qa_trigger(text, text, text)
    IS 'Återskapar QA-triggerfunktionen trg_fn_<tabell>_qa med modertabellens aktuella
kolumnlista. Anropas via hex_synka_historik() efter varje ALTER TABLE så att den genererade
INSERT-satsen mot historiktabellen fortsätter matcha tabellstrukturen. Kolumnnamn
citeras så att reserverade ord fungerar.';
