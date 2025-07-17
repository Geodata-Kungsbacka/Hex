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
 * SYFTE: Denna funktion tar en befintlig tabell och bestämmer vilka kolumner
 * som ska finnas i den "standardiserade" versionen av tabellen. Den blandar
 * kolumner från tre källor för att skapa en enhetlig tabellstruktur.
 *
 * PRAKTISKT EXEMPEL:
 * En användare skapar: CREATE TABLE sk0_ext_sgu.jorddjupsmodell_y (meter_till_berg integer, geom geometry);
 * Funktionen returnerar kolumner för: (gid, meter_till_berg, skapad_tidpunkt, geom)
 * Där gid och skapad_tidpunkt kommer från standardiserade_kolumner
 *
 * ANVÄNDS AV: hantera_ny_tabell() för att omstrukturera tabeller automatiskt
 *
 * PARAMETRAR:
 * - p_schema_namn: Namnet på schemat (t.ex. "sk0_ext_sgu", "sk1_kba_mh_bygg")
 * - p_tabell_namn: Namnet på tabellen (t.ex. "jorddjupsmodell_y") 
 * - p_geometriinfo: Struct med geometriinformation (geom_info-typ) eller NULL
 *
 * RETURVÄRDE:
 * - Array av kolumnkonfig-objekt, där varje objekt innehåller:
 *   * kolumnnamn: Namnet på kolumnen (t.ex. "gid", "meter_till_berg")
 *   * ordinal_position: Sorteringsordning (1,2,3... eller -1,-2,-3...)
 *   * datatyp: PostgreSQL-datatyp (t.ex. "integer", "text", "geometry(Polygon,3007)")
 *
 * ORDINAL_POSITION FÖRKLARING:
 * - Positiva värden (1,2,3...): Kolumner som placeras FÖRST i tabellen
 * - CREATE TABLE kolumner: Behåller sina ursprungliga positioner
 * - Negativa värden (-1,-2,-3...): Kolumner som placeras SIST i tabellen
 * - Geometri: Alltid allra sist (ordinal_position = 0)
 *
 * SCHEMA_UTTRYCK FÖRKLARING:
 * Schema_uttryck avgör vilka scheman som ska få specifika standardkolumner.
 * Uttrycket sätts in efter "WHERE p_schema_namn [uttryck]" i SQL.
 *
 * EXEMPEL:
 * - "LIKE '%_ext_%'" → Endast externa datakällor (sk0_ext_sgu, sk1_ext_lantmateriet)
 * - "= 'sk0_ext_sgu'" → Endast detta specifika schema
 * - "IS NOT NULL" → Alla scheman (standardvärde)
 * - "NOT LIKE '%_sys_%'" → Alla utom systemscheman
 * - "LIKE '%_kba_%'" → Endast interna datakällor (sk1_kba_mh_bygg, sk2_kba_plan)
 *
 * KONKRET EXEMPEL PÅ FUNKTIONENS ANVÄNDNING:
 * 
 * INPUT:
 * - p_schema_namn: "sk0_ext_sgu"
 * - p_tabell_namn: "jorddjupsmodell_y" 
 * - p_geometriinfo: geometry(Polygon,3007)
 * 
 * PROCESS:
 * 1. Standardkolumner som matchar: gid (pos 1), skapad_tidpunkt (pos -1)
 * 2. CREATE TABLE kolumner: meter_till_berg (pos 1) 
 * 3. Geometri: geom geometry(Polygon,3007) (pos 0)
 * 
 * OUTPUT:
 * Array med: [gid, meter_till_berg, skapad_tidpunkt, geom]
 * 
 * ANVÄNDS FÖR:
 * CREATE TABLE sk0_ext_sgu.jorddjupsmodell_y_temp (
 *     gid integer GENERATED ALWAYS AS IDENTITY,
 *     meter_till_berg integer,
 *     skapad_tidpunkt timestamptz DEFAULT NOW(),
 *     geom geometry(Polygon,3007)
 * );
 *
 * ANDRA SCHEMAEXEMPEL:
 * - sk1_kba_mh_bygg: Intern data från mh_bygg-avdelningen, säkerhetsnivå 1
 * - sk2_sys_combine: Systemdata från Combine-systemet, säkerhetsnivå 2
 *
 * KOLUMNORDNING:
 * 1. Standardkolumner med positiv ordinal_position (filtrerade per schema)
 * 2. Kolumner från CREATE TABLE-satsen
 * 3. Standardkolumner med negativ ordinal_position (filtrerade per schema)
 * 4. Geometrikolumn sist om den finns
 *
 * TVÅSTEGSPROCESS:
 * 1. Filtrera standardkolumner baserat på schema_uttryck i en loop
 * 2. Använd vanlig UNION ALL för att kombinera alla kolumntyper
 ******************************************************************************/
