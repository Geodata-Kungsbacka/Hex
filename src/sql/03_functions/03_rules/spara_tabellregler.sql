-- FUNCTION: public.spara_tabellregler(text, text)

-- DROP FUNCTION IF EXISTS public.spara_tabellregler(text, text);

CREATE OR REPLACE FUNCTION public.spara_tabellregler(
	p_schema_namn text,
	p_tabell_namn text)
    RETURNS tabellregler
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion sparar tabellövergripande regler som sedan kan återskapas
 * vid omstrukturering av tabeller. Funktionen har anpassats för att endast
 * hantera äkta tabellregler, medan kolumnegenskaper hanteras separat av
 * spara_kolumnegenskaper().
 *
 * Funktionen sparar:
 * 1. Index
 *    - Alla index utom PRIMARY KEY och UNIQUE constraints
 *    - Format: Kompletta CREATE INDEX-satser
 *
 * 2. Foreign Keys
 *    - Alla FK-relationer till andra tabeller
 *    - Format: konstraintnamn;definition
 *
 * 3. Tabellomfattande Constraints
 *    - CHECK som refererar flera kolumner
 *    - UNIQUE över en eller flera kolumner
 *    - PRIMARY KEY
 *    - Format: konstraintnamn;definition
 *
 * Kolumnegenskaper (DEFAULT, NOT NULL, enkla CHECK, IDENTITY) hanteras nu
 * av funktionen spara_kolumnegenskaper().
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [spara_tabellregler]
 * - Tydliga steg-markörer visar progression
 * - Detaljerad regelinformation loggas
 * - Slutresultat sammanfattas
 ******************************************************************************/
DECLARE
    resultat tabellregler;     -- Variabel som håller alla regler
    tabell_oid oid;           -- Tabellens unika PostgreSQL-ID
    antal_index integer;      -- För statistik
    antal_fk integer;         -- För statistik
    antal_constr integer;     -- För statistik
BEGIN
    RAISE NOTICE E'[spara_tabellregler] === START ===';
    RAISE NOTICE '[spara_tabellregler] Analyserar regler för %.%', p_schema_namn, p_tabell_namn;
    
    -- Steg 1: Hämta tabellens OID
    RAISE NOTICE '[spara_tabellregler] Steg 1: Hämtar tabellidentifierare';
    SELECT c.oid INTO STRICT tabell_oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema_namn
    AND c.relname = p_tabell_namn;

    RAISE NOTICE '[spara_tabellregler]   » Tabell-OID: %', tabell_oid;

    -- Steg 2: Spara index
    RAISE NOTICE '[spara_tabellregler] Steg 2: Analyserar index';
    WITH index_data AS (
        SELECT pg_get_indexdef(i.indexrelid) as indexdef
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE i.indrelid = tabell_oid
        AND NOT i.indisprimary      -- Skippa primärnycklar, de hanteras med constraints
        AND NOT i.indisunique       -- Skippa unique constraints, de hanteras med constraints
    )
    SELECT array_agg(indexdef), COUNT(*)
    INTO resultat.index_defs, antal_index
    FROM index_data;

    IF antal_index > 0 THEN
        RAISE NOTICE '[spara_tabellregler]   » Hittade % index:', antal_index;
        FOR i IN 1..antal_index LOOP
            RAISE NOTICE '[spara_tabellregler]     #%: %', i, resultat.index_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_tabellregler]   » Inga index hittades';
    END IF;

    -- Steg 3: Spara foreign keys
    RAISE NOTICE '[spara_tabellregler] Steg 3: Analyserar foreign keys';
    WITH fk_data AS (
        SELECT format('%s;%s', 
            conname, 
            pg_get_constraintdef(oid)
        ) as fkdef
        FROM pg_constraint
        WHERE conrelid = tabell_oid
        AND contype = 'f'          -- 'f' = foreign key
    )
    SELECT array_agg(fkdef), COUNT(*)
    INTO resultat.fk_defs, antal_fk
    FROM fk_data;

    IF antal_fk > 0 THEN
        RAISE NOTICE '[spara_tabellregler]   » Hittade % foreign keys:', antal_fk;
        FOR i IN 1..antal_fk LOOP
            RAISE NOTICE '[spara_tabellregler]     #%: %', i, resultat.fk_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_tabellregler]   » Inga foreign keys hittades';
    END IF;

    -- Steg 4: Spara tabellövergripande constraints (CHECK och UNIQUE)
    RAISE NOTICE '[spara_tabellregler] Steg 4: Analyserar tabellövergripande constraints';
    WITH constraint_data AS (
        SELECT 
            conname,
            contype,
            pg_get_constraintdef(oid) as definition,
            array_length(conkey, 1) as col_count  -- Antal kolumner i constraint
        FROM pg_constraint
        WHERE conrelid = tabell_oid
        AND (
            contype = 'p' OR                      -- PRIMARY KEY
            contype = 'u' OR                      -- UNIQUE constraint
            (contype = 'c' AND array_length(conkey, 1) > 1)  -- CHECK med flera kolumner
        )
    )
    SELECT 
        array_agg(format('%s;%s', conname, definition)), 
        COUNT(*)
    INTO 
        resultat.constraint_defs, 
        antal_constr
    FROM constraint_data;
    
    IF antal_constr > 0 THEN
        RAISE NOTICE '[spara_tabellregler]   » Hittade % tabellövergripande constraints:', antal_constr;
        FOR i IN 1..antal_constr LOOP
            RAISE NOTICE '[spara_tabellregler]     #%: %', i, resultat.constraint_defs[i];
        END LOOP;
    ELSE
        RAISE NOTICE '[spara_tabellregler]   » Inga tabellövergripande constraints hittades';
    END IF;

    -- Summera resultatet
    RAISE NOTICE '[spara_tabellregler] Sammanfattning:';
    RAISE NOTICE '[spara_tabellregler]   » Index:         %', COALESCE(antal_index, 0);
    RAISE NOTICE '[spara_tabellregler]   » Foreign Keys:  %', COALESCE(antal_fk, 0);
    RAISE NOTICE '[spara_tabellregler]   » Constraints:   %', COALESCE(antal_constr, 0);
    RAISE NOTICE '[spara_tabellregler] === SLUT ===';

    RETURN resultat;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE NOTICE '[spara_tabellregler] !!! FEL UPPSTOD !!!';
        RAISE EXCEPTION '[spara_tabellregler] Tabell %.% existerar inte', 
            p_schema_namn, p_tabell_namn;
    WHEN TOO_MANY_ROWS THEN
        RAISE NOTICE '[spara_tabellregler] !!! FEL UPPSTOD !!!';
        RAISE EXCEPTION '[spara_tabellregler] Flera tabeller matchade %.% - kontakta databasadmin', 
            p_schema_namn, p_tabell_namn;
    WHEN OTHERS THEN
        RAISE NOTICE '[spara_tabellregler] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[spara_tabellregler]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[spara_tabellregler]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[spara_tabellregler]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[spara_tabellregler]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[spara_tabellregler]   - Kontext: %', PG_EXCEPTION_CONTEXT;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.spara_tabellregler(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.spara_tabellregler(text, text)
    IS 'Sparar tabellövergripande regler från PostgreSQL:s systemtabeller.
Hanterar nu endast äkta tabellregler (index, FK, multikolumns-constraints),
medan kolumnegenskaper har flyttats till en separat funktion. Del av uppdelningen 
mellan tabellregler och kolumnegenskaper för ett tydligare struktureringssystem.';