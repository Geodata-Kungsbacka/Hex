CREATE OR REPLACE FUNCTION public.hex_synka_objektnamn(
    p_schema text, p_tabell text, p_gammalt_namn text DEFAULT NULL
)
RETURNS integer LANGUAGE plpgsql
AS $BODY$
-- Följ objektens katalogkopplingar så att namnbyte inte delar funktioner
-- mellan tabeller. Samma rutin används av underhållet för äldre namn.
DECLARE
    moder oid := to_regclass(format('%I.%I', p_schema, p_tabell));
    gammalt text := coalesce(p_gammalt_namn, p_tabell);
    meta record;
    obj record;
    typ text;
    nytt text;
    kandidater oid[];
    fn oid;
    antal integer := 0;
BEGIN
    IF moder IS NULL THEN RETURN 0; END IF;
    SELECT * INTO meta FROM public.hex_metadata WHERE parent_oid = moder;

    FOREACH typ IN ARRAY ARRAY['qa', 'insert_audit'] LOOP
        -- En kvarvarande trigger är den säkraste källan, även när det gamla
        -- funktionsnamnet trunkerades eller tabellen redan har döpts om.
        SELECT array_agg(DISTINCT p.oid) INTO kandidater
        FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid = moder AND NOT t.tgisinternal
          AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = p_schema)
          AND ((typ = 'insert_audit' AND t.tgname = 'hex_tvinga_anvandarvarden')
            OR (typ = 'qa' AND (p.proname = meta.trigger_funktion
                OR t.tgname IN (public.hex_objektnamn(gammalt, 'qa_trigger'), public.hex_objektnamn(p_tabell, 'qa_trigger')))));
        IF kandidater IS NULL THEN
            SELECT array_agg(p.oid) INTO kandidater FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = p_schema AND p.pronargs = 0 AND p.prorettype = 'trigger'::regtype
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
        SELECT proname INTO nytt FROM pg_proc WHERE oid = fn;
        IF nytt <> public.hex_objektnamn(p_tabell, typ) THEN
            EXECUTE format('ALTER FUNCTION %s RENAME TO %I', fn::regprocedure, public.hex_objektnamn(p_tabell, typ));
            antal := antal + 1;
        END IF;
        IF typ = 'qa' THEN
            FOR obj IN SELECT tgname FROM pg_trigger WHERE tgrelid = moder AND tgfoid = fn AND NOT tgisinternal LOOP
                nytt := public.hex_objektnamn(p_tabell, 'qa_trigger');
                IF obj.tgname <> nytt THEN
                    EXECUTE format('ALTER TRIGGER %I ON %I.%I RENAME TO %I', obj.tgname, p_schema, p_tabell, nytt);
                    antal := antal + 1;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- Endast den sekvens som ägs av gid, inte manuella fristående sekvenser.
    FOR obj IN
        SELECT s.oid, s.relname, n.nspname FROM pg_class s
        JOIN pg_namespace n ON n.oid = s.relnamespace
        JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass
        JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S' AND d.refclassid = 'pg_class'::regclass
          AND d.refobjid = moder AND d.deptype IN ('a', 'i') AND a.attname = 'gid'
    LOOP
        nytt := public.hex_objektnamn(p_tabell, 'gid_sequence');
        IF obj.relname <> nytt THEN
            EXECUTE format('ALTER SEQUENCE %I.%I RENAME TO %I', obj.nspname, obj.relname, nytt);
            antal := antal + 1;
        END IF;
    END LOOP;

    IF meta.history_table IS NOT NULL THEN
    FOR obj IN
        SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE i.indrelid = to_regclass(format('%I.%I', p_schema, meta.history_table))
          AND c.relname IN (public.hex_objektnamn(gammalt, 'history_index'),
                           public.hex_objektnamn(p_tabell, 'history_index'),
                           (left(gammalt, 50) || '_h_idx')::name::text,
                           (left(p_tabell, 50) || '_h_idx')::name::text)
    LOOP
        nytt := public.hex_objektnamn(p_tabell, 'history_index');
        IF obj.relname <> nytt THEN
            EXECUTE format('ALTER INDEX %I.%I RENAME TO %I', p_schema, obj.relname, nytt);
            antal := antal + 1;
        END IF;
    END LOOP;
    END IF;
    PERFORM public.hex_registrera_metadata(p_schema, p_tabell);
    RETURN antal;
END;
$BODY$;
DO $$ BEGIN
    EXECUTE format('ALTER FUNCTION public.hex_synka_objektnamn(text, text, text) OWNER TO %I', public.hex_systemagare());
END $$;
COMMENT ON FUNCTION public.hex_synka_objektnamn(text, text, text) IS
    'Synkar Hex-funktioner, QA-trigger, gid-sekvens och historikindex med tabellens namn.';
