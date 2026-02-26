-- FUNCTION: public.aterskapa_tabellregler(text, text, tabellregler)

-- DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, tabellregler);

CREATE OR REPLACE FUNCTION public.aterskapa_tabellregler(
	p_schema_namn text,
	p_tabell_namn text,
	p_regler tabellregler)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion återskapar tabellövergripande regler i rätt ordning. 
 * Funktionen har anpassats för att endast hantera äkta tabellregler, medan
 * kolumnegenskaper hanteras separat av aterskapa_kolumnegenskaper().
 *
 * Regler återskapas i följande ordning:
 * 1. Index (skapas först eftersom de kan behövas av constraints)
 * 2. Tabellövergripande Constraints (PRIMARY KEY, UNIQUE, multikolumn-CHECK)
 * 3. Foreign Keys (skapas sist för att undvika cirkelreferenser)
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [aterskapa_tabellregler]
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
    RAISE NOTICE E'[aterskapa_tabellregler] === START ===';
    RAISE NOTICE '[aterskapa_tabellregler] Återskapar tabellregler för %.%', p_schema_namn, p_tabell_namn;

    -- Steg 1: Återskapa index
    op_steg := 'index';
    antal_index := COALESCE(array_length(p_regler.index_defs, 1), 0);
    
    IF antal_index > 0 THEN
        RAISE NOTICE '[aterskapa_tabellregler] Steg 1: Återskapar % index', antal_index;
        FOR i IN 1..antal_index LOOP
            sql_sats := p_regler.index_defs[i];
            RAISE NOTICE '[aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
            EXECUTE sql_sats;
        END LOOP;
        RAISE NOTICE '[aterskapa_tabellregler]   ✓ % index återskapade', antal_index;
    ELSE
        RAISE NOTICE '[aterskapa_tabellregler] Steg 1: Inga index att återskapa';
    END IF;

    -- Steg 2: Återskapa tabellövergripande constraints (PRIMARY KEY, UNIQUE, multikolumn-CHECK)
    op_steg := 'constraints';
    antal_constr := COALESCE(array_length(p_regler.constraint_defs, 1), 0);
    
    IF antal_constr > 0 THEN
        RAISE NOTICE '[aterskapa_tabellregler] Steg 2: Återskapar % tabellövergripande constraints', antal_constr;
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
                    RAISE NOTICE '[aterskapa_tabellregler]   → Hoppar över PRIMARY KEY-constraint "%" (hanteras av gid-kolumnen)', constraint_namn;
                    CONTINUE;
                END IF;

                sql_sats := format(
                    'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                    p_schema_namn, p_tabell_namn,
                    constraint_namn,
                    constraint_def
                );
                RAISE NOTICE '[aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[aterskapa_tabellregler]   ✓ Tabellövergripande constraints återskapade (PRIMARY KEY undantagen)';
    ELSE
        RAISE NOTICE '[aterskapa_tabellregler] Steg 2: Inga tabellövergripande constraints att återskapa';
    END IF;

    -- Steg 3: Återskapa foreign keys
    op_steg := 'foreign keys';
    antal_fk := COALESCE(array_length(p_regler.fk_defs, 1), 0);
    
    IF antal_fk > 0 THEN
        RAISE NOTICE '[aterskapa_tabellregler] Steg 3: Återskapar % foreign keys', antal_fk;
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
                RAISE NOTICE '[aterskapa_tabellregler]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[aterskapa_tabellregler]   ✓ % foreign keys återskapade', antal_fk;
    ELSE
        RAISE NOTICE '[aterskapa_tabellregler] Steg 3: Inga foreign keys att återskapa';
    END IF;

    -- Summera resultatet
    RAISE NOTICE '[aterskapa_tabellregler] Sammanfattning:';
    RAISE NOTICE '[aterskapa_tabellregler]   » Index:        %', antal_index;
    RAISE NOTICE '[aterskapa_tabellregler]   » Constraints:  %', antal_constr;
    RAISE NOTICE '[aterskapa_tabellregler]   » Foreign Keys: %', antal_fk;
    RAISE NOTICE '[aterskapa_tabellregler] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[aterskapa_tabellregler] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[aterskapa_tabellregler] Senaste kontext:';
        RAISE NOTICE '[aterskapa_tabellregler]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[aterskapa_tabellregler]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[aterskapa_tabellregler]   - Operation: %', op_steg;
        RAISE NOTICE '[aterskapa_tabellregler]   - SQL: %', sql_sats;
        RAISE NOTICE '[aterskapa_tabellregler] Tekniska feldetaljer:';
        RAISE NOTICE '[aterskapa_tabellregler]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[aterskapa_tabellregler]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.aterskapa_tabellregler(text, text, tabellregler)
    OWNER TO postgres;

COMMENT ON FUNCTION public.aterskapa_tabellregler(text, text, tabellregler)
    IS 'Återskapar tabellövergripande regler (index, constraints, foreign keys) i korrekt ordning.
Funktionen har anpassats för att endast hantera äkta tabellregler, medan kolumnegenskaper 
hanteras separat av aterskapa_kolumnegenskaper() för ett tydligare struktureringssystem.';
