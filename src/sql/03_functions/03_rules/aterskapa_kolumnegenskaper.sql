-- FUNCTION: public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper)

-- DROP FUNCTION IF EXISTS public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper);

CREATE OR REPLACE FUNCTION public.aterskapa_kolumnegenskaper(
	p_schema_namn text,
	p_tabell_namn text,
	p_egenskaper kolumnegenskaper)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion återskapar kolumnspecifika egenskaper för en tabell.
 * Funktionen är separat från återskapande av tabellregler för att hålla
 * ett tydligt koncept av ansvarsfördelning.
 *
 * Egenskaper återskapas i följande ordning:
 * 1. NOT NULL-begränsningar
 * 2. CHECK-begränsningar 
 * 3. DEFAULT-värden
 * 4. IDENTITY-definitioner
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [aterskapa_kolumnegenskaper]
 * - Tydliga steg-markörer visar progression
 * - SQL-satser loggas för felsökning
 * - Detaljerade felmeddelanden med kontext
 ******************************************************************************/
DECLARE
    sql_sats text;           -- SQL-sats som ska exekveras
    op_steg text;            -- Aktuellt operationssteg för felrapportering
    antal_default integer;   -- Antal återskapade DEFAULT-värden
    antal_notnull integer;   -- Antal återskapade NOT NULL-constraints
    antal_check integer;     -- Antal återskapade CHECK-constraints
    antal_identity integer;  -- Antal återskapade IDENTITY-definitioner
