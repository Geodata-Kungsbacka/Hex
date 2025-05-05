-- FUNCTION: public.hamta_kolumnstandard(text, text, geom_info)

-- DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, geom_info);

CREATE OR REPLACE FUNCTION public.hamta_kolumnstandard(
	p_schema_namn text,
	p_tabell_namn text,
	p_geometriinfo geom_info)
    RETURNS kolumnkonfig[]
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion sammanställer en komplett kolumnlista för en tabell genom att
 * kombinera kolumner från tre källor i en specifik ordning:
 *
 * 1. Standardkolumner med positiv ordinal_position
 *    Exempel: gid GENERATED ALWAYS AS IDENTITY
 *
 * 2. Kolumner från CREATE TABLE-satsen
 *    Exempel: namn text, antal integer
 *
 * 3. Standardkolumner med negativ ordinal_position
 *    Exempel: andrad_av text, andrad_datum timestamptz
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [hamta_kolumnstandard]
 * - Tydliga steg-markörer för att visa progression
 * - Detaljerad kolumnsammansättning loggas
 * - Slutlig CREATE TABLE-sats visas för felsökning
 ******************************************************************************/
DECLARE 
    resultat kolumnkonfig[];          -- Resultatarray som returneras
    create_kolumn record;             -- För loggning av kolumninformation
    sql_sats text;                    -- För loggning av SQL-satser
    antal_standardkolumner integer;   -- Antal kolumner från standardiserade_kolumner
    antal_tabellkolumner integer;     -- Totalt antal kolumner
