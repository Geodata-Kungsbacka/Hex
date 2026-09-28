CREATE OR REPLACE FUNCTION public.hex_synka_historik(
    p_schema_namn text,
    p_tabell_namn text
)
    RETURNS integer
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Synkroniserar historiktabellen med modertabellen och bygger om QA-triggern.
 *
 * INVARIANT
 * Historiktabellen innehåller allt modertabellen innehåller, och allt den
 * har innehållit. Konkret:
 *
 *   1. Varje kolumn i modertabellen finns i historiktabellen med samma typ.
 *   2. Kolumner som tagits bort ur modertabellen ligger kvar i
 *      historiktabellen med sina gamla värden. De tas aldrig bort.
 *   3. QA-triggerns kolumnlista speglar modertabellen som den ser ut nu.
 *
 * Funktionen är idempotent och kan köras hur ofta som helst. Den anropas av
 * hex_hantera_ny_kolumn() efter varje ALTER TABLE och av hex_underhall().
 *
 * TYPKONFLIKTER
 * Uppstår när en kolumn byter typ (ALTER COLUMN TYPE), eller tas bort och
 * läggs tillbaka med annan typ (fid bigint → fid text). Historiktabellens
 * kolumn får aldrig tappa värden, så konverteringen görs bara om varje
 * befintligt värde klarar vägen fram och tillbaka oförändrat:
 *
 *     gammal → ny typ → gammal typ, jämfört som text
 *
 * integer → text och varchar(50) → varchar(100) klarar det. numeric → integer
 * (avrundar), varchar(100) → varchar(10) (kapar) och text → integer (kastar
 * fel på 'abc') gör det inte. I de fallen döps den gamla kolumnen om till
 * <kolumn>_arkiv_<ÅÅÅÅMMDD> och en ny kolumn med rätt typ läggs till. De gamla
 * värdena finns då kvar orörda i arkivkolumnen.
 *
 * RETURVÄRDE
 * Antalet ändringar (tillagda, konverterade och arkiverade kolumner, borttagna
 * NOT NULL, samt 1 om QA-triggerns kropp ändrades). 0 betyder att allt redan
 * var synkroniserat. NULL om tabellen saknar historiktabell.
 ******************************************************************************/
DECLARE
    moder_oid    oid;
    h_tabell     text;
    h_oid        oid;
    kol          record;
    h_typ        text;
    forlust      boolean;
    konverterad  boolean;
    arkivnamn    text;
    suffix       text;
    lopnummer    integer;
    fn_oid       oid;
    kropp_fore   text;
    kropp_efter  text;
    kolumn_lista     text;
    old_kolumn_lista text;
    flagga       text;
    antal        integer := 0;
