CREATE OR REPLACE FUNCTION public.hex_sakerstall_geomindex(
    p_schema text, p_tabell text, p_kolumn text
)
RETURNS text LANGUAGE plpgsql
AS $BODY$
-- Gemensam för hex_hantera_ny_tabell, hex_hantera_ny_kolumn och
-- hex_underhall: ett GiST-index på geometrikolumnen, med namn från
-- hex_objektnamn(). Returnerar namnet på indexet tabellen fick.
--
-- Tidigare användes CREATE INDEX IF NOT EXISTS med ett härlett namn. Ägdes
-- namnet redan av en annan tabells index (t.ex. en tabell som döpts om och
-- vars index behållit det gamla namnet) hoppades skapandet över tyst och
-- tabellen saknade spatialt index.
DECLARE
    index_namn text := public.hex_objektnamn(p_tabell, 'geom_index');
    moder      oid  := to_regclass(format('%I.%I', p_schema, p_tabell));
    r          record;
BEGIN
    -- Ta bort GiST-index med annat namn (t.ex. FME-skapade) för att undvika dubbletter
    FOR r IN
        SELECT c.relname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam AND am.amname = 'gist'
        WHERE i.indrelid = moder AND c.relname <> index_namn
    LOOP
        EXECUTE format('DROP INDEX %I.%I', p_schema, r.relname);
        RAISE NOTICE '[hex_sakerstall_geomindex]   ✓ Dubblerat GiST-index borttaget: %', r.relname;
    END LOOP;

    IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
               WHERE i.indrelid = moder AND c.relname = index_namn) THEN
        RETURN index_namn;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = p_schema AND c.relname = index_namn) THEN
        -- Namnet tillhör ett annat objekt i schemat. Ett index utan namn är
        -- bättre än inget index; hex_underhall() byter namn när det frigjorts.
        RAISE WARNING '[hex_sakerstall_geomindex] %.% är upptaget; GiST-indexet på %.% får ett namn från PostgreSQL.',
            p_schema, index_namn, p_schema, p_tabell;
        EXECUTE format('CREATE INDEX ON %I.%I USING GIST (%I)', p_schema, p_tabell, p_kolumn);
        SELECT c.relname INTO index_namn
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam AND am.amname = 'gist'
        WHERE i.indrelid = moder;
        RETURN index_namn;
    END IF;

    EXECUTE format('CREATE INDEX %I ON %I.%I USING GIST (%I)', index_namn, p_schema, p_tabell, p_kolumn);
    RETURN index_namn;
END;
$BODY$;
DO $$ BEGIN
    EXECUTE format('ALTER FUNCTION public.hex_sakerstall_geomindex(text, text, text) OWNER TO %I', public.hex_systemagare());
END $$;
COMMENT ON FUNCTION public.hex_sakerstall_geomindex(text, text, text) IS
    'Säkerställer ett GiST-index på geometrikolumnen med namn från hex_objektnamn(). Returnerar indexets namn.';
