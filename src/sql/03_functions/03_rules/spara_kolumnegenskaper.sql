-- FUNCTION: public.spara_kolumnegenskaper(text, text)

-- DROP FUNCTION IF EXISTS public.spara_kolumnegenskaper(text, text);

CREATE OR REPLACE FUNCTION public.spara_kolumnegenskaper(
	p_schema_namn text,
	p_tabell_namn text)
    RETURNS kolumnegenskaper
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion sparar kolumnspecifika egenskaper som sedan kan användas
 * vid omstrukturering av tabeller. Funktionen separerar egenskaper som bara
 * påverkar enskilda kolumner från egentliga tabellregler.
 *
 * Funktionen sparar:
 * 1. DEFAULT-värden
 *    - Alla DEFAULT-värden för kolumner
 *    - Format: kolumnnamn;värde
 * 
 * 2. NOT NULL-begränsningar
 *    - Icke-null begränsningar för kolumner
 *    - Format: kolumnnamn
 * 
 * 3. Kolumnspecifika CHECK-begränsningar
 *    - CHECK-begränsningar som bara refererar till en kolumn
 *    - Format: konstraintnamn;kolumnnamn;definition
 * 
 * 4. IDENTITY-definitioner
 *    - Kolumner skapade som IDENTITY
 *    - Format: kolumnnamn;definition
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [spara_kolumnegenskaper]
 * - Tydliga steg-markörer visar progression
 * - Detaljerad information för varje egenskap
 * - Slutresultat sammanfattas
 ******************************************************************************/
DECLARE
    resultat kolumnegenskaper;   -- Variabel som håller alla kolumnegenskaper
    tabell_oid oid;             -- Tabellens unika PostgreSQL-ID
    antal_default integer;      -- För statistik
    antal_notnull integer;      -- För statistik
    antal_check integer;        -- För statistik
    antal_identity integer;     -- För statistik