BEGIN
    moder_oid := to_regclass(format('%I.%I', p_schema_namn, p_tabell_namn));
    IF moder_oid IS NULL THEN
        RETURN NULL;
    END IF;

    -- hex_metadata först (följer med vid RENAME TO), namnkonventionen annars.
    -- Schemavillkoret skyddar mot en kvarlämnad post vars OID återanvänts av
    -- en tabell i ett annat schema.
    SELECT m.history_table INTO h_tabell
    FROM public.hex_metadata m
    WHERE m.parent_oid = moder_oid
      AND m.history_schema = p_schema_namn;

    IF h_tabell IS NULL THEN
        h_tabell := left(p_tabell_namn || '_h', 63);
    END IF;

    h_oid := to_regclass(format('%I.%I', p_schema_namn, h_tabell));
    IF h_oid IS NULL OR h_oid = moder_oid THEN
        RETURN NULL;
    END IF;

    -- Bara en riktig historiktabell synkas. Namnkonventionen ensam kan träffa
    -- en vanlig tabell som råkar heta <tabell>_h, och den ska inte få
    -- modertabellens kolumner.
    IF (SELECT count(*) FROM pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attname IN ('h_typ', 'h_tidpunkt', 'h_av')
          AND NOT a.attisdropped) <> 3 THEN
        RETURN NULL;
    END IF;

    -- Våra egna ALTER TABLE mot historiktabellen ska inte starta
    -- kolumnomstrukturering i hex_hantera_ny_kolumn().
    flagga := current_setting('temp.reorganization_in_progress', true);
    PERFORM set_config('temp.reorganization_in_progress', 'true', true);

    -- 1. Modertabellens kolumner, i ordning
    FOR kol IN
        SELECT a.attname::text AS namn,
               format_type(a.atttypid, a.atttypmod) AS typ
        FROM pg_attribute a
        WHERE a.attrelid = moder_oid
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        h_typ := NULL;
        SELECT format_type(a.atttypid, a.atttypmod) INTO h_typ
        FROM pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attname = kol.namn
          AND a.attnum > 0
          AND NOT a.attisdropped;

        -- 1a. Saknas i historiktabellen
        IF h_typ IS NULL THEN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN %I %s',
                p_schema_namn, h_tabell, kol.namn, kol.typ);
            antal := antal + 1;
            RAISE NOTICE '[hex_synka_historik] ✓ %.%: kolumn % (%) tillagd',
                p_schema_namn, h_tabell, kol.namn, kol.typ;
            CONTINUE;
        END IF;

        CONTINUE WHEN h_typ = kol.typ;

        -- 1b. Typkonflikt: konvertera bara om inget värde ändras
        BEGIN
            EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %I.%I WHERE %I IS NOT NULL'
                ' AND ((%I::%s)::%s)::text IS DISTINCT FROM %I::text)',
                p_schema_namn, h_tabell, kol.namn,
                kol.namn, kol.typ, h_typ, kol.namn)
            INTO forlust;
        EXCEPTION
            WHEN OTHERS THEN
                forlust := true;  -- Något värde går inte att konvertera alls
        END;

        konverterad := false;
        IF NOT forlust THEN
            BEGIN
                EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE %s USING %I::%s',
                    p_schema_namn, h_tabell, kol.namn, kol.typ, kol.namn, kol.typ);
                konverterad := true;
                antal := antal + 1;
                RAISE NOTICE '[hex_synka_historik] ✓ %.%: kolumn % konverterad % → %',
                    p_schema_namn, h_tabell, kol.namn, h_typ, kol.typ;
            EXCEPTION
                WHEN OTHERS THEN
                    konverterad := false;
            END;
        END IF;

        -- 1c. Arkivera den gamla kolumnen och lägg till en ny
        IF NOT konverterad THEN
            suffix := '_arkiv_' || to_char(now(), 'YYYYMMDD');
            lopnummer := 1;
            LOOP
                arkivnamn := left(kol.namn, 63 - length(suffix)) || suffix;
                EXIT WHEN NOT EXISTS (
                    SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = h_oid AND a.attname = arkivnamn AND NOT a.attisdropped
                );
                lopnummer := lopnummer + 1;
                suffix := '_arkiv_' || to_char(now(), 'YYYYMMDD') || '_' || lopnummer;
            END LOOP;

            EXECUTE format('ALTER TABLE %I.%I RENAME COLUMN %I TO %I',
                p_schema_namn, h_tabell, kol.namn, arkivnamn);
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN %I %s',
                p_schema_namn, h_tabell, kol.namn, kol.typ);
            antal := antal + 1;
            RAISE WARNING '[hex_synka_historik] %.%: kolumn % bytte typ % → % och kan inte konverteras utan förlust. Gamla värden bevarade i %',
                p_schema_namn, h_tabell, kol.namn, h_typ, kol.typ, arkivnamn;
        END IF;
    END LOOP;

    -- 2. Kolumner som bara finns kvar i historiken får aldrig blockera
    --    QA-triggerns INSERT. h_-kolumnerna är historiktabellens egna.
    FOR kol IN
        SELECT a.attname::text AS namn
        FROM pg_attribute a
        WHERE a.attrelid = h_oid
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attnotnull
          AND a.attname NOT IN ('h_typ', 'h_tidpunkt', 'h_av')
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP NOT NULL',
            p_schema_namn, h_tabell, kol.namn);
        antal := antal + 1;
        RAISE NOTICE '[hex_synka_historik] ✓ %.%: NOT NULL borttagen på %',
            p_schema_namn, h_tabell, kol.namn;
    END LOOP;

    -- 3. QA-triggern. Räknas som ändring bara om kroppen faktiskt ändrades,
    --    så att hex_underhall() kan rapportera 'redan synkad'.
    SELECT t.tgfoid INTO fn_oid
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE t.tgrelid = moder_oid
      AND NOT t.tgisinternal
      AND p.proname ~ '^trg_fn_.+_qa$'
    LIMIT 1;

    IF fn_oid IS NOT NULL THEN
        SELECT prosrc INTO kropp_fore FROM pg_proc WHERE oid = fn_oid;

        -- Triggern är aktuell om kroppen innehåller exakt den INSERT och den
        -- %ROWTYPE som hex_aterskapa_qa_trigger() skulle skriva. Då byggs den
        -- inte om, så att ALTER TABLE OWNER TO och liknande inte ersätter
        -- funktionen i onödan. En kropp i äldre format byggs om en gång.
        SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum),
               string_agg(format('OLD.%I', a.attname), ', ' ORDER BY a.attnum)
        INTO kolumn_lista, old_kolumn_lista
        FROM pg_attribute a
        WHERE a.attrelid = moder_oid AND a.attnum > 0 AND NOT a.attisdropped;

        IF position(format('INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)',
                           p_schema_namn, h_tabell, kolumn_lista) IN kropp_fore) = 0
           OR position(format('session_user, %s;', old_kolumn_lista) IN kropp_fore) = 0
           OR position(format('rad %I.%I%%ROWTYPE;', p_schema_namn, p_tabell_namn) IN kropp_fore) = 0
        THEN
            -- Misslyckas ombyggnaden avbryts hela ALTER TABLE. En trigger som
            -- inte speglar tabellen tappar historik tyst, och det är värre
            -- än att DDL:en nekas.
            IF NOT public.hex_aterskapa_qa_trigger(p_schema_namn, p_tabell_namn, h_tabell) THEN
                RAISE EXCEPTION '[hex_synka_historik] QA-triggern för %.% kunde inte byggas om – se WARNING ovan. Ändringen avbryts så att ingen historik går förlorad.',
                    p_schema_namn, p_tabell_namn;
            END IF;
            SELECT prosrc INTO kropp_efter FROM pg_proc WHERE oid = fn_oid;
            IF kropp_fore IS DISTINCT FROM kropp_efter THEN
                antal := antal + 1;
            END IF;
        END IF;
    ELSE
        RAISE NOTICE '[hex_synka_historik] %.% har historiktabell men ingen QA-trigger – hex_underhall() återkopplar den',
            p_schema_namn, p_tabell_namn;
    END IF;

    PERFORM set_config('temp.reorganization_in_progress', coalesce(flagga, 'false'), true);
    RETURN antal;

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('temp.reorganization_in_progress', coalesce(flagga, 'false'), true);
        RAISE;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_synka_historik(text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_synka_historik(text, text)
    IS 'Synkroniserar historiktabellen med modertabellen: lägger till saknade
kolumner, konverterar typer utan förlust eller arkiverar den gamla kolumnen, och
bygger om QA-triggern. Kolumner som tagits bort ur modertabellen behålls i
historiken. Idempotent. Returnerar antal ändringar, NULL om historik saknas.';
