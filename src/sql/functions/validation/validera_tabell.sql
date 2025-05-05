-- FUNCTION: public.validera_tabell(text, text)

-- DROP FUNCTION IF EXISTS public.validera_tabell(text, text);

CREATE OR REPLACE FUNCTION public.validera_tabell(
	p_schema_namn text,
	p_tabell_namn text,
	OUT p_geometriinfo geom_info)
    RETURNS geom_info
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion validerar att en tabell följer systemets namngivningsregler
 * och krav på geometrikolumner.
 *
 * För alla tabeller valideras:
 * - Att tabellnamnet börjar med schemanamn + understreck (schema_*)
 *
 * För tabeller utan geometri valideras även:
 * - Att tabellnamnet INTE slutar med något av de reserverade suffixen
 *   (_p, _l, _y, _g) som är vikta för tabeller med geometri
 *
 * För tabeller med geometri valideras:
 * - Att tabellen har exakt en geometrikolumn
 * - Att geometrikolumnen heter 'geom'
 * - Att tabellnamnet har korrekt suffix baserat på geometrityp:
 *   _p för (MULTI)POINT
 *   _l för (MULTI)LINESTRING
 *   _y för (MULTI)POLYGON
 *   _g för övriga geometrityper
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [validera_tabell]
 * - Tydliga steg-markörer för att visa progression  
 * - Detaljerad kontextinformation vid fel
 * - Tydliga avslutningsmarkörer
 ******************************************************************************/
DECLARE
    antal_geom integer;     -- För validering av antal geometrikolumner
    felaktigt_namn text;    -- För validering av kolumnnamn
    forvantat_suffix text;  -- För validering av tabellnamn
    valideringssteg text;   -- För felsökningskontext
