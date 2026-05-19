/******************************************************************************
 * Returnerar ett reguljärt uttryck som matchar alla giltiga Hex-schemanamn,
 * byggt dynamiskt från prefixen i standardiserade_skyddsnivaer.
 *
 * Exempel med standardkonfiguration (sk0, sk1, sk2, skx):
 *   Returnerar: ^(sk0|sk1|sk2|skx)_
 *
 * Används överallt där kod behöver avgöra om ett schemanamn tillhör Hex,
 * så att egna prefix (t.ex. sc1) fungerar utan kodändringar.
 *
 * VOLATILE (inte IMMUTABLE/STABLE) eftersom standardiserade_skyddsnivaer
 * kan ändras under körning.
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_schema_regex()
    RETURNS text
    LANGUAGE sql
    VOLATILE
AS $BODY$
    SELECT '^(' || string_agg(prefix, '|' ORDER BY prefix) || ')_'
    FROM   public.standardiserade_skyddsnivaer;
$BODY$;

ALTER FUNCTION public.hex_schema_regex()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_schema_regex()
    IS 'Returnerar ett reguljärt uttryck som matchar alla giltiga Hex-schemanamn, '
       'byggt dynamiskt från standardiserade_skyddsnivaer. '
       'Exempel: ^(sk0|sk1|sk2|skx)_ '
       'Används för att undvika hårdkodade schemaprefix i funktionslogik.';