BEGIN
    RAISE NOTICE E'[spara_kolumnegenskaper] === START ===';
    RAISE NOTICE '[spara_kolumnegenskaper] Analyserar kolumnegenskaper för %.%', p_schema_namn, p_tabell_namn;
    
    -- Steg 1: Hämta tabellens OID
    RAISE NOTICE '[spara_kolumnegenskaper] Steg 1: Hämtar tabellidentifierare';
    SELECT c.oid INTO STRICT tabell_oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema_namn
    AND c.relname = p_tabell_namn;

    RAISE NOTICE '[spara_kolumnegenskaper]   » Tabell-OID: %', tabell_oid;

    -- Steg 2: Spara DEFAULT-värden
    RAISE NOTICE '[spara_kolumnegenskaper] Steg 2: Analyserar DEFAULT-värden';
    WITH default_data AS (
        SELECT format('%s;%s', 
            attname, 
            pg_get_expr(adbin, adrelid)
        ) as defdef
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON (a.attrelid, a.attnum) = (d.adrelid, d.adnum)
        WHERE attrelid = tabell_oid
        AND NOT attisdropped        -- Skippa borttagna kolumner
        AND adbin IS NOT NULL      -- Har ett default-värde
        AND attgenerated = ''      -- Inte en generated kolumn
    )
    SELECT array_agg(defdef), COUNT(*)
    INTO resultat.default_defs, antal_default
    FROM default_data;

    IF antal_default > 0 THEN
        RAISE NOTICE '[spara_kolumnegenskaper]   » Hittade % DEFAULT-värden:', antal_default;
        FOR i IN 1..antal_default LOOP
            RAISE NOTICE '[spara_kolumnegenskaper]     #%: %', i, resultat.default_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_kolumnegenskaper]   » Inga DEFAULT-värden hittades';
    END IF;

    -- Steg 3: Spara NOT NULL-begränsningar 
    RAISE NOTICE '[spara_kolumnegenskaper] Steg 3: Analyserar NOT NULL-begränsningar';
    WITH notnull_data AS (
        SELECT attname
        FROM pg_attribute
        WHERE attrelid = tabell_oid
        AND NOT attisdropped
        AND attnotnull            -- Kolumn har NOT NULL
        AND attnum > 0           -- Skip system columns
    )
    SELECT array_agg(attname), COUNT(*)
    INTO resultat.notnull_defs, antal_notnull
    FROM notnull_data;

    IF antal_notnull > 0 THEN
        RAISE NOTICE '[spara_kolumnegenskaper]   » Hittade % NOT NULL-begränsningar:', antal_notnull;
        FOR i IN 1..antal_notnull LOOP
            RAISE NOTICE '[spara_kolumnegenskaper]     #%: %', i, resultat.notnull_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_kolumnegenskaper]   » Inga NOT NULL-begränsningar hittades';
    END IF;

    -- Steg 4: Spara kolumnspecifika CHECK-begränsningar
    RAISE NOTICE '[spara_kolumnegenskaper] Steg 4: Analyserar kolumnspecifika CHECK-begränsningar';
    
    -- Hitta CHECK-begränsningar som bara refererar en kolumn
    WITH check_data AS (
        SELECT 
            con.conname as constraint_name,
            att.attname as column_name,
            pg_get_constraintdef(con.oid) as definition
        FROM pg_constraint con
        JOIN pg_attribute att ON att.attrelid = con.conrelid
        -- Joina för att få kolumner som används i CHECK-satsen
        JOIN LATERAL unnest(con.conkey) WITH ORDINALITY cols(colnum, ord) 
            ON att.attnum = cols.colnum
        WHERE con.conrelid = tabell_oid
        AND con.contype = 'c'  -- 'c' = check
        -- Gruppera på constraintnamn och räkna antal kolumner
        GROUP BY con.conname, att.attname, con.oid
        -- Filter: Bara constraints med en refererad kolumn
        HAVING COUNT(*) = 1
    )
    SELECT 
        array_agg(format('%s;%s;%s', constraint_name, column_name, definition)),
        COUNT(*)
    INTO 
        resultat.check_defs, antal_check
    FROM check_data;

    IF antal_check > 0 THEN
        RAISE NOTICE '[spara_kolumnegenskaper]   » Hittade % kolumnspecifika CHECK-begränsningar:', antal_check;
        FOR i IN 1..antal_check LOOP
            RAISE NOTICE '[spara_kolumnegenskaper]     #%: %', i, resultat.check_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_kolumnegenskaper]   » Inga kolumnspecifika CHECK-begränsningar hittades';
    END IF;

    -- Steg 5: Spara IDENTITY-definitioner
    RAISE NOTICE '[spara_kolumnegenskaper] Steg 5: Analyserar IDENTITY-kolumner';
    WITH identity_data AS (
        SELECT 
            attname,
            pg_get_serial_sequence(p_schema_namn || '.' || p_tabell_namn, attname) as sequence_name
        FROM pg_attribute
        WHERE attrelid = tabell_oid
        AND NOT attisdropped
        AND attidentity != ''  -- '' = not identity, 'a' = always, 'd' = default
    )
    SELECT 
        array_agg(format('%s;%s', 
            attname, 
            CASE attidentity 
                WHEN 'a' THEN 'GENERATED ALWAYS AS IDENTITY'
                WHEN 'd' THEN 'GENERATED BY DEFAULT AS IDENTITY'
                ELSE ''
            END
        )),
        COUNT(*)
    INTO 
        resultat.identity_defs, antal_identity
    FROM pg_attribute
    WHERE attrelid = tabell_oid
    AND NOT attisdropped
    AND attidentity != '';  -- '' = not identity, 'a' = always, 'd' = default

    IF antal_identity > 0 THEN
        RAISE NOTICE '[spara_kolumnegenskaper]   » Hittade % IDENTITY-kolumner:', antal_identity;
        FOR i IN 1..antal_identity LOOP
            RAISE NOTICE '[spara_kolumnegenskaper]     #%: %', i, resultat.identity_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_kolumnegenskaper]   » Inga IDENTITY-kolumner hittades';
    END IF;

    -- Summera resultatet
    RAISE NOTICE '[spara_kolumnegenskaper] Sammanfattning:';
    RAISE NOTICE '[spara_kolumnegenskaper]   » DEFAULT-värden:      %', COALESCE(antal_default, 0);
    RAISE NOTICE '[spara_kolumnegenskaper]   » NOT NULL:            %', COALESCE(antal_notnull, 0);
    RAISE NOTICE '[spara_kolumnegenskaper]   » Kolumn-CHECK:        %', COALESCE(antal_check, 0);
    RAISE NOTICE '[spara_kolumnegenskaper]   » IDENTITY-kolumner:   %', COALESCE(antal_identity, 0);
    RAISE NOTICE '[spara_kolumnegenskaper] === SLUT ===';

    RETURN resultat;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE NOTICE '[spara_kolumnegenskaper] !!! FEL UPPSTOD !!!';
        RAISE EXCEPTION '[spara_kolumnegenskaper] Tabell %.% existerar inte', 
            p_schema_namn, p_tabell_namn;
    WHEN TOO_MANY_ROWS THEN
        RAISE NOTICE '[spara_kolumnegenskaper] !!! FEL UPPSTOD !!!';
        RAISE EXCEPTION '[spara_kolumnegenskaper] Flera tabeller matchade %.% - kontakta databasadmin', 
            p_schema_namn, p_tabell_namn;
    WHEN OTHERS THEN
        RAISE NOTICE '[spara_kolumnegenskaper] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[spara_kolumnegenskaper]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[spara_kolumnegenskaper]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[spara_kolumnegenskaper]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[spara_kolumnegenskaper]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[spara_kolumnegenskaper]   - Kontext: %', PG_EXCEPTION_CONTEXT;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.spara_kolumnegenskaper(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.spara_kolumnegenskaper(text, text)
    IS 'Sparar kolumnspecifika egenskaper från PostgreSQL:s systemtabeller.
Hanterar DEFAULT-värden, NOT NULL, kolumnspecifika CHECK-begränsningar och 
IDENTITY-definitioner. Del av uppdelningen mellan tabellregler och kolumnegenskaper
för ett tydligare struktureringssystem.';
