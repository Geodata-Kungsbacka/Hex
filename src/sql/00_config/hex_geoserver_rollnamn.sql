/******************************************************************************
 * Returnerar namnet på GeoServers tjänstekonto för ett schema.
 *
 * p_konto är 'las' (läs-workspacen) eller 'skriv' (skriv-workspacen). Kontot
 * hittas via hex_standardiserade_roller.geoserver_konto, inte via namnet, så
 * att rollmallen kan döpas om från gs_r_{schema}/gs_w_{schema} utan att
 * GeoServer-publiceringen slutar fungera.
 *
 * Returnerar NULL om ingen rollmall är markerad för p_konto.
 *
 * Används av hex_underhall() (steg 10) och GeoServer-lyssnaren.
 ******************************************************************************/
CREATE OR REPLACE FUNCTION public.hex_geoserver_rollnamn(p_schema text, p_konto text)
    RETURNS text
    LANGUAGE sql
    STABLE
AS $BODY$
    SELECT replace(rollnamn, '{schema}', p_schema)
    FROM   public.hex_standardiserade_roller
    WHERE  geoserver_konto = p_konto;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_geoserver_rollnamn(text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_geoserver_rollnamn(text, text)
    IS 'Returnerar GeoServers tjänstekonto för ett schema: p_konto = ''las'' eller ''skriv''. '
       'Slås upp via hex_standardiserade_roller.geoserver_konto. NULL om inget konto är markerat.';