BEGIN
    RAISE NOTICE E'[aterskapa_kolumnegenskaper] === START ===';
    RAISE NOTICE '[aterskapa_kolumnegenskaper] Återskapar kolumnegenskaper för %.%', 
        p_schema_namn, p_tabell_namn;

    -- Steg 1: Återskapa NOT NULL-begränsningar
    op_steg := 'not null';
    antal_notnull := COALESCE(array_length(p_egenskaper.notnull_defs, 1), 0);
    
    IF antal_notnull > 0 THEN
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 1: Återskapar % NOT NULL-begränsningar', 
            antal_notnull;
        FOR i IN 1..antal_notnull LOOP
            sql_sats := format(
                'ALTER TABLE %I.%I ALTER COLUMN %I SET NOT NULL',
                p_schema_namn, p_tabell_namn, p_egenskaper.notnull_defs[i]
            );
            RAISE NOTICE '[aterskapa_kolumnegenskaper]   SQL #%: %', i, sql_sats;
            EXECUTE sql_sats;
        END LOOP;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   ✓ % NOT NULL-begränsningar återskapade', 
            antal_notnull;
    ELSE
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 1: Inga NOT NULL-begränsningar att återskapa';
    END IF;

    -- Steg 2: Återskapa kolumnspecifika CHECK-begränsningar
    op_steg := 'check constraints';
    antal_check := COALESCE(array_length(p_egenskaper.check_defs, 1), 0);
    
    IF antal_check > 0 THEN
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 2: Återskapar % kolumnspecifika CHECK-begränsningar', 
            antal_check;
        FOR i IN 1..antal_check LOOP
            -- Extrahera constraint-namn, kolumnnamn och definition
            DECLARE
                constraint_namn text := split_part(p_egenskaper.check_defs[i], ';', 1);
                kolumn_namn text := split_part(p_egenskaper.check_defs[i], ';', 2);
                check_def text := split_part(p_egenskaper.check_defs[i], ';', 3);
            BEGIN
                sql_sats := format(
                    'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                    p_schema_namn, p_tabell_namn,
                    constraint_namn,
                    check_def
                );
                RAISE NOTICE '[aterskapa_kolumnegenskaper]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   ✓ % kolumnspecifika CHECK-begränsningar återskapade', 
            antal_check;
    ELSE
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 2: Inga kolumnspecifika CHECK-begränsningar att återskapa';
    END IF;

    -- Steg 3: Återskapa DEFAULT-värden
    op_steg := 'default-värden';
    antal_default := COALESCE(array_length(p_egenskaper.default_defs, 1), 0);

    IF antal_default > 0 THEN
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 3: Återskapar % DEFAULT-värden', 
            antal_default;
        FOR i IN 1..antal_default LOOP
            -- Extrahera kolumnnamn och värde
            DECLARE
                kolumn_namn text := split_part(p_egenskaper.default_defs[i], ';', 1);
                default_varde text := split_part(p_egenskaper.default_defs[i], ';', 2);
                ar_standardkolumn boolean;
            BEGIN
                -- Kontrollera om detta är en standardkolumn
                SELECT EXISTS (
                    SELECT 1 FROM standardiserade_kolumner 
                    WHERE kolumnnamn = kolumn_namn
                ) INTO ar_standardkolumn;
                
                IF ar_standardkolumn THEN
                    RAISE NOTICE '[aterskapa_kolumnegenskaper]   Hoppar över standardkolumn: % (har redan korrekt DEFAULT)', 
                        kolumn_namn;
                    CONTINUE;
                END IF;
                
                sql_sats := format(
                    'ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT %s',
                    p_schema_namn, p_tabell_namn,
                    kolumn_namn,
                    default_varde
                );
                RAISE NOTICE '[aterskapa_kolumnegenskaper]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   ✓ % DEFAULT-värden återskapade', 
            antal_default;
    ELSE
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 3: Inga DEFAULT-värden att återskapa';
    END IF;

    -- Steg 4: Återskapa IDENTITY-definitioner
    op_steg := 'identity-definitioner';
    antal_identity := COALESCE(array_length(p_egenskaper.identity_defs, 1), 0);
    
    IF antal_identity > 0 THEN
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 4: Återskapar % IDENTITY-definitioner', 
            antal_identity;
        FOR i IN 1..antal_identity LOOP
            -- Extrahera kolumnnamn och värde
            DECLARE
                kolumn_namn text := split_part(p_egenskaper.identity_defs[i], ';', 1);
                identity_def text := split_part(p_egenskaper.identity_defs[i], ';', 2);
            BEGIN
                sql_sats := format(
                    'ALTER TABLE %I.%I ALTER COLUMN %I ADD %s',
                    p_schema_namn, p_tabell_namn,
                    kolumn_namn,
                    identity_def
                );
                RAISE NOTICE '[aterskapa_kolumnegenskaper]   SQL #%: %', i, sql_sats;
                EXECUTE sql_sats;
            END;
        END LOOP;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   ✓ % IDENTITY-definitioner återskapade', 
            antal_identity;
    ELSE
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Steg 4: Inga IDENTITY-definitioner att återskapa';
    END IF;

    -- Summera resultatet
    RAISE NOTICE '[aterskapa_kolumnegenskaper] Sammanfattning:';
    RAISE NOTICE '[aterskapa_kolumnegenskaper]   » NOT NULL:          %', antal_notnull;
    RAISE NOTICE '[aterskapa_kolumnegenskaper]   » CHECK:             %', antal_check;
    RAISE NOTICE '[aterskapa_kolumnegenskaper]   » DEFAULT:           %', antal_default;
    RAISE NOTICE '[aterskapa_kolumnegenskaper]   » IDENTITY:          %', antal_identity;
    RAISE NOTICE '[aterskapa_kolumnegenskaper] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[aterskapa_kolumnegenskaper] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Senaste kontext:';
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - Operation: %', op_steg;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - SQL: %', sql_sats;
        RAISE NOTICE '[aterskapa_kolumnegenskaper] Tekniska feldetaljer:';
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[aterskapa_kolumnegenskaper]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper)
    OWNER TO postgres;

COMMENT ON FUNCTION public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper)
    IS 'Återskapar kolumnspecifika egenskaper som DEFAULT, NOT NULL, kolumnspecifika 
CHECK-begränsningar och IDENTITY-definitioner. Del av uppdelningen mellan tabellregler 
och kolumnegenskaper för ett tydligare struktureringssystem.';