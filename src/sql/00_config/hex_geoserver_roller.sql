/******************************************************************************
 * Skapar grupprollen hex_geoserver_roller.
 *
 * Syftet med denna roll är att samla alla Hex-skapade systemanvändare
 * (r_* och w_*) i en gemensam grupp, utan några egna rättigheter.
 * Detta gör det möjligt att konfigurera din PostgreSQL-server att tillåta
 * uppkopplingar med dessa användare genom att referera till gruppen
 * (+hex_geoserver_roller) i pg_hba.conf, istället för att lista varje
 * enskild roll manuellt.
 *
 * Rollen har inga egna rättigheter – den fungerar enbart som
 * autentiseringsmarkör i pg_hba.conf.
 ******************************************************************************/
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hex_geoserver_roller') THEN
        CREATE ROLE hex_geoserver_roller WITH NOLOGIN;
    END IF;
END$$;

COMMENT ON ROLE hex_geoserver_roller IS
    'Gruproll för alla Hex-skapade systemanvändare (r_* och w_*). '
    'Har inga egna rättigheter. Används som autentiseringsmarkör i '
    'pg_hba.conf (+hex_geoserver_roller) för att tillåta uppkopplingar '
    'utan att lista varje roll individuellt.';
