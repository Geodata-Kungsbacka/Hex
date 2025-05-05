-- FUNCTION: public.validera_vynamn(text, text)

-- DROP FUNCTION IF EXISTS public.validera_vynamn(text, text);

CREATE OR REPLACE FUNCTION public.validera_vynamn(
	p_schema_namn text,
	p_vy_namn text)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
* Validerar att ett vynamn foljer namngivningskonventionen:
* 1. Maste borja med schemanamn + _v_
*    Exempel: teknik.teknik_v_ledningar_p
*
* 2. Suffix baserat pa vyns geometriinnehall enligt geometry_columns:
*    - Ingen geometri: Inget suffix
*    - En geometri: _p, _l eller _y baserat pa geometrityp
*    - Flera geometrier: _g
*
* Vid geometritransformationer (ST_-funktioner) maste resultatet
* explicit typkonverteras for att tydliggora vilken geometrityp som
* skapas, t.ex:
*   ST_Buffer(geom, 100)::geometry(Polygon,3007)
*   ST_Union(geom)::geometry(LineString,3007)
******************************************************************************/
DECLARE
   antal_geom integer;       -- Antal geometrikolumner i vyn
   geom_typ text;           -- Geometrityp fran systemtabell
   forvantat_suffix text;   -- Vilket suffix vynamnet ska ha
   begart_suffix text;      -- Suffixet som anvandaren forsoker anvanda
   har_transformation boolean; -- Om vyn innehaller ST_-funktioner
BEGIN
   RAISE NOTICE E'\n=== START validera_vynamn() ===';
   RAISE NOTICE 'Validerar vy %.%', p_schema_namn, p_vy_namn;

   -- Extrahera onskat suffix fran vynamnet (sista tva tecknen)
   begart_suffix := right(p_vy_namn, 2);

   -- Kontrollera om vyn innehaller geometritransformationer
   SELECT definition ~* 'ST_[A-Za-z]+\s*\(' INTO har_transformation
   FROM pg_views
   WHERE schemaname = p_schema_namn 
   AND viewname = p_vy_namn;

   -- Rakna antalet geometrikolumner
   SELECT COUNT(*) INTO antal_geom
   FROM geometry_columns
   WHERE f_table_schema = p_schema_namn 
   AND f_table_name = p_vy_namn;

   -- Bestam forvantat suffix baserat pa antal geometrier
   CASE 
       -- Ingen geometri - inget suffix
       WHEN antal_geom = 0 THEN
           forvantat_suffix := '';
           
       -- En geometri - suffix alltid baserat pa typ i systemtabell
       WHEN antal_geom = 1 THEN
           SELECT type INTO STRICT geom_typ 
           FROM geometry_columns 
           WHERE f_table_schema = p_schema_namn 
           AND f_table_name = p_vy_namn
           LIMIT 1;
           
           forvantat_suffix := CASE 
               WHEN geom_typ IN ('POINT', 'MULTIPOINT') THEN '_p'
               WHEN geom_typ IN ('LINESTRING', 'MULTILINESTRING') THEN '_l'
               WHEN geom_typ IN ('POLYGON', 'MULTIPOLYGON') THEN '_y'
               ELSE '_g'
           END;
           
       -- Flera geometrier - alltid _g
       ELSE
           forvantat_suffix := '_g';
   END CASE;

   -- Validera v-prefix och suffix
   IF NOT (p_vy_namn LIKE p_schema_namn || '_v_%' AND 
           (forvantat_suffix = '' OR p_vy_namn LIKE '%' || forvantat_suffix)) THEN
       
       -- Om geometritransformation OCH generisk geometri, ge hjalpsamt meddelande
       IF har_transformation AND geom_typ = 'GEOMETRY' THEN
           RAISE EXCEPTION E'Ogiltigt vynamn "%.%".\n'
               'Vyn innehåller geometritransformationer (ST_-funktioner).\n'
               'Vid geometritransformationer måste resultatet explicit typkonverteras\n'
               'för att tydliggöra vilken geometrityp som skapas, t.ex:\n'
               '  ST_Buffer(geom, 100)::geometry(Polygon,3007)  -- För suffix _y\n'
               '  ST_Union(geom)::geometry(LineString,3007)     -- För suffix _l\n'
               'Suffix ska sedan matcha den typkonverterade geometritypen (%)',
               p_schema_namn, p_vy_namn,
               begart_suffix;
       ELSE
           RAISE EXCEPTION E'Ogiltigt vynamn "%.%".\n'
               'Vynamn måste börja med schemanamn följt av _v_\n'
               'och sluta med korrekt suffix för geometritypen (%)\n'
               'Exempel: %_v_mittnamn%',
               p_schema_namn, p_vy_namn,
               forvantat_suffix,
               p_schema_namn, forvantat_suffix;
       END IF;
   END IF;

   RAISE NOTICE '=== SLUT validera_vynamn() ===\n';
END;
$BODY$;

ALTER FUNCTION public.validera_vynamn(text, text)
    OWNER TO postgres;
