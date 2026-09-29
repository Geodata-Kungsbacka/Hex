-- FUNCTION: public.hex_validera_vynamn(text, text)

CREATE OR REPLACE FUNCTION public.hex_validera_vynamn(
    p_schema_namn text,
    p_vy_namn text)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
* Validerar att ett vynamn följer namngivningskonventionen:
* 1. Måste börja med v_
*    Exempel: v_ledningar_p
*
* 2. Suffix baserat på vyns geometriinnehåll enligt geometry_columns, med
*    suffixen från hex_installningar (hex_geometrisuffix()):
*    - Ingen geometri: Inget suffix
*    - En geometri: suffix_punkt, suffix_linje eller suffix_yta
*      (standard _p, _l, _y) baserat på geometrityp
*    - Flera geometrier: suffix_ovrigt (standard _g)
*
* Vid geometritransformationer (ST_-funktioner) måste resultatet
* explicit typkonverteras för att tydliggöra vilken geometrityp som
* skapas, t.ex:
*   ST_Buffer(geom, 100)::geometry(Polygon,3007)
*   ST_Union(geom)::geometry(LineString,3007)
******************************************************************************/
DECLARE
   antal_geom integer;       -- Antal geometrikolumner i vyn
   geom_typ text;           -- Geometrityp från systemtabell
   forvantat_suffix text;   -- Vilket suffix vynamnet ska ha
   begart_suffix text;      -- Suffixet som användaren försöker använda
   har_transformation boolean; -- Om vyn innehåller ST_-funktioner
BEGIN
   RAISE NOTICE E'\n=== START hex_validera_vynamn() ===';
   RAISE NOTICE 'Validerar vy %.%', p_schema_namn, p_vy_namn;

   -- Geometrisuffixet vynamnet slutar med, om något
   begart_suffix := public.hex_tabellsuffix(p_vy_namn);

   -- Kontrollera om vyn innehåller geometritransformationer
   SELECT definition ~* 'ST_[A-Za-z]+\s*\(' INTO har_transformation
   FROM pg_views
   WHERE schemaname = p_schema_namn 
   AND viewname = p_vy_namn;

   -- Räkna antalet geometrikolumner
   SELECT COUNT(*) INTO antal_geom
   FROM geometry_columns
   WHERE f_table_schema = p_schema_namn 
   AND f_table_name = p_vy_namn;

   -- Bestäm förväntat suffix baserat på antal geometrier
   CASE 
       -- Ingen geometri - inget suffix
       WHEN antal_geom = 0 THEN
           forvantat_suffix := '';
           
       -- En geometri - suffix alltid baserat på typ i systemtabell
       WHEN antal_geom = 1 THEN
           SELECT type INTO STRICT geom_typ 
           FROM geometry_columns 
           WHERE f_table_schema = p_schema_namn 
           AND f_table_name = p_vy_namn
           LIMIT 1;
           
           forvantat_suffix := public.hex_geometrisuffix(geom_typ);

       -- Flera geometrier - alltid suffix_ovrigt (standard _g)
       ELSE
           forvantat_suffix := public.hex_geometrisuffix('GEOMETRY');
   END CASE;

   -- Validera v-prefix och suffix. Båda jämförs exakt: i LIKE är _ ett
   -- jokertecken, så 'v_%' godtog t.ex. "vagar_l" och '%_p' "v_kartap".
   IF NOT (left(p_vy_namn, 2) = 'v_' AND
          (forvantat_suffix = '' OR begart_suffix IS NOT DISTINCT FROM forvantat_suffix)) THEN
       
       -- Om geometritransformation OCH generisk geometri, ge hjälpsamt meddelande
       IF har_transformation AND geom_typ = 'GEOMETRY' THEN
           RAISE EXCEPTION E'Ogiltigt vynamn "%.%".\n'
               'Vyn innehåller geometritransformationer (ST_-funktioner).\n'
               'Vid geometritransformationer måste resultatet explicit typkonverteras\n'
               'för att tydliggöra vilken geometrityp som skapas, t.ex:\n'
               '  ST_Buffer(geom, 100)::geometry(Polygon,%)  -- För suffix %\n'
               '  ST_Union(geom)::geometry(LineString,%)     -- För suffix %\n'
               'Suffix ska sedan matcha den typkonverterade geometritypen (%)',
               p_schema_namn, p_vy_namn,
               public.hex_srid(), public.hex_geometrisuffix('POLYGON'),
               public.hex_srid(), public.hex_geometrisuffix('LINESTRING'),
               coalesce(begart_suffix, '(inget suffix)');
       ELSE
           RAISE EXCEPTION E'Ogiltigt vynamn "%.%".\n'
               'Vynamn måste börja med v_\n'
               'och sluta med korrekt suffix för geometritypen (%)\n'
               'Exempel: v_mittnamn%',
               p_schema_namn, p_vy_namn,
               forvantat_suffix,
               forvantat_suffix;
       END IF;
   END IF;

   RAISE NOTICE '=== SLUT hex_validera_vynamn() ===\n';
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_validera_vynamn(text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;