DECLARE 
    resultat kolumnkonfig[];          -- Resultatarray som returneras
    create_kolumn record;             -- För loggning av kolumninformation
    standardkolumn record;            -- För loop genom standardiserade_kolumner
    matchar boolean;                  -- För evaluering av schema_uttryck
    sql_sats text;                    -- För loggning av SQL-satser
    antal_standardkolumner integer;   -- Antal kolumner från standardiserade_kolumner
    antal_filtrerade integer;         -- Antal kolumner efter schema-filtrering
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
    RAISE NOTICE '[hamta_kolumnstandard]   - Totalt antal standardkolumner: %', antal_standardkolumner;

    -- STEG 3: Hitta vilka standardkolumner som passar detta schema
    -- Vi loopar genom alla standardkolumner och testar om de matchar schemat.
    -- T.ex. kolumn "extern_id" med uttryck "LIKE '%_ext_%'" matchar "sk0_ext_sgu"
    -- men inte "sk1_kba_mh_bygg". Matchande kolumner sparas i temp_filtrerade_standardkolumner.
    RAISE NOTICE '[hamta_kolumnstandard] Steg 3: Filtrerar standardkolumner baserat på schema_uttryck';
    
    -- Skapa temporär tabell för filtrerade standardkolumner
    CREATE TEMP TABLE temp_filtrerade_standardkolumner AS
        SELECT kolumnnamn, ordinal_position, datatyp 
        FROM standardiserade_kolumner 
        WHERE false; -- Tom tabell med rätt struktur

    -- Loop genom alla standardkolumner och testa schema_uttryck
    FOR standardkolumn IN 
        SELECT kolumnnamn, ordinal_position, datatyp, schema_uttryck
        FROM standardiserade_kolumner 
        ORDER BY ordinal_position
    LOOP
        BEGIN
            -- EXECUTE: Kör dynamisk SQL som byggts som sträng
            -- format(): Säker formatering av SQL med %L (quoted literal) och %s (string)
            -- Constraint har redan validerat att schema_uttryck är säkert att använda
            EXECUTE format('SELECT %L %s', p_schema_namn, standardkolumn.schema_uttryck) INTO matchar;
            
            IF matchar THEN
                INSERT INTO temp_filtrerade_standardkolumner 
                VALUES (standardkolumn.kolumnnamn, standardkolumn.ordinal_position, standardkolumn.datatyp);
                
                RAISE NOTICE '[hamta_kolumnstandard]   ✓ Kolumn % matchade schema_uttryck: %', 
                    standardkolumn.kolumnnamn, standardkolumn.schema_uttryck;
            ELSE
                RAISE NOTICE '[hamta_kolumnstandard]   - Kolumn % matchade INTE schema_uttryck: %', 
                    standardkolumn.kolumnnamn, standardkolumn.schema_uttryck;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING '[hamta_kolumnstandard] Fel vid evaluering av schema_uttryck för kolumn %: % (Fel: %)', 
                    standardkolumn.kolumnnamn, standardkolumn.schema_uttryck, SQLERRM;
        END;
    END LOOP;

    -- Räkna hur många kolumner som matchade
    SELECT COUNT(*) INTO antal_filtrerade FROM temp_filtrerade_standardkolumner;
    RAISE NOTICE '[hamta_kolumnstandard]   - Antal kolumner som matchade schema %: %', 
        p_schema_namn, antal_filtrerade;

    -- STEG 4: Sätt ihop alla kolumner i rätt ordning
    -- KRITISK SORTERINGSLOGIK: Kolumnordningen bestäms av denna UNION ALL-sekvens,
    -- INTE av ordinal_position! ordinal_position avgör bara vilken sektion
    -- standardkolumnerna hamnar i (före eller efter CREATE TABLE-kolumnerna).
    --
    -- UNION ALL-ordning (detta är den slutliga kolumnordningen):
    -- 1. Filtrerade standardkolumner (positiva ordinal_position) - t.ex. gid
    -- 2. Användarens CREATE TABLE-kolumner - t.ex. meter_till_berg
    -- 3. Filtrerade standardkolumner (negativa ordinal_position) - t.ex. skapad_tidpunkt  
    -- 4. Geometrikolumn sist om den finns - t.ex. geom
    RAISE NOTICE '[hamta_kolumnstandard] Steg 4: Sammanställer alla kolumner i korrekt ordning';
    
    CREATE TEMP TABLE temp_kolumner_till_fardig_tabell AS
        -- DEL 1: Standardkolumner som ska komma FÖRST (positiv ordinal_position)
        -- Exempel: gid integer GENERATED ALWAYS AS IDENTITY (position 1)
        SELECT 
            kolumnnamn, 
            ordinal_position, 
            datatyp,
            false as is_generated, 
            NULL::text as generated_expr
        FROM temp_filtrerade_standardkolumner
        WHERE ordinal_position > 0

        UNION ALL

        -- DEL 2: Kolumner från användarens CREATE TABLE-sats
        -- Exempel: meter_till_berg integer (behåller sin ursprungliga position)
        -- Denna sektion hanterar även GENERATED kolumner (beräknade kolumner)
        SELECT 
            c.column_name,
            c.ordinal_position,
            CASE 
                WHEN a.attgenerated = 's' THEN
                    -- GENERATED ALWAYS AS ... STORED kolumner
                    format('%s GENERATED ALWAYS AS %s STORED',
                        c.udt_name,
                        pg_get_expr(d.adbin, d.adrelid)
                    )
                ELSE
                    -- Vanliga kolumner
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

        -- DEL 3: Standardkolumner som ska komma SIST (negativ ordinal_position)
        -- Exempel: skapad_tidpunkt timestamptz DEFAULT NOW() (position -1)
        SELECT 
            kolumnnamn, 
            ordinal_position, 
            datatyp,
            false as is_generated, 
            NULL::text as generated_expr
        FROM temp_filtrerade_standardkolumner 
        WHERE ordinal_position < 0

        UNION ALL

        -- DEL 4: Geometrikolumnen allra sist (om den finns)
        -- Exempel: geom geometry(Polygon,3007) (position 0)
        SELECT 
            p_geometriinfo.kolumnnamn AS kolumnnamn,
            0 AS ordinal_position,    -- Geometri får alltid position 0
            p_geometriinfo.definition AS datatyp,
            false AS is_generated,
            NULL::text AS generated_expr
        WHERE p_geometriinfo IS NOT NULL;

    -- Steg 5: Räkna totalt antal kolumner för statistik
    RAISE NOTICE '[hamta_kolumnstandard] Steg 5: Analyserar slutliga kolumner';
    SELECT COUNT(*) INTO antal_tabellkolumner FROM temp_kolumner_till_fardig_tabell;
    RAISE NOTICE '[hamta_kolumnstandard]   - Totalt antal kolumner efter sammansättning: %', antal_tabellkolumner;

    -- Steg 6: Logga kolumnerna och deras definitioner
    RAISE NOTICE '[hamta_kolumnstandard] Steg 6: Loggar slutliga kolumner';
    FOR create_kolumn IN 
        SELECT * FROM temp_kolumner_till_fardig_tabell 
        ORDER BY ordinal_position
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

    -- STEG 7: Skapa resultatarray som funktionen returnerar
    -- array_agg(): Samlar alla rader till en array
    -- ROW()::kolumnkonfig: Skapar en struct av typen kolumnkonfig från varje rad
    -- Ordningen kommer från UNION ALL-sekvensen ovan (ingen ORDER BY behövs)
    RAISE NOTICE '[hamta_kolumnstandard] Steg 7: Skapar resultatarray';
    SELECT array_agg(ROW(kolumnnamn, ordinal_position, datatyp)::kolumnkonfig)
    INTO resultat 
    FROM temp_kolumner_till_fardig_tabell;

    -- Steg 8: Visa den kompletta CREATE TABLE-satsen
    RAISE NOTICE '[hamta_kolumnstandard] Steg 8: Genererar CREATE TABLE-sats för felsökning';
    SELECT string_agg(
        format('%I %s', kolumnnamn, datatyp),
        E',\n    '
        ORDER BY ordinal_position
    ) INTO sql_sats 
    FROM temp_kolumner_till_fardig_tabell;
    
    RAISE NOTICE E'[hamta_kolumnstandard] Resulterande CREATE TABLE-sats:\n  (\n    %\n  )', sql_sats;

    -- Städa upp och returnera resultat
    DROP TABLE IF EXISTS temp_filtrerade_standardkolumner;
    DROP TABLE IF EXISTS temp_kolumner_till_fardig_tabell;
    
    RAISE NOTICE '[hamta_kolumnstandard]   - Hämtade % kolumner för schema %', antal_tabellkolumner, p_schema_namn;
    RAISE NOTICE '[hamta_kolumnstandard]   - Varav % kom från filtrerade standardkolumner', antal_filtrerade;
    RAISE NOTICE '[hamta_kolumnstandard] === SLUT ===';
    
    RETURN resultat;

EXCEPTION
    WHEN OTHERS THEN
        -- Säkerställ att temporära tabeller tas bort även vid fel
        DROP TABLE IF EXISTS temp_filtrerade_standardkolumner;
        DROP TABLE IF EXISTS temp_kolumner_till_fardig_tabell;
        
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
kolumner från standardiserade_kolumner (filtrerade baserat på schema_uttryck) 
och originaltabellen samt eventuell geometri. Använder tvåstegsfiltrering:
1) Loop för schema_uttryck-evaluering 2) Vanlig UNION ALL för sammansättning.
Returnerar en array med kolumnkonfig-objekt som används för att skapa den
standardiserade tabellstrukturen.';