BEGIN
    RAISE NOTICE E'[hamta_kolumnstandard] === START ===';
    
    -- Steg 1: Analysera geometriinformation om sådan finns
    RAISE NOTICE '[hamta_kolumnstandard] Steg 1: Analyserar geometriinformation';
    IF p_geometriinfo IS NOT NULL THEN
        RAISE NOTICE '[hamta_kolumnstandard]   - Kolumnnamn:      %', p_geometriinfo.kolumnnamn;
        RAISE NOTICE '[hamta_kolumnstandard]   - Typ:             %', p_geometriinfo.typ_ursprunglig;
        RAISE NOTICE '[hamta_kolumnstandard]   - Basal typ:       %', p_geometriinfo.typ_basal;
        RAISE NOTICE '[hamta_kolumnstandard]   - Dimensioner:     %', p_geometriinfo.dimensioner;
        RAISE NOTICE '[hamta_kolumnstandard]   - Definition:      %', p_geometriinfo.definition;
    ELSE
        RAISE NOTICE '[hamta_kolumnstandard]   - Ingen geometriinformation tillgänglig';
    END IF;

    -- Steg 2: Räkna standardkolumner för statistik
    RAISE NOTICE '[hamta_kolumnstandard] Steg 2: Räknar standardkolumner';
    SELECT COUNT(*) INTO antal_standardkolumner 
    FROM standardiserade_kolumner;
    RAISE NOTICE '[hamta_kolumnstandard]   - Antal standardkolumner: %', antal_standardkolumner;

    -- Steg 3: Skapa temporär tabell med alla kolumner i rätt ordning
    RAISE NOTICE '[hamta_kolumnstandard] Steg 3: Sammanställer kolumner i korrekt ordning';
    
    -- Skapa temporär tabell med kolumner i rätt ordning
    CREATE TEMP TABLE temp_kolumner AS
        -- Standardkolumner med positiv ordinal_position först
        SELECT 
            kolumnnamn, 
            ordinal_position, 
            datatyp,
            false as is_generated, 
            NULL::text as generated_expr
        FROM standardiserade_kolumner
        WHERE ordinal_position > 0

        UNION ALL

        -- CREATE TABLE-kolumner i mitten
        SELECT 
            c.column_name,
            c.ordinal_position,
            CASE 
                WHEN a.attgenerated = 's' THEN
                    -- Ta bort extra paranteser genom att inte lägga till egna
                    format('%s GENERATED ALWAYS AS %s STORED',
                        c.udt_name,
                        pg_get_expr(d.adbin, d.adrelid)
                    )
                ELSE
                    c.udt_name
            END as datatyp,
            CASE WHEN a.attgenerated = 's' THEN true 
                 ELSE false END as is_generated,
            CASE WHEN a.attgenerated = 's' THEN pg_get_expr(d.adbin, d.adrelid)
                 ELSE NULL END as generated_expr
        FROM information_schema.columns c
        JOIN pg_attribute a ON (
            a.attrelid = (p_schema_namn || '.' || p_tabell_namn)::regclass 
            AND a.attname = c.column_name
        )
        LEFT JOIN pg_attrdef d ON (a.attrelid, a.attnum) = (d.adrelid, d.adnum)
        WHERE c.table_schema = p_schema_namn
        AND c.table_name = p_tabell_namn
        AND c.column_name NOT IN (SELECT kolumnnamn FROM standardiserade_kolumner)
        AND c.column_name != 'geom'

        UNION ALL

        -- Standardkolumner med negativ ordinal_position
        SELECT 
            kolumnnamn, 
            ordinal_position, 
            datatyp,
            false as is_generated, 
            NULL::text as generated_expr
        FROM standardiserade_kolumner 
        WHERE ordinal_position < 0

        UNION ALL

        -- Geometrikolumnen sist om den finns
        SELECT 
            p_geometriinfo.kolumnnamn AS kolumnnamn,
            0 AS ordinal_position,    -- Använder 0 som ordinal_position för geometri
            p_geometriinfo.definition AS datatyp,
            false AS is_generated,
            NULL::text AS generated_expr
        WHERE p_geometriinfo IS NOT NULL;

    -- Steg 4: Räkna totalt antal kolumner för statistik
    RAISE NOTICE '[hamta_kolumnstandard] Steg 4: Analyserar sammanställda kolumner';
    SELECT COUNT(*) INTO antal_tabellkolumner FROM temp_kolumner;
    RAISE NOTICE '[hamta_kolumnstandard]   - Totalt antal kolumner: %', antal_tabellkolumner;

    -- Steg 5: Logga kolumnerna och deras definitioner
    FOR create_kolumn IN SELECT * FROM temp_kolumner
    LOOP
        IF create_kolumn.is_generated THEN
            RAISE NOTICE '[hamta_kolumnstandard]   - Kolumn: % (GENERATED med uttryck: %)',
                create_kolumn.kolumnnamn,
                create_kolumn.generated_expr;
        ELSE
            RAISE NOTICE '[hamta_kolumnstandard]   - Kolumn: % (Typ: %)',
                create_kolumn.kolumnnamn,
                create_kolumn.datatyp;
        END IF;
    END LOOP;

    -- Steg 6: Skapa resultatarrayen
    RAISE NOTICE '[hamta_kolumnstandard] Steg 5: Skapar resultatarray';
    SELECT array_agg(ROW(kolumnnamn, ordinal_position, datatyp)::kolumnkonfig)
    INTO resultat 
    FROM temp_kolumner;

    -- Steg 7: Visa den kompletta CREATE TABLE-satsen
    RAISE NOTICE '[hamta_kolumnstandard] Steg 6: Genererar CREATE TABLE-sats för felsökning';
    SELECT string_agg(
        format('%I %s', kolumnnamn, datatyp),
        E',\n    '
    ) INTO sql_sats 
    FROM temp_kolumner;
    
    RAISE NOTICE E'[hamta_kolumnstandard] Resulterande CREATE TABLE-sats:\n  (\n    %\n  )', sql_sats;

    -- Städa upp och returnera resultat
    DROP TABLE IF EXISTS temp_kolumner;
    RAISE NOTICE '[hamta_kolumnstandard]   - Hämtade % kolumner', antal_tabellkolumner;
    RAISE NOTICE '[hamta_kolumnstandard] === SLUT ===';
    
    RETURN resultat;

EXCEPTION
    WHEN OTHERS THEN
        -- Säkerställ att temporära tabellen tas bort även vid fel
        DROP TABLE IF EXISTS temp_kolumner;
        RAISE NOTICE '[hamta_kolumnstandard] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hamta_kolumnstandard]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[hamta_kolumnstandard]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[hamta_kolumnstandard]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hamta_kolumnstandard]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[hamta_kolumnstandard] === AVBRUTEN ===';
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hamta_kolumnstandard(text, text, geom_info)
    OWNER TO postgres;

COMMENT ON FUNCTION public.hamta_kolumnstandard(text, text, geom_info)
    IS 'Sammanställer en komplett kolumnlista för en tabell genom att kombinera 
kolumner från standardiserade_kolumner och originaltabellen samt eventuell geometri.
Returnerar en array med kolumnkonfig-objekt som används för att skapa den
standardiserade tabellstrukturen.';