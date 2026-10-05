CREATE OR REPLACE FUNCTION public.hex_synka_objektnamn(
    p_schema text, p_tabell text, p_gammalt_namn text DEFAULT NULL,
    p_varna boolean DEFAULT true
)
RETURNS integer LANGUAGE plpgsql
AS $BODY$
-- Följ objektens katalogkopplingar så att namnbyte inte delar funktioner
-- mellan tabeller. Samma rutin används av underhållet för äldre namn.
--
-- p_varna styr hur ett upptaget relationsnamn (sekvens, index, primärnyckel)
-- rapporteras: WARNING när anropet är sista chansen, NOTICE när underhållet
-- gör ett första varv och ett senare varv kan hitta namnet ledigt.
DECLARE
    moder oid := to_regclass(format('%I.%I', p_schema, p_tabell));
    schema_oid oid := (SELECT oid FROM pg_namespace WHERE nspname = p_schema);
    gammalt text := coalesce(p_gammalt_namn, p_tabell);
    meta record;
    obj record;
    typ text;
    nytt text;
    kandidater oid[];
    fn oid;
    upptagen record;
    qa_namn text;
    antal integer := 0;
BEGIN
    IF moder IS NULL THEN RETURN 0; END IF;
    SELECT * INTO meta FROM public.hex_metadata WHERE parent_oid = moder;
    -- Ett namnbyte i en äldre version uppdaterade metadata men lämnade
    -- funktions- och indexnamnet kvar. Det äldre QA-namnet ger då ursprunget.
    IF p_gammalt_namn IS NULL AND meta.trigger_funktion ~ '^trg_fn_.+_qa$' THEN
        gammalt := substring(meta.trigger_funktion FROM '^trg_fn_(.+)_qa$');
    END IF;

    FOREACH typ IN ARRAY ARRAY['qa', 'insert_audit'] LOOP
        -- En kvarvarande trigger är den säkraste källan, även när det gamla
        -- funktionsnamnet trunkerades eller tabellen redan har döpts om.
        SELECT array_agg(DISTINCT p.oid) INTO kandidater
        FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid = moder AND NOT t.tgisinternal
          AND p.pronamespace = schema_oid
          AND ((typ = 'insert_audit' AND t.tgname = 'hex_tvinga_anvandarvarden')
            OR (typ = 'qa' AND (p.proname = meta.trigger_funktion
                OR t.tgname IN (public.hex_objektnamn(gammalt, 'qa_trigger'), public.hex_objektnamn(p_tabell, 'qa_trigger')))));
        IF kandidater IS NULL THEN
            SELECT array_agg(p.oid) INTO kandidater FROM pg_proc p
            WHERE p.pronamespace = schema_oid AND p.pronargs = 0 AND p.prorettype = 'trigger'::regtype
              AND (p.proname IN (public.hex_objektnamn(gammalt, typ), public.hex_objektnamn(p_tabell, typ),
                       ('trg_fn_' || gammalt || '_' || typ)::name::text,
                       ('trg_fn_' || p_tabell || '_' || typ)::name::text)
                OR (typ = 'qa' AND p.proname = meta.trigger_funktion));
        END IF;
        IF coalesce(cardinality(kandidater), 0) > 1 THEN
            RAISE EXCEPTION 'Flera Hex-funktioner för %.% (%); rätta kopplingen före underhåll.', p_schema, p_tabell, typ;
        END IF;
        fn := kandidater[1];
        IF fn IS NULL THEN CONTINUE; END IF;
        IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgfoid = fn AND tgrelid <> moder) THEN
            RAISE EXCEPTION 'Hex-funktionen % delas mellan tabeller; namnbytet avbryts.', fn::regprocedure;
        END IF;
        nytt := public.hex_objektnamn(p_tabell, typ);
        IF (SELECT proname FROM pg_proc WHERE oid = fn) <> nytt THEN
            -- Målnamnet kan vara upptaget av en funktion som äldre versioner
            -- lämnade kvar vid DROP TABLE (insert_audit togs inte bort). En
            -- sådan anropas inte av någon trigger och tas bort; utan CASCADE,
            -- så att ett oväntat beroende avbryter i stället för att raderas.
            -- Används den av en trigger tillhör den en annan tabell.
            SELECT p.oid, EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgfoid = p.oid) AS anvands,
                   p.prorettype = 'trigger'::regtype AS ar_trigger
            INTO upptagen
            FROM pg_proc p
            WHERE p.pronamespace = schema_oid AND p.proname = nytt AND p.pronargs = 0;
            IF upptagen.oid IS NOT NULL THEN
                IF upptagen.anvands OR NOT upptagen.ar_trigger THEN
                    RAISE EXCEPTION 'Funktionsnamnet %.%() är upptaget; Hex-objekten för %.% kan inte döpas om.',
                        p_schema, nytt, p_schema, p_tabell
                        USING HINT = 'Funktionen används av en annan tabell eller är ingen triggerfunktion. '
                                     'Döp om eller ta bort den och försök igen.';
                END IF;
                EXECUTE format('DROP FUNCTION %s', upptagen.oid::regprocedure);
                RAISE NOTICE '[hex_synka_objektnamn] Kvarlämnad funktion %.%() borttagen', p_schema, nytt;
                antal := antal + 1;
            END IF;
            EXECUTE format('ALTER FUNCTION %s RENAME TO %I', fn::regprocedure, nytt);
            antal := antal + 1;
        END IF;
        IF typ = 'qa' THEN
            qa_namn := nytt;
            FOR obj IN SELECT tgname FROM pg_trigger WHERE tgrelid = moder AND tgfoid = fn AND NOT tgisinternal LOOP
                nytt := public.hex_objektnamn(p_tabell, 'qa_trigger');
                IF obj.tgname <> nytt THEN
                    EXECUTE format('ALTER TRIGGER %I ON %I.%I RENAME TO %I', obj.tgname, p_schema, p_tabell, nytt);
                    antal := antal + 1;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- Relationer vars namn härleds ur tabellnamnet. Ett index som bär en
    -- primärnyckel döps om med ALTER INDEX, vilket även döper om constrainten.
    FOR obj IN
        -- Endast den sekvens som ägs av gid, inte manuella fristående sekvenser.
        SELECT s.relname::text AS namn, 'gid_sequence' AS typ, 'SEQUENCE' AS sats
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass
        JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S' AND d.refclassid = 'pg_class'::regclass
          AND d.refobjid = moder AND d.deptype IN ('a', 'i') AND a.attname = 'gid'
        UNION ALL
        SELECT c.relname::text, 'history_index', 'INDEX'
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE meta.history_table IS NOT NULL
          AND i.indrelid = to_regclass(format('%I.%I', p_schema, meta.history_table))
          AND c.relname IN (public.hex_objektnamn(gammalt, 'history_index'),
                            public.hex_objektnamn(p_tabell, 'history_index'),
                            (left(gammalt, 50) || '_h_idx')::name::text,
                            (left(p_tabell, 50) || '_h_idx')::name::text)
        UNION ALL
        -- GiST-indexet på geom. Bara när det är entydigt: finns flera rörs inget.
        SELECT min(c.relname::text), 'geom_index', 'INDEX'
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam AND am.amname = 'gist'
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = moder AND i.indnatts = 1 AND a.attname = 'geom'
        HAVING count(*) = 1
        UNION ALL
        -- Hex primärnyckel ligger alltid på enbart gid.
        SELECT c.relname::text, 'pkey', 'INDEX'
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conindid
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
        WHERE con.conrelid = moder AND con.contype = 'p'
          AND cardinality(con.conkey) = 1 AND a.attname = 'gid'
    LOOP
        nytt := public.hex_objektnamn(p_tabell, obj.typ);
        CONTINUE WHEN obj.namn = nytt;
        -- Index och sekvenser delar namnrymd per schema. Är namnet upptaget
        -- (t.ex. av en tabell som döptes om i en äldre version och ännu inte
        -- synkats) lämnas objektet som det är i stället för att avbryta.
        IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = schema_oid AND relname = nytt) THEN
            IF p_varna THEN
                RAISE WARNING '[hex_synka_objektnamn] %.% kan inte döpas om till %: namnet är upptaget.',
                    p_schema, obj.namn, nytt;
            ELSE
                RAISE NOTICE '[hex_synka_objektnamn] %.% väntar: % är upptaget.', p_schema, obj.namn, nytt;
            END IF;
            CONTINUE;
        END IF;
        EXECUTE format('ALTER %s %I.%I RENAME TO %I', obj.sats, p_schema, obj.namn, nytt);
        antal := antal + 1;
    END LOOP;

    -- Metadata registreras om bara när något ändrats eller pekar fel, så att
    -- underhållet inte skriver om varje tabells rad vid varje körning.
    IF antal > 0 OR meta.parent_oid IS NULL
       OR meta.trigger_funktion IS DISTINCT FROM qa_namn THEN
        PERFORM public.hex_registrera_metadata(p_schema, p_tabell);
    END IF;
    RETURN antal;
END;
$BODY$;
DO $$ BEGIN
    EXECUTE format('ALTER FUNCTION public.hex_synka_objektnamn(text, text, text, boolean) OWNER TO %I', public.hex_systemagare());
END $$;
COMMENT ON FUNCTION public.hex_synka_objektnamn(text, text, text, boolean) IS
    'Synkar Hex-funktioner, QA-trigger, gid-sekvens, historikindex, GiST-index och primärnyckel med tabellens namn.';
