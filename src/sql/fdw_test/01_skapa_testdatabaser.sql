-------------------------------------------------------------------------------
-- STEG 1: Skapa två rena testdatabaser
--
-- Kör detta som superuser (postgres) mot t.ex. 'postgres'-databasen.
-- Resultatet: två tomma databaser med PostGIS.
-------------------------------------------------------------------------------

-- Rensa eventuella tidigare testkörningar
DROP DATABASE IF EXISTS fdw_test_hex;
DROP DATABASE IF EXISTS fdw_test_dbsync;

-- Skapa databaserna
CREATE DATABASE fdw_test_dbsync;
CREATE DATABASE fdw_test_hex;

-- Aktivera PostGIS i båda (kör separat mot respektive databas)
-- Se steg 2 och 3.
