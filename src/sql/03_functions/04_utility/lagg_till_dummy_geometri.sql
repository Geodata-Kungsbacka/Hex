-- FUNCTION: public.lagg_till_dummy_geometri(text, text, geom_info)

CREATE OR REPLACE FUNCTION public.lagg_till_dummy_geometri(
    p_schema_namn  text,
    p_tabell_namn  text,
    p_geometriinfo geom_info
)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
/******************************************************************************
 * Lägger till en minimal dummy-geometrirad i en nyligen skapad geometritabell
 * så att QGIS kan identifiera geometritypen direkt via normal DB-anslutning.
 *
 * BAKGRUND
 * QGIS med "Använd uppskattad tabellmetadata" av kör:
 *   SELECT DISTINCT geometrytype(geom) FROM tabell LIMIT 1
 * En tom tabell ger NULL → QGIS visar en manuell dialogruta där användaren
 * måste ange geometrikolumn och SRID. En dummy-rad löser detta.
 *
 * Dummy-koordinater (EPSG 3007, SWEREF99 12 00, Kungsbacka-området):
 *   Punkt/linje/polygon centrerad kring (160000, 6395000).
 *   Geometrin är 100 × 100 m och uppfyller validera_geometri()-kravet
 *   på _kba_-tabeller (giltig, ej tom, inga duplicerade punkter,
 *   area/längd > tolerans, ST_IsSimple).
 *
 * LIVSCYKEL
 *   Dummy-raden registreras i hex_dummy_geometrier.
 *   En AFTER INSERT-trigger (hex_ta_bort_dummy) läggs till på tabellen.
 *   Triggern tar automatiskt bort dummyn när den första riktiga raden
 *   läggs in.
 *
 * Hela funktionen är omgiven av ett EXCEPTION-block – fel vid dummy-insättning
 * (t.ex. obligatoriska kolumner utan standardvärde) loggas som NOTICE och
 * stoppar inte tabellskapandet.
 ******************************************************************************/
DECLARE
    dummy_wkt text;
    dummy_gid bigint;
BEGIN
    -- Välj WKT baserat på geometrityp (typ_basal är utan dimensionssuffix)
    dummy_wkt := CASE p_geometriinfo.typ_basal
        WHEN 'POINT'
            THEN 'POINT(160000 6395000)'
        WHEN 'MULTIPOINT'
            THEN 'MULTIPOINT((160000 6395000))'
        WHEN 'LINESTRING'
            THEN 'LINESTRING(160000 6395000, 160100 6395100)'
        WHEN 'MULTILINESTRING'
            THEN 'MULTILINESTRING((160000 6395000, 160100 6395100))'
        WHEN 'POLYGON'
            THEN 'POLYGON((160000 6395000, 160100 6395000, 160100 6395100, 160000 6395100, 160000 6395000))'
        WHEN 'MULTIPOLYGON'
            THEN 'MULTIPOLYGON(((160000 6395000, 160100 6395000, 160100 6395100, 160000 6395100, 160000 6395000)))'
        ELSE
            -- Fallback för GEOMETRY och okända typer – ta polygon som är mest
            -- "universell" i termer av visualisering i QGIS
            'POLYGON((160000 6395000, 160100 6395000, 160100 6395100, 160000 6395100, 160000 6395000))'
    END;

    -- Infoga dummy-raden (INSERT INTO geom-kolumnen, övriga kolumner har defaults).
    -- ST_GeomFromText skapar 2D-geometri; PostGIS lägger automatiskt till Z=0
    -- om kolumntypen kräver det (PointZ, PolygonZ etc.).
    EXECUTE format(
        'INSERT INTO %I.%I (geom) VALUES (ST_GeomFromText($1, $2)) RETURNING gid',
        p_schema_namn, p_tabell_namn
    ) INTO dummy_gid USING dummy_wkt, p_geometriinfo.srid;

    -- Registrera dummy-gid för framtida städning
    INSERT INTO public.hex_dummy_geometrier (schema_namn, tabell_namn, gid)
    VALUES (p_schema_namn, p_tabell_namn, dummy_gid);

    -- Lägg till AFTER INSERT-trigger som tar bort dummyn när riktig data anländer.
    -- Triggern skapas EFTER insättningen, vilket innebär att den inte avfyras
    -- för dummy-raden själv (den finns redan i tabellen när triggern skapas).
    EXECUTE format(
        'CREATE TRIGGER hex_ta_bort_dummy'
        ' AFTER INSERT ON %I.%I'
        ' FOR EACH ROW EXECUTE FUNCTION public.ta_bort_dummy_rad()',
        p_schema_namn, p_tabell_namn
    );

    RAISE NOTICE '[lagg_till_dummy_geometri] ✓ Dummy-geometri tillagd i %.% (gid: %, typ: %, srid: %)',
        p_schema_namn, p_tabell_namn, dummy_gid,
        p_geometriinfo.typ_basal, p_geometriinfo.srid;

EXCEPTION
    WHEN OTHERS THEN
        -- Stoppar inte tabellskapandet – loggar bara problemet
        RAISE NOTICE '[lagg_till_dummy_geometri] ⚠ Kunde inte lägga till dummy i %.%: %',
            p_schema_namn, p_tabell_namn, SQLERRM;
        RAISE NOTICE '[lagg_till_dummy_geometri]   Trolig orsak: obligatorisk kolumn utan standardvärde.';
        RAISE NOTICE '[lagg_till_dummy_geometri]   Tabellen kan kräva manuell specifikation i QGIS.';
END;
$BODY$;

ALTER FUNCTION public.lagg_till_dummy_geometri(text, text, geom_info)
    OWNER TO postgres;

COMMENT ON FUNCTION public.lagg_till_dummy_geometri(text, text, geom_info)
    IS 'Lägger till en minimal dummy-geometrirad i en geometritabell för att QGIS
ska kunna identifiera geometritypen via normal DB-anslutning (utan manuell dialog).
Dummy-koordinaterna ligger i Kungsbacka-området (EPSG 3007, ~160000 6395000) och
uppfyller alla validera_geometri()-krav. Dummy-gid registreras i hex_dummy_geometrier
och en AFTER INSERT-trigger (hex_ta_bort_dummy) läggs till för att automatiskt
städa bort dummyn när den första riktiga raden infogats. Fel loggas som NOTICE
och stoppar inte tabellskapandet.';
