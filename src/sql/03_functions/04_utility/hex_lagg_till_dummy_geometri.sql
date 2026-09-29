-- FUNCTION: public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info)

CREATE OR REPLACE FUNCTION public.hex_lagg_till_dummy_geometri(
    p_schema_namn  text,
    p_tabell_namn  text,
    p_geometriinfo hex_geom_info
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
 * Dummy-koordinater läses från hex_installningar:
 *   Punkt/linje/polygon med nedre vänstra hörnet i (dummy_x, dummy_y), i
 *   koordinatsystemet hex_installningar.srid. Linjen och polygonen spänner
 *   dummy_storlek enheter i x och y. Standard är (160000, 6395000) och 100 i
 *   EPSG 3007 (SWEREF99 12 00, Kungsbacka-området), dvs. 100 × 100 m.
 *   Har tabellen ett annat SRID transformeras geometrin dit, så att dummyn
 *   hamnar på samma plats. SRID 0 (okänt) får koordinaterna som de är.
 *   Geometrin uppfyller hex_validera_geometri()-kravet på _kba_-tabeller
 *   (giltig, ej tom, inga duplicerade punkter, inga kurvsegment).
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
    inst       public.hex_installningar;
    x0         double precision;
    y0         double precision;
    x1         double precision;
    y1         double precision;
    dummy_geom geometry;
    dummy_gid  bigint;
BEGIN
    SELECT * INTO STRICT inst FROM public.hex_installningar;
    x0 := inst.dummy_x;
    y0 := inst.dummy_y;
    x1 := inst.dummy_x + inst.dummy_storlek;
    y1 := inst.dummy_y + inst.dummy_storlek;

    -- Välj geometri baserat på geometrityp (typ_basal är utan dimensionssuffix).
    -- Byggs i inställningarnas koordinatsystem och transformeras nedan.
    dummy_geom := CASE p_geometriinfo.typ_basal
        WHEN 'POINT'
            THEN ST_SetSRID(ST_MakePoint(x0, y0), inst.srid)
        WHEN 'MULTIPOINT'
            THEN ST_Multi(ST_SetSRID(ST_MakePoint(x0, y0), inst.srid))
        WHEN 'LINESTRING'
            THEN ST_SetSRID(ST_MakeLine(ST_MakePoint(x0, y0), ST_MakePoint(x1, y1)), inst.srid)
        WHEN 'MULTILINESTRING'
            THEN ST_Multi(ST_SetSRID(ST_MakeLine(ST_MakePoint(x0, y0), ST_MakePoint(x1, y1)), inst.srid))
        WHEN 'POLYGON'
            THEN ST_MakeEnvelope(x0, y0, x1, y1, inst.srid)
        WHEN 'MULTIPOLYGON'
            THEN ST_Multi(ST_MakeEnvelope(x0, y0, x1, y1, inst.srid))
        ELSE
            -- Fallback för GEOMETRY och okända typer – ta polygon som är mest
            -- "universell" i termer av visualisering i QGIS
            ST_MakeEnvelope(x0, y0, x1, y1, inst.srid)
    END;

    -- Tabell i annat koordinatsystem än inställningen: flytta dummyn dit, så
    -- att den hamnar på samma plats. SRID 0 går inte att transformera till –
    -- koordinaterna behålls då som de är.
    IF p_geometriinfo.srid = 0 THEN
        dummy_geom := ST_SetSRID(dummy_geom, 0);
    ELSIF p_geometriinfo.srid <> inst.srid THEN
        dummy_geom := ST_Transform(dummy_geom, p_geometriinfo.srid);
    END IF;

    -- Infoga dummy-raden (INSERT INTO geom-kolumnen, övriga kolumner har defaults).
    -- Geometrin är byggd i 2D. PostGIS fyller inte på dimensioner själv
    -- ("Column has Z dimension but geometry does not"), så lägg till Z/M = 0
    -- efter kolumnens typ. Utan det fick PointZ-, PolygonZ- m.fl. tabeller
    -- aldrig någon dummy-rad.
    dummy_geom := CASE p_geometriinfo.suffix
        WHEN 'Z'  THEN ST_Force3DZ(dummy_geom)
        WHEN 'M'  THEN ST_Force3DM(dummy_geom)
        WHEN 'ZM' THEN ST_Force4D(dummy_geom)
        ELSE dummy_geom
    END;
    EXECUTE format(
        'INSERT INTO %I.%I (geom) VALUES ($1) RETURNING gid',
        p_schema_namn, p_tabell_namn
    ) INTO dummy_gid USING dummy_geom;

    -- Registrera dummy-gid för framtida städning
    INSERT INTO public.hex_dummy_geometrier (schema_namn, tabell_namn, gid)
    VALUES (p_schema_namn, p_tabell_namn, dummy_gid);

    -- Lägg till AFTER INSERT-trigger som tar bort dummyn när riktig data anländer.
    -- Triggern skapas EFTER insättningen, vilket innebär att den inte avfyras
    -- för dummy-raden själv (den finns redan i tabellen när triggern skapas).
    EXECUTE format(
        'CREATE TRIGGER hex_ta_bort_dummy'
        ' AFTER INSERT ON %I.%I'
        ' FOR EACH ROW EXECUTE FUNCTION public.hex_ta_bort_dummy_rad()',
        p_schema_namn, p_tabell_namn
    );

    RAISE NOTICE '[hex_lagg_till_dummy_geometri] ✓ Dummy-geometri tillagd i %.% (gid: %, typ: %, srid: %)',
        p_schema_namn, p_tabell_namn, dummy_gid,
        p_geometriinfo.typ_basal, p_geometriinfo.srid;

EXCEPTION
    WHEN OTHERS THEN
        -- Stoppar inte tabellskapandet – loggar bara problemet
        RAISE NOTICE '[hex_lagg_till_dummy_geometri] ⚠ Kunde inte lägga till dummy i %.%: %',
            p_schema_namn, p_tabell_namn, SQLERRM;
        RAISE NOTICE '[hex_lagg_till_dummy_geometri]   Trolig orsak: obligatorisk kolumn utan standardvärde.';
        RAISE NOTICE '[hex_lagg_till_dummy_geometri]   Tabellen kan kräva manuell specifikation i QGIS.';
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info)
    IS 'Lägger till en minimal dummy-geometrirad i en geometritabell för att QGIS
ska kunna identifiera geometritypen via normal DB-anslutning (utan manuell dialog).
Dummy-koordinaterna läses från hex_installningar (dummy_x, dummy_y, dummy_storlek i
hex_installningar.srid) och transformeras till tabellens SRID vid behov. Geometrin
uppfyller alla hex_validera_geometri()-krav. Dummy-gid registreras i hex_dummy_geometrier
och en AFTER INSERT-trigger (hex_ta_bort_dummy) läggs till för att automatiskt
städa bort dummyn när den första riktiga raden infogats. Fel loggas som NOTICE
och stoppar inte tabellskapandet.';
