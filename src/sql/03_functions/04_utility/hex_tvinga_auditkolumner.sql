CREATE OR REPLACE FUNCTION public.hex_tvinga_auditkolumner()
    RETURNS trigger
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Åsidosätter alltid klientens värden för auditkolumner vid INSERT.
 *
 * Installeras som BEFORE INSERT-trigger på alla _kba_-tabeller som har
 * kolumnerna skapad_av, skapad_tidpunkt, andrad_av och andrad_tidpunkt.
 * Klientens inskickade värden (t.ex. från FME eller QGIS) kastas tyst och
 * ersätts med serversidans aktuella tid och den autentiserade användaren.
 *
 * Effekten är att det är omöjligt att förfalska auditkolumner vid INSERT,
 * oavsett vilket verktyg som används.
 *
 * Kolumnerna skyddas av separata mekanismer:
 *   skapad_av / skapad_tidpunkt  – denna BEFORE INSERT-trigger
 *   andrad_av / andrad_tidpunkt  – QA-triggern (BEFORE UPDATE OR DELETE)
 *                                  samt denna trigger vid INSERT
 *   gid                          – hex_tvinga_gid_fran_sekvens (BEFORE INSERT)
 ******************************************************************************/
BEGIN
    NEW.skapad_av       := session_user;
    NEW.skapad_tidpunkt := NOW();
    NEW.andrad_av       := session_user;
    NEW.andrad_tidpunkt := NOW();
    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION public.hex_tvinga_auditkolumner()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_tvinga_auditkolumner()
    IS 'BEFORE INSERT-trigger som alltid åsidosätter klientens auditkolumnvärden
(skapad_av, skapad_tidpunkt, andrad_av, andrad_tidpunkt) med serversidans
session_user och NOW(). Förhindrar att klienter (t.ex. FME, QGIS) kan skicka
egna värden för dessa kolumner. Triggeranropet hex_tvinga_auditkolumner skapas
automatiskt av hex_hantera_ny_tabell() på _kba_-tabeller med auditkolumner.';
