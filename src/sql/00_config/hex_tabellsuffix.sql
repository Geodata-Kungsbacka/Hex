/******************************************************************************
 * Returnerar det geometrisuffix (enligt hex_installningar) som p_namn slutar
 * med, eller NULL om namnet inte slutar med något av dem.
 *
 * Ersätter mönstret '_[plyg]$' där koden behöver veta om ett namn bär ett
 * geometrisuffix, t.ex. för att avvisa ett suffix på en tabell utan geometri
 * eller känna igen en tabell som väntar på sin geometrikolumn.
 *
 * Suffixen består av ett understreck följt av [a-z0-9]+ (CHECK i
 * hex_installningar), så högst ett av dem kan matcha.
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_tabellsuffix(p_namn text)
    RETURNS text
    LANGUAGE sql
    STABLE
AS $BODY$
    SELECT s.suffix
    FROM   public.hex_installningar i,
           unnest(ARRAY[i.suffix_punkt, i.suffix_linje,
                        i.suffix_yta,   i.suffix_ovrigt]) AS s(suffix)
    WHERE  right(p_namn, length(s.suffix)) = s.suffix
      AND  length(p_namn) > length(s.suffix);
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_tabellsuffix(text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_tabellsuffix(text)
    IS 'Returnerar det geometrisuffix (hex_installningar) som namnet slutar med, eller NULL.';
