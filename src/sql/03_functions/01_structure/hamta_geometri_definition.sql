-- FUNCTION: public.hamta_geometri_definition(text, text)

-- DROP FUNCTION IF EXISTS public.hamta_geometri_definition(text, text);

CREATE OR REPLACE FUNCTION public.hamta_geometri_definition(
	p_schema_namn text,
	p_tabell_namn text)
    RETURNS geom_info
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Denna funktion analyserar en tabells geometrikolumn och returnerar en 
 * strukturerad representation av dess egenskaper via geom_info-typen.
 *
 * Funktionen validerar först att:
 * 1. Tabellen har exakt en geometrikolumn
 * 2. Geometrikolumnen heter 'geom'
 *
 * Därefter analyseras geometrins:
 * - Typ (POINT, LINESTRING etc)
 * - Dimensionalitet (2D/3D/4D)
 * - SRID
 *
 * Loggningsstrategi:
 * - Alla meddelanden prefixas med [hamta_geometri_definition]
 * - Tydliga steg-markörer för att visa progression
 * - Detaljerad geometrianalys loggas
 * - Felmeddelanden ger diagnostikinformation för felsökning
 ******************************************************************************/
DECLARE
    resultat geom_info;    -- Returvärde som byggs stegvis
    antal_geom integer;    -- För validering av antal geometrikolumner
    felaktigt_namn text;   -- För validering av kolumnnamn