BEGIN
    RAISE NOTICE E'[validera_tabell] === START ===';
    RAISE NOTICE '[validera_tabell] Validerar tabell %.%', p_schema_namn, p_tabell_namn;

    -- Steg 1: Kontrollera om tabellen har geometri
    valideringssteg := 'geometri-kontroll';
    RAISE NOTICE '[validera_tabell] Steg 1: Kontrollerar geometrikolumner';
    SELECT COUNT(*) INTO antal_geom
    FROM geometry_columns
    WHERE f_table_schema = p_schema_namn 
    AND f_table_name = p_tabell_namn;
    
    RAISE NOTICE '[validera_tabell]   » Antal geometrikolumner: %', antal_geom;

    -- Steg 2: Hantera tabeller utan geometri
    IF antal_geom = 0 THEN
        valideringssteg := 'validering av tabell utan geometri';
        RAISE NOTICE '[validera_tabell] Steg 2a: Validerar tabell utan geometri';

        -- Kontrollera prefix
        IF NOT p_tabell_namn LIKE p_schema_namn || '\_%' THEN
            RAISE EXCEPTION E'[validera_tabell] Ogiltigt tabellnamn "%.%".\n'
                '[validera_tabell] Även tabeller utan geometri måste börja med schemanamn '
                'följt av understreck (%_)',
                p_schema_namn, p_tabell_namn,
                p_schema_namn;
        END IF;
        RAISE NOTICE '[validera_tabell]   ✓ Tabellnamn har korrekt prefix: %_', p_schema_namn;

        -- Kontrollera att inget geometrisuffix används
        IF p_tabell_namn LIKE '%\_p' OR 
           p_tabell_namn LIKE '%\_l' OR 
           p_tabell_namn LIKE '%\_y' OR 
           p_tabell_namn LIKE '%\_g' THEN
            RAISE NOTICE E'[validera_tabell] Ogiltigt tabellnamn "%.%".\n'
                '[validera_tabell] Tabeller utan geometri får inte använda suffixen _p, _l, _y '
                'eller _g då dessa är reserverade för tabeller med '
                'geometrikolumner.',
                p_schema_namn, p_tabell_namn;
        END IF;
        RAISE NOTICE '[validera_tabell]   ✓ Tabellnamn använder inte reserverade geometrisuffix';

        -- Returnera NULL som geometriinfo
        p_geometriinfo := NULL;
        RAISE NOTICE '[validera_tabell]   ✓ Validering slutförd för tabell utan geometri';
        RAISE NOTICE '[validera_tabell] === SLUT ===';
        RETURN;
    END IF;

    -- Steg 2b: Validera tabeller med geometri
    valideringssteg := 'validering av antal geometrikolumner';
    RAISE NOTICE '[validera_tabell] Steg 2b: Validerar tabell med geometri';
    
    IF antal_geom > 1 THEN
        RAISE EXCEPTION E'[validera_tabell] Tabellen %.% har % geometrikolumner.\n'
            '[validera_tabell] Detta stöds inte av systemet.\n'
            '[validera_tabell] Standardisera genom att använda en geometrikolumn med namnet "geom".',
            p_schema_namn, p_tabell_namn, antal_geom;
    END IF;
    RAISE NOTICE '[validera_tabell]   ✓ Korrekt antal geometrikolumner: 1';

    -- Steg 3: Validera geometrikolumnens namn
    valideringssteg := 'validering av geometrikolumnnamn';
    RAISE NOTICE '[validera_tabell] Steg 3: Validerar geometrikolumnens namn';
    
    IF EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = p_schema_namn 
        AND f_table_name = p_tabell_namn
        AND f_geometry_column != 'geom'
    ) THEN
        SELECT f_geometry_column INTO STRICT felaktigt_namn
        FROM geometry_columns
        WHERE f_table_schema = p_schema_namn 
        AND f_table_name = p_tabell_namn;
        
        RAISE EXCEPTION E'[validera_tabell] Tabellen %.% har en geometrikolumn med namnet "%".\n'
            '[validera_tabell] Detta stöds inte av systemet.\n'
            '[validera_tabell] Använd standardnamnet "geom" för geometrikolumner.',
            p_schema_namn, p_tabell_namn, felaktigt_namn;
    END IF;
    RAISE NOTICE '[validera_tabell]   ✓ Geometrikolumn har korrekt namn: geom';

    -- Steg 4: Hämta geometriinfo för validering och returnering
    valideringssteg := 'hämtning av geometriinformation';
    RAISE NOTICE '[validera_tabell] Steg 4: Hämtar geometriinformation';
    
    p_geometriinfo := hamta_geometri_definition(p_schema_namn, p_tabell_namn);
    RAISE NOTICE '[validera_tabell]   » Geometry-typ: %', p_geometriinfo.typ_basal;
    RAISE NOTICE '[validera_tabell]   » SRID: %', p_geometriinfo.srid;

    -- Steg 5: Validera tabellnamn med korrekt geometrisuffix
    valideringssteg := 'validering av tabellnamnsuffix';
    RAISE NOTICE '[validera_tabell] Steg 5: Validerar tabellnamnets suffix';
    
    forvantat_suffix := CASE 
        WHEN p_geometriinfo.typ_basal IN ('POINT', 'MULTIPOINT') THEN '_p'
        WHEN p_geometriinfo.typ_basal IN ('LINESTRING', 'MULTILINESTRING') THEN '_l'
        WHEN p_geometriinfo.typ_basal IN ('POLYGON', 'MULTIPOLYGON') THEN '_y'
        ELSE '_g'
    END;
    RAISE NOTICE '[validera_tabell]   » Förväntat suffix för %: %', 
        p_geometriinfo.typ_basal, forvantat_suffix;

    -- Validera både prefix och suffix
    IF NOT (p_tabell_namn LIKE p_schema_namn || '\_%' AND 
            p_tabell_namn LIKE '%' || forvantat_suffix) THEN
        RAISE EXCEPTION E'[validera_tabell] Ogiltigt tabellnamn "%.%".\n'
            '[validera_tabell] Tabellnamn måste:\n'
            '[validera_tabell] 1. Börja med schemanamn följt av understreck (%_)\n'
            '[validera_tabell] 2. Sluta med suffix för geometrityp (%)\n'
            '[validera_tabell] Exempel på giltigt namn: %_mittnamn%',
            p_schema_namn, p_tabell_namn,
            p_schema_namn,
            forvantat_suffix,
            p_schema_namn, forvantat_suffix;
    END IF;
    RAISE NOTICE '[validera_tabell]   ✓ Tabellnamn har korrekt prefix och suffix';

    RAISE NOTICE '[validera_tabell]   ✓ Validering slutförd för tabell med geometri';
    RAISE NOTICE '[validera_tabell] === SLUT ===';
    RETURN;  -- p_geometriinfo returneras automatiskt via OUT-parametern

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[validera_tabell] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[validera_tabell] Valideringssteg: %', valideringssteg;
        RAISE NOTICE '[validera_tabell] Tabell: %.%', p_schema_namn, p_tabell_namn;
        RAISE NOTICE '[validera_tabell] Geometrikolumner: %', coalesce(antal_geom::text, 'okänt');
        RAISE NOTICE '[validera_tabell] Felkod: %', SQLSTATE;
        RAISE NOTICE '[validera_tabell] Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[validera_tabell] === AVBRUTEN ===';
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.validera_tabell(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.validera_tabell(text, text)
    IS 'Validerar att en tabell följer systemets namnkonventioner och krav på
geometrikolumner. Accepterar tabeller utan geometri men validerar då att de
inte använder reserverade geometrisuffix. Returnerar geometriinfo för tabellen
eller NULL om tabellen saknar geometri.';
