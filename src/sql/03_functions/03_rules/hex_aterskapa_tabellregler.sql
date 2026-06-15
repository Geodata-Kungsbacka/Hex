-- FUNCTION: public.hex_aterskapa_tabellregler(text, text, hex_tabellregler)

-- DROP FUNCTION IF EXISTS public.hex_aterskapa_tabellregler(text, text, hex_tabellregler);

CREATE OR REPLACE FUNCTION public.hex_aterskapa_tabellregler(
	p_schema_namn text,
	p_tabell_namn text,
	p_regler hex_tabellregler)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion återskapar tabellövergripande regler i rätt ordning. 
 * Funktionen har anpassats för att endast hantera äkta hex_tabellregler, medan
 * hex_kolumnegenskaper hanteras separat av hex_aterskapa_kolumnegenskaper().
 *
 * Regler återskapas i följande ordning:
 * 1. Index (skapas först eftersom de kan behövas av constraints)
 * 2. Tabellövergripande Constraints (UNIQUE, multikolumn-CHECK)
 *    OBS: PRIMARY KEY undantas alltid – Hex tillhandahåller sin egen
 *    primärnyckel via gid-kolumnen. En extern PK skulle orsaka
 *    "multiple primary keys"-fel vid omstrukturering.
 * 3. Foreign Keys (skapas sist för att undvika cirkelreferenser)
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [hex_aterskapa_tabellregler]
 * - Tydliga steg-markörer visar progression
 * - SQL-satser loggas för felsökning
 * - Detaljerade felmeddelanden med kontext
 ******************************************************************************/
DECLARE
    sql_sats text;           -- SQL-sats som ska exekveras
    op_steg text;            -- Aktuellt operationssteg för felrapportering
    antal_index integer;     -- Antal återskapade index
    antal_constr integer;    -- Antal återskapade constraints
    antal_fk integer;        -- Antal återskapade foreign keys  
BEGIN
    RAISE NOTICE E'[hex_aterskapa_tabellregler] === START ===';
    RAISE NOTICE '[hex_aterskapa_tabellregler] Återskapar hex_tabellregler för %.%', p_schema_namn, p_tabell_namn;

    -- Steg 1: Återskapa index
    op_steg := 'index';
    antal_index := COALESCE(array_length(p_regler.index_defs, 1), 0);
    
    IF antal_index > 0 THEN
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 1: Återskapar % index', antal_index;
        FOR i IN 1..antal_index LOOP
            sql_sats := p_regler.index_defs[i];
            RAISE NOTICE '[hex_aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
            EXECUTE sql_sats;
        END LOOP;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   ✓ % index återskapade', antal_index;
    ELSE
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 1: Inga index att återskapa';
    END IF;

    -- Steg 2: Återskapa tabellövergripande constraints (PRIMARY KEY, UNIQUE, multikolumn-CHECK)
    op_steg := 'constraints';
    antal_constr := COALESCE(array_length(p_regler.constraint_defs, 1), 0);
    
    IF antal_constr > 0 THEN
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 2: Återskapar % tabellövergripande constraints', antal_constr;
        FOR i IN 1..antal_constr LOOP
            -- Extrahera namn och definition
            DECLARE
                constraint_namn text := split_part(p_regler.constraint_defs[i], ';', 1);
                constraint_def text := split_part(p_regler.constraint_defs[i], ';', 2);
            BEGIN
                -- Skippa PRIMARY KEY: Hex tillhandahåller alltid sin egen primärnyckel
                -- via gid-kolumnen. En extern PRIMARY KEY (t.ex. från FME) skulle
                -- orsaka "multiple primary keys" fel.
                IF constraint_def LIKE 'PRIMARY KEY%' THEN
                    RAISE NOTICE '[hex_aterskapa_tabellregler]   → Hoppar över PRIMARY KEY-constraint "%" (hanteras av gid-kolumnen)', constraint_namn;
                    CONTINUE;
                END IF;

                sql_sats := format(
                    'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                    p_schema_namn, p_tabell_namn,
                    constraint_namn,
                    constraint_def
                );
                RAISE NOTICE '[hex_aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   ✓ Tabellövergripande constraints återskapade (PRIMARY KEY undantagen)';
    ELSE
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 2: Inga tabellövergripande constraints att återskapa';
    END IF;

    -- Steg 3: Återskapa foreign keys
    op_steg := 'foreign keys';
    antal_fk := COALESCE(array_length(p_regler.fk_defs, 1), 0);
    
    IF antal_fk > 0 THEN
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 3: Återskapar % foreign keys', antal_fk;
        FOR i IN 1..antal_fk LOOP
            -- Extrahera namn och definition
            DECLARE
                fk_namn text := split_part(p_regler.fk_defs[i], ';', 1);
                fk_def text := split_part(p_regler.fk_defs[i], ';', 2);
            BEGIN
                sql_sats := format(
                    'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                    p_schema_namn, p_tabell_namn,
                    fk_namn,
                    fk_def
                );
                RAISE NOTICE '[hex_aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   ✓ % foreign keys återskapade', antal_fk;
    ELSE
        RAISE NOTICE '[hex_aterskapa_tabellregler] Steg 3: Inga foreign keys att återskapa';
    END IF;

    -- Summera resultatet
    RAISE NOTICE '[hex_aterskapa_tabellregler] Sammanfattning:';
    RAISE NOTICE '[hex_aterskapa_tabellregler]   » Index:        %', antal_index;
    RAISE NOTICE '[hex_aterskapa_tabellregler]   » Constraints:  %', antal_constr;
    RAISE NOTICE '[hex_aterskapa_tabellregler]   » Foreign Keys: %', antal_fk;
    RAISE NOTICE '[hex_aterskapa_tabellregler] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hex_aterskapa_tabellregler] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_aterskapa_tabellregler] Senaste kontext:';
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - Operation: %', op_steg;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - SQL: %', sql_sats;
        RAISE NOTICE '[hex_aterskapa_tabellregler] Tekniska feldetaljer:';
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hex_aterskapa_tabellregler]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hex_aterskapa_tabellregler(text, text, hex_tabellregler)
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_aterskapa_tabellregler(text, text, hex_tabellregler)
    IS 'Återskapar tabellövergripande regler (index, constraints, foreign keys) i korrekt ordning.
PRIMARY KEY-constraints undantas alltid: Hex tillhandahåller sin egen primärnyckel via
gid-kolumnen, och en extern PRIMARY KEY (t.ex. från FME) skulle orsaka konflikt.
Kolumnegenskaper hanteras separat av hex_aterskapa_kolumnegenskaper().';