BEGIN
    RAISE NOTICE E'[hamta_geometri_definition] === START ===';
    RAISE NOTICE '[hamta_geometri_definition] Analyserar geometri för %.%', p_schema_namn, p_tabell_namn;

    -- Steg 1: Validera antal geometrikolumner
    RAISE NOTICE '[hamta_geometri_definition] Steg 1: Validerar antal geometrikolumner';
    SELECT COUNT(*) INTO antal_geom
    FROM geometry_columns
    WHERE f_table_schema = p_schema_namn 
    AND f_table_name = p_tabell_namn;

    IF antal_geom = 0 THEN
        RAISE EXCEPTION '[hamta_geometri_definition] Tabellen %.% saknar geometrikolumn', 
            p_schema_namn, p_tabell_namn;
    END IF;

    IF antal_geom > 1 THEN
        RAISE EXCEPTION E'[hamta_geometri_definition] Tabellen %.% har % geometrikolumner.\n'
            '[hamta_geometri_definition] Detta stöds inte av systemet.\n'
            '[hamta_geometri_definition] Standardisera genom att använda en geometrikolumn med namnet "geom".',
            p_schema_namn, p_tabell_namn, antal_geom;
    END IF;

    -- Steg 2: Validera geometrikolumnens namn
    RAISE NOTICE '[hamta_geometri_definition] Steg 2: Validerar geometrikolumnens namn';
    SELECT f_geometry_column INTO felaktigt_namn
    FROM geometry_columns
    WHERE f_table_schema = p_schema_namn 
    AND f_table_name = p_tabell_namn
    AND f_geometry_column != 'geom';

    IF FOUND THEN
        RAISE EXCEPTION E'[hamta_geometri_definition] Tabellen %.% har en geometrikolumn med namnet "%".\n'
            '[hamta_geometri_definition] Detta stöds inte av systemet.\n'
            '[hamta_geometri_definition] Använd standardnamnet "geom" för geometrikolumner.',
            p_schema_namn, p_tabell_namn, felaktigt_namn;
    END IF;

    -- Steg 3: Hämta grundläggande geometriinformation från systemtabeller
    RAISE NOTICE '[hamta_geometri_definition] Steg 3: Hämtar grundläggande geometridata';
    SELECT 'geom',                  -- Kolumnnamn (alltid 'geom')
           type,                    -- Ursprunglig typ från systemtabellen
           coord_dimension,         -- Antal dimensioner (2/3/4)
           srid                     -- SRID-värde
    INTO STRICT 
           resultat.kolumnnamn,
           resultat.typ_ursprunglig,
           resultat.dimensioner,
           resultat.srid
    FROM geometry_columns
    WHERE f_table_schema = p_schema_namn
    AND f_table_name = p_tabell_namn
    AND f_geometry_column = 'geom';

    -- Steg 4: Extrahera grundgeometrityp utan dimensionssuffix
    RAISE NOTICE '[hamta_geometri_definition] Steg 4: Analyserar typ och dimensioner';
    resultat.typ_basal := regexp_replace(resultat.typ_ursprunglig, '[ZM]+$', '');

    -- Steg 5: Beräkna dimensionssuffix baserat på dimensionalitet och M-förekomst
    resultat.suffix := CASE 
        WHEN resultat.dimensioner = 4 THEN 'ZM'
        WHEN resultat.dimensioner = 3 AND resultat.typ_ursprunglig NOT LIKE '%M' THEN 'Z'
        WHEN resultat.dimensioner = 3 AND resultat.typ_ursprunglig LIKE '%M' THEN 'M'
        ELSE ''
    END;

    -- Steg 6: Bygg komplett geometrityp
    resultat.typ_komplett := resultat.typ_basal || resultat.suffix;

    -- Steg 7: Skapa den slutliga geometridefinitionen
    RAISE NOTICE '[hamta_geometri_definition] Steg 5: Bygger geometridefinition';
    resultat.definition := format('geometry(%s,%s)', 
        resultat.typ_komplett, 
        resultat.srid::text
    );

    -- Steg 8: Logga resultatet
    RAISE NOTICE '[hamta_geometri_definition] Geometrianalys slutförd:';
    RAISE NOTICE '[hamta_geometri_definition]   - Kolumnnamn:      %', resultat.kolumnnamn;
    RAISE NOTICE '[hamta_geometri_definition]   - Ursprunglig typ: %', resultat.typ_ursprunglig;
    RAISE NOTICE '[hamta_geometri_definition]   - Basal typ:       %', resultat.typ_basal;
    RAISE NOTICE '[hamta_geometri_definition]   - Dimensioner:     %', resultat.dimensioner;
    RAISE NOTICE '[hamta_geometri_definition]   - SRID:            %', resultat.srid;
    RAISE NOTICE '[hamta_geometri_definition]   - Suffix:          %', resultat.suffix;
    RAISE NOTICE '[hamta_geometri_definition]   - Komplett typ:    %', resultat.typ_komplett;
    RAISE NOTICE '[hamta_geometri_definition]   - Definition:      %', resultat.definition;
    
    RAISE NOTICE '[hamta_geometri_definition] === SLUT ===';
    
    RETURN resultat;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION '[hamta_geometri_definition] Ingen geometrikolumn hittades för %.%', 
            p_schema_namn, p_tabell_namn;
    WHEN TOO_MANY_ROWS THEN
        RAISE EXCEPTION '[hamta_geometri_definition] Flera geometrikolumner hittades för %.%. '
            'Detta kan indikera inkonsistens i systemtabellerna.',
            p_schema_namn, p_tabell_namn;
    WHEN OTHERS THEN
        RAISE NOTICE '[hamta_geometri_definition] Ett fel uppstod:';
        RAISE NOTICE '[hamta_geometri_definition]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[hamta_geometri_definition]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[hamta_geometri_definition]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hamta_geometri_definition]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[hamta_geometri_definition]   - Kontext: %', PG_EXCEPTION_CONTEXT;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hamta_geometri_definition(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.hamta_geometri_definition(text, text)
    IS 'Analyserar en tabells geometrikolumn och returnerar en strukturerad 
representation av dess egenskaper via geom_info-typen. Validerar att tabellen
har exakt en geometrikolumn med namnet "geom" och skapar sedan en komplett
geometridefinition som kan användas för CREATE TABLE och ALTER TABLE.';