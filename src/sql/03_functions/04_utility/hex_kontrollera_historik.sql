CREATE OR REPLACE FUNCTION public.hex_kontrollera_historik()
    RETURNS TABLE (
        schema_namn    text,
        tabell_namn    text,
        historiktabell text,
        problem        text,
        detalj         text
    )
    LANGUAGE 'sql'
    STABLE
AS $BODY$
/******************************************************************************
 * Listar tabeller vars historiktabell eller QA-trigger inte stämmer med
 * modertabellen. Läser bara – rättningen görs av hex_synka_historik(), som
 * hex_underhall() kör på samtliga tabeller.
 *
 * Paren moder/historik hämtas ur två källor, så att även tabeller som saknas i
 * hex_metadata kommer med:
 *   - hex_metadata (parent_oid → history_table), som följer med vid RENAME TO
 *   - namnkonventionen <tabell>_h i samma schema
 *
 * PROBLEMTYPER
 *   saknas i historik    Kolumn i modertabellen som historiktabellen saknar.
 *                        Värdet sparas inte vid UPDATE/DELETE (om triggern
 *                        byggts om) eller får triggern att krascha.
 *   typskillnad          Samma kolumn, olika typ i moder och historik.
 *   trigger: borttagen   QA-triggern läser OLD.<kolumn> som inte längre finns.
 *                        Varje UPDATE/DELETE kraschar.
 *   trigger: saknas      Kolumn i modertabellen som QA-triggern inte kopierar.
 *                        Kraschar inte, men historiken tappar värdet tyst.
 *   ingen QA-trigger     Historiktabell finns men modertabellen har ingen
 *                        trg_fn_*_qa-trigger. Ingen historik skrivs.
 *   ej i hex_metadata    Paret hittades bara via namnkonventionen.
 *   afvaktande med geom  Tabellen står kvar i hex_afvaktande_geometri trots
 *                        att den har geom – FME-tvåsteget slutfördes aldrig
 *                        (GiST-index, geometrivalidering och historiksynk).
 ******************************************************************************/
    WITH par AS (
        SELECT m.parent_oid AS moder_oid,
               to_regclass(format('%I.%I', m.history_schema, m.history_table))::oid AS h_oid,
               true AS i_metadata
        FROM public.hex_metadata m
        WHERE EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = m.parent_oid)
        UNION ALL
        SELECT c.oid, h.oid, false
        FROM pg_class c
        JOIN pg_class h
          ON h.relnamespace = c.relnamespace
         AND h.relname = left(c.relname || '_h', 63)
         AND h.relkind = 'r'
        WHERE c.relkind = 'r'
          AND c.relname !~ '_h$'
          AND NOT EXISTS (SELECT 1 FROM public.hex_metadata m WHERE m.parent_oid = c.oid)
    ),
    par_namn AS (
        SELECT p.*, n.nspname::text AS s, c.relname::text AS t, h.relname::text AS ht
        FROM par p
        JOIN pg_class c ON c.oid = p.moder_oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class h ON h.oid = p.h_oid
    ),
    moder_kol AS (
        SELECT p.moder_oid, a.attname::text AS kol, format_type(a.atttypid, a.atttypmod) AS typ
        FROM par_namn p
        JOIN pg_attribute a ON a.attrelid = p.moder_oid AND a.attnum > 0 AND NOT a.attisdropped
    ),
    h_kol AS (
        SELECT p.moder_oid, a.attname::text AS kol, format_type(a.atttypid, a.atttypmod) AS typ
        FROM par_namn p
        JOIN pg_attribute a ON a.attrelid = p.h_oid AND a.attnum > 0 AND NOT a.attisdropped
    ),
    trigger_fn AS (
        SELECT DISTINCT ON (t.tgrelid) t.tgrelid AS moder_oid, p.proname::text AS fn, p.prosrc
        FROM pg_trigger t
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE NOT t.tgisinternal
          AND p.proname ~ '^trg_fn_.+_qa$'
          AND t.tgrelid IN (SELECT moder_oid FROM par)
        ORDER BY t.tgrelid, p.proname
    ),
    -- Kolumnlistan i den första INSERT INTO ... (...) i triggerns kropp.
    -- Namn kan vara citerade ("order"), därav trim och ersättning av "".
    trigger_kol AS (
        SELECT f.moder_oid,
               replace(trim(BOTH '"' FROM trim(k)), '""', '"') AS kol
        FROM trigger_fn f,
             regexp_split_to_table(
                 substring(f.prosrc FROM 'INSERT INTO[^(]*\(([^)]*)\)'), ',') AS k
    )
    SELECT s, t, ht, 'saknas i historik', m.kol || ' ' || m.typ
    FROM par_namn p JOIN moder_kol m USING (moder_oid)
    WHERE NOT EXISTS (SELECT 1 FROM h_kol h WHERE h.moder_oid = p.moder_oid AND h.kol = m.kol)

    UNION ALL
    SELECT s, t, ht, 'typskillnad', format('%s: moder %s, historik %s', m.kol, m.typ, h.typ)
    FROM par_namn p
    JOIN moder_kol m USING (moder_oid)
    JOIN h_kol h ON h.moder_oid = p.moder_oid AND h.kol = m.kol
    WHERE h.typ <> m.typ

    UNION ALL
    SELECT s, t, ht, 'trigger: borttagen kolumn', f.fn || ' läser OLD.' || k.kol
    FROM par_namn p
    JOIN trigger_fn f USING (moder_oid)
    JOIN trigger_kol k USING (moder_oid)
    WHERE k.kol NOT IN ('h_typ', 'h_tidpunkt', 'h_av')
      AND NOT EXISTS (SELECT 1 FROM moder_kol m WHERE m.moder_oid = p.moder_oid AND m.kol = k.kol)

    UNION ALL
    SELECT s, t, ht, 'trigger: kolumn saknas', f.fn || ' kopierar inte ' || m.kol
    FROM par_namn p
    JOIN trigger_fn f USING (moder_oid)
    JOIN moder_kol m USING (moder_oid)
    WHERE NOT EXISTS (SELECT 1 FROM trigger_kol k WHERE k.moder_oid = p.moder_oid AND k.kol = m.kol)

    UNION ALL
    SELECT s, t, ht, 'ingen QA-trigger', NULL
    FROM par_namn p
    WHERE NOT EXISTS (SELECT 1 FROM trigger_fn f WHERE f.moder_oid = p.moder_oid)

    UNION ALL
    SELECT s, t, ht, 'ej i hex_metadata', 'hittad via namnkonventionen <tabell>_h'
    FROM par_namn p
    WHERE NOT p.i_metadata

    UNION ALL
    SELECT ag.schema_namn, ag.tabell_namn, NULL, 'afvaktande med geom',
           format('registrerad %s av %s', ag.registrerad, ag.registrerad_av)
    FROM public.hex_afvaktande_geometri ag
    WHERE EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = to_regclass(format('%I.%I', ag.schema_namn, ag.tabell_namn))
          AND a.attname = 'geom' AND NOT a.attisdropped
    )

    ORDER BY 1, 2, 4, 5;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_kontrollera_historik() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_kontrollera_historik()
    IS 'Listar tabeller vars historiktabell eller QA-trigger inte stämmer med
modertabellen: saknade kolumner, typskillnader, triggerkolumner som inte finns,
saknade triggers och afvaktande tabeller som fått geom. Läser bara; rätta med
hex_synka_historik() eller hex_underhall().';
