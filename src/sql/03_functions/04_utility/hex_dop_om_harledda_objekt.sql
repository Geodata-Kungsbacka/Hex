CREATE OR REPLACE FUNCTION public.hex_dop_om_harledda_objekt(
    p_parent_oid   oid,
    p_gammalt_namn text
)
    RETURNS integer
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Döper om de objekt som Hex namnger efter tabellen när tabellen döps om med
 * ALTER TABLE ... RENAME TO.
 *
 * Anropas av hex_hantera_ny_kolumn() i RENAME TO-grenen, efter att
 * historiktabellen döpts om. Tabellens schema och nya namn läses ur pg_class
 * via OID:n; det gamla namnet kommer från hex_metadata.
 *
 * Utan omdöpningen blir objekten kvar under det gamla namnet. Då går det inte
 * att skapa en ny tabell med det gamla namnet (sekvensen och historikindexet
 * finns redan), och lyckas det ändå skriver hex_skapa_historik_qa() över
 * trg_fn_<gammalt namn>_qa, som den omdöpta tabellens trigger fortfarande
 * anropar. Därefter kraschar UPDATE och DELETE på den omdöpta tabellen.
 *
 * Objekt som döps om (gammalt → nytt):
 *   <tabell>_<kolumn>_seq        identitets- och serial-sekvenser
 *   left(<tabell>,50)_h_idx      historikindexet
 *   left(<tabell>,50)_geom_gidx  GiST-indexet
 *   validera_geom_<tabell>       geometrivalideringen
 *   trg_<tabell>_qa              QA-triggern
 *   trg_fn_<tabell>_qa           QA-triggerfunktionen
 *   trg_fn_<tabell>_insert_audit INSERT-triggerfunktionen
 *
 * Bara objekt som bär det gamla härledda namnet berörs; ett objekt som någon
 * döpt om för hand lämnas i fred. Är det nya namnet redan upptaget, eller
 * längre än 63 tecken, behålls det gamla med en WARNING respektive NOTICE.
 * Triggerfunktionerna hittas via sina triggrar och känns igen på suffixen
 * _qa och _insert_audit, så ett trunkerat namn skulle göra dem omöjliga att
 * hitta.
 *
 * RETURVÄRDE
 * Antal omdöpta objekt.
 ******************************************************************************/
DECLARE
    s         text;
    t         text;
    h_oid     oid;
    r         record;
    nytt      text;
    antal     integer := 0;
