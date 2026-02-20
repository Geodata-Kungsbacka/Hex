-------------------------------------------------------------------------------
-- STEG 7: Städa upp efter test
--
-- Kör detta som superuser mot 'postgres'-databasen.
-- Tar bort allt som testet skapade.
-------------------------------------------------------------------------------

-- Avsluta eventuella aktiva anslutningar
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname IN ('fdw_test_hex', 'fdw_test_dbsync')
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS fdw_test_hex;
DROP DATABASE IF EXISTS fdw_test_dbsync;
DROP ROLE IF EXISTS fdw_reader;
