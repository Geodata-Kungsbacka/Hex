-- FUNCTION: public.hex_validera_tabell(text, text)

CREATE OR REPLACE FUNCTION public.hex_validera_tabell(
    p_schema_namn text,
    p_tabell_namn text,
    OUT p_geometriinfo hex_geom_info)
    RETURNS hex_geom_info
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion validerar att en tabell följer systemets krav på 
 * geometrikolumner och suffixnamn.
 *
 * För tabeller utan geometri valideras:
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
 * - Alla meddelanden prefixas med [hex_validera_tabell]
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
    RAISE NOTICE E'[hex_validera_tabell] === START ===';
    RAISE NOTICE '[hex_validera_tabell] Validerar tabell %.%', p_schema_namn, p_tabell_namn;

    -- Steg 1: Kontrollera namnlängd
    valideringssteg := 'namnlängdskontroll';
    RAISE NOTICE '[hex_validera_tabell] Steg 1: Kontrollerar namnlängd';

    IF length(p_tabell_namn) > 54 THEN
        RAISE EXCEPTION
            E'[hex_validera_tabell] Tabellnamnet "%" är för långt (%s tecken, max 54).\n'
            'Historiktabellen (%_h) måste rymmas inom PostgreSQL-gränsen på 63 tecken.',
            p_tabell_namn, length(p_tabell_namn), p_tabell_namn;
    END IF;
    RAISE NOTICE '[hex_validera_tabell]   ✓ Namnlängd OK: % tecken', length(p_tabell_namn);

    -- Steg 2: Kontrollera om tabellen har geometri
    valideringssteg := 'geometri-kontroll';
    RAISE NOTICE '[hex_validera_tabell] Steg 2: Kontrollerar geometrikolumner';
    SELECT COUNT(*) INTO antal_geom
    FROM geometry_columns
    WHERE f_table_schema = p_schema_namn 
    AND f_table_name = p_tabell_namn;
    
    RAISE NOTICE '[hex_validera_tabell]   » Antal geometrikolumner: %', antal_geom;

    -- Steg 3: Hantera tabeller utan geometri
    IF antal_geom = 0 THEN
        valideringssteg := 'validering av tabell utan geometri';
        RAISE NOTICE '[hex_validera_tabell] Steg 3a: Validerar tabell utan geometri';

        -- Kontrollera att inget geometrisuffix används
        -- FIX: Ändrat från RAISE NOTICE till RAISE EXCEPTION
        IF p_tabell_namn ~ '_[plyg]$' THEN
            RAISE EXCEPTION E'[hex_validera_tabell] Ogiltigt tabellnamn "%.%".\n'
                '[hex_validera_tabell] Tabeller utan geometri får inte använda suffixen _p, _l, _y '
                'eller _g då dessa är reserverade för tabeller med '
                'geometrikolumner.',
                p_schema_namn, p_tabell_namn;
        END IF;
        RAISE NOTICE '[hex_validera_tabell]   ✓ Tabellnamn använder inte reserverade geometrisuffix';

        -- Returnera NULL som geometriinfo
        p_geometriinfo := NULL;
        RAISE NOTICE '[hex_validera_tabell]   ✓ Validering slutförd för tabell utan geometri';
        RAISE NOTICE '[hex_validera_tabell] === SLUT ===';
        RETURN;
    END IF;

    -- Steg 3b: Validera tabeller med geometri
    valideringssteg := 'validering av antal geometrikolumner';
    RAISE NOTICE '[hex_validera_tabell] Steg 3b: Validerar tabell med geometri';
    
    IF antal_geom > 1 THEN
        RAISE EXCEPTION E'[hex_validera_tabell] Tabellen %.% har % geometrikolumner.\n'
            '[hex_validera_tabell] Detta stöds inte av systemet.\n'
            '[hex_validera_tabell] Standardisera genom att använda en geometrikolumn med namnet "geom".',
            p_schema_namn, p_tabell_namn, antal_geom;
    END IF;
    RAISE NOTICE '[hex_validera_tabell]   ✓ Korrekt antal geometrikolumner: 1';

    -- Steg 4: Validera geometrikolumnens namn
    valideringssteg := 'validering av geometrikolumnnamn';
    RAISE NOTICE '[hex_validera_tabell] Steg 4: Validerar geometrikolumnens namn';
    
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
        
        RAISE EXCEPTION E'[hex_validera_tabell] Tabellen %.% har en geometrikolumn med namnet "%".\n'
            '[hex_validera_tabell] Detta stöds inte av systemet.\n'
            '[hex_validera_tabell] Använd standardnamnet "geom" för geometrikolumner.',
            p_schema_namn, p_tabell_namn, felaktigt_namn;
    END IF;
    RAISE NOTICE '[hex_validera_tabell]   ✓ Geometrikolumn har korrekt namn: geom';

    -- Steg 5: Hämta geometriinfo för validering och returnering
    valideringssteg := 'hämtning av geometriinformation';
    RAISE NOTICE '[hex_validera_tabell] Steg 5: Hämtar geometriinformation';
    
    p_geometriinfo := hex_hamta_geometri_definition(p_schema_namn, p_tabell_namn);
    RAISE NOTICE '[hex_validera_tabell]   » Geometry-typ: %', p_geometriinfo.typ_basal;
    RAISE NOTICE '[hex_validera_tabell]   » SRID: %', p_geometriinfo.srid;

    -- Steg 6: Validera tabellnamn med korrekt geometrisuffix
    valideringssteg := 'validering av tabellnamnsuffix';
    RAISE NOTICE '[hex_validera_tabell] Steg 6: Validerar tabellnamnets suffix';
    
    forvantat_suffix := CASE 
        WHEN p_geometriinfo.typ_basal IN ('POINT', 'MULTIPOINT') THEN '_p'
        WHEN p_geometriinfo.typ_basal IN ('LINESTRING', 'MULTILINESTRING') THEN '_l'
        WHEN p_geometriinfo.typ_basal IN ('POLYGON', 'MULTIPOLYGON') THEN '_y'
        ELSE '_g'
    END;
    RAISE NOTICE '[hex_validera_tabell]   » Förväntat suffix för %: %', 
        p_geometriinfo.typ_basal, forvantat_suffix;

    -- Validera suffix (inga krav på prefix längre)
    IF NOT p_tabell_namn LIKE '%' || forvantat_suffix THEN
        RAISE EXCEPTION E'[hex_validera_tabell] Ogiltigt tabellnamn "%.%".\n'
            '[hex_validera_tabell] Tabellnamn med geometri måste:\n'
            '[hex_validera_tabell] Sluta med suffix för geometrityp (%)\n'
            '[hex_validera_tabell] Exempel på giltigt namn: mittnamn%',
            p_schema_namn, p_tabell_namn,
            forvantat_suffix,
            forvantat_suffix;
    END IF;
    RAISE NOTICE '[hex_validera_tabell]   ✓ Tabellnamn har korrekt suffix';

    RAISE NOTICE '[hex_validera_tabell]   ✓ Validering slutförd för tabell med geometri';
    RAISE NOTICE '[hex_validera_tabell] === SLUT ===';
    RETURN;  -- p_geometriinfo returneras automatiskt via OUT-parametern

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hex_validera_tabell] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_validera_tabell] Valideringssteg: %', valideringssteg;
        RAISE NOTICE '[hex_validera_tabell] Tabell: %.%', p_schema_namn, p_tabell_namn;
        RAISE NOTICE '[hex_validera_tabell] Geometrikolumner: %', coalesce(antal_geom::text, 'okänt');
        RAISE NOTICE '[hex_validera_tabell] Felkod: %', SQLSTATE;
        RAISE NOTICE '[hex_validera_tabell] Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[hex_validera_tabell] === AVBRUTEN ===';
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hex_validera_tabell(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_validera_tabell(text, text)
    IS 'Validerar att en tabell följer systemets krav på geometrikolumner och suffixnamn.
Tabeller utan geometri får INTE använda reserverade suffix (_p, _l, _y, _g).
Tabeller med geometri MÅSTE ha korrekt suffix baserat på geometrityp.';