BEGIN
    SELECT n.nspname, c.relname INTO s, t
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_parent_oid AND c.relkind = 'r';

    IF t IS NULL OR p_gammalt_namn IS NULL OR t = p_gammalt_namn THEN
        RETURN 0;
    END IF;

    -- Relationer: sekvenser, historikindex och GiST-index. Alla delar
    -- namnrymd med tabellerna i schemat, så ett upptaget namn kollas mot
    -- pg_class.
    h_oid := to_regclass(format('%I.%I', s, left(t || '_h', 63)));

    FOR r IN
        -- Sekvenser som ägs av en kolumn i tabellen (IDENTITY och serial)
        SELECT sq.relname AS namn, 'SEQUENCE' AS typ,
               left(t, 63 - length(a.attname) - 5) || '_' || a.attname || '_seq' AS nytt,
               p_gammalt_namn || '_' || a.attname || '_seq' AS harlett
        FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_class sq ON sq.oid = d.objid AND sq.relkind = 'S'
        JOIN pg_catalog.pg_attribute a
          ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE d.classid = 'pg_catalog.pg_class'::regclass
          AND d.refobjid = p_parent_oid
          AND d.deptype IN ('a', 'i')
        UNION ALL
        SELECT ic.relname, 'INDEX',
               left(t, 50) || '_h_idx',
               left(p_gammalt_namn, 50) || '_h_idx'
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
        WHERE i.indrelid = h_oid
        UNION ALL
        SELECT ic.relname, 'INDEX',
               left(t, 50) || '_geom_gidx',
               left(p_gammalt_namn, 50) || '_geom_gidx'
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
        WHERE i.indrelid = p_parent_oid
    LOOP
        -- Bara objekt som bär det namn Hex gav dem
        CONTINUE WHEN r.namn <> r.harlett OR r.namn = r.nytt;

        IF to_regclass(format('%I.%I', s, r.nytt)) IS NOT NULL THEN
            RAISE WARNING '[hex_dop_om_harledda_objekt] %.% döps inte om: % finns redan',
                s, r.namn, r.nytt;
            CONTINUE;
        END IF;

        EXECUTE format('ALTER %s %I.%I RENAME TO %I', r.typ, s, r.namn, r.nytt);
        antal := antal + 1;
        RAISE NOTICE '[hex_dop_om_harledda_objekt] ✓ % %.% → %', r.typ, s, r.namn, r.nytt;
    END LOOP;

    -- Geometrivalideringen. Constraintnamn är unika per tabell, inte per
    -- schema, så det räcker att kolla tabellen.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
               WHERE conrelid = p_parent_oid
                 AND conname = left('validera_geom_' || p_gammalt_namn, 63))
       AND length('validera_geom_' || t) <= 63
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
                       WHERE conrelid = p_parent_oid
                         AND conname = 'validera_geom_' || t)
    THEN
        EXECUTE format('ALTER TABLE %I.%I RENAME CONSTRAINT %I TO %I',
            s, t, left('validera_geom_' || p_gammalt_namn, 63), 'validera_geom_' || t);
        antal := antal + 1;
        RAISE NOTICE '[hex_dop_om_harledda_objekt] ✓ %.%: constraint validera_geom_% → validera_geom_%',
            s, t, p_gammalt_namn, t;
    END IF;

    -- Triggerfunktionerna hittas via triggrarna, inte via namnet: det är
    -- funktionen som triggern faktiskt anropar som ska följa med.
    FOR r IN
        SELECT t2.tgname, p.oid AS fn_oid, p.proname AS namn,
               CASE WHEN p.proname = 'trg_fn_' || p_gammalt_namn || '_qa'
                    THEN 'trg_fn_' || t || '_qa'
                    WHEN p.proname = 'trg_fn_' || p_gammalt_namn || '_insert_audit'
                    THEN 'trg_fn_' || t || '_insert_audit'
               END AS nytt
        FROM pg_catalog.pg_trigger t2
        JOIN pg_catalog.pg_proc p ON p.oid = t2.tgfoid
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE t2.tgrelid = p_parent_oid
          AND NOT t2.tgisinternal
          AND n.nspname = s
    LOOP
        CONTINUE WHEN r.nytt IS NULL;

        IF length(r.nytt) > 63 THEN
            RAISE NOTICE '[hex_dop_om_harledda_objekt] %.%() behåller sitt namn: % är längre än 63 tecken',
                s, r.namn, r.nytt;
            CONTINUE;
        END IF;

        IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                   JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = s AND p.proname = r.nytt) THEN
            RAISE WARNING '[hex_dop_om_harledda_objekt] %.%() döps inte om: %() finns redan',
                s, r.namn, r.nytt;
            CONTINUE;
        END IF;

        EXECUTE format('ALTER FUNCTION %I.%I() RENAME TO %I', s, r.namn, r.nytt);
        antal := antal + 1;
        RAISE NOTICE '[hex_dop_om_harledda_objekt] ✓ %: %() → %()', s, r.namn, r.nytt;
    END LOOP;

    -- QA-triggern. Triggernamn är unika per tabell.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
               WHERE tgrelid = p_parent_oid
                 AND tgname = left('trg_' || p_gammalt_namn || '_qa', 63))
       AND length('trg_' || t || '_qa') <= 63
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
                       WHERE tgrelid = p_parent_oid
                         AND tgname = 'trg_' || t || '_qa')
    THEN
        EXECUTE format('ALTER TRIGGER %I ON %I.%I RENAME TO %I',
            left('trg_' || p_gammalt_namn || '_qa', 63), s, t, 'trg_' || t || '_qa');
        antal := antal + 1;
        RAISE NOTICE '[hex_dop_om_harledda_objekt] ✓ %.%: trigger trg_%_qa → trg_%_qa',
            s, t, p_gammalt_namn, t;
    END IF;

    RETURN antal;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_dop_om_harledda_objekt(oid, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_dop_om_harledda_objekt(oid, text)
    IS 'Döper om sekvenser, index, geometrivalidering, QA-trigger och triggerfunktioner
som Hex namngett efter tabellen, efter ALTER TABLE RENAME TO. Returnerar antal omdöpta objekt.';
