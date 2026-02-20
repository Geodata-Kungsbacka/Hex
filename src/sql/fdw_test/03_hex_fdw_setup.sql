-------------------------------------------------------------------------------
-- STEG 3: Sätt upp Hex-databasen med postgres_fdw
--
-- Kör detta mot: fdw_test_hex
-------------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-------------------------------------------------------------------------------
-- 3a. Definiera fjärrservern (pekar på db-sync-databasen)
-------------------------------------------------------------------------------
CREATE SERVER dbsync_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (
        host 'localhost',
        port '5432',
        dbname 'fdw_test_dbsync'
    );

-------------------------------------------------------------------------------
-- 3b. Användarmappning: lokal superuser → fjärr-läsroll
--      Byt 'postgres' till din lokala roll om den heter annat.
-------------------------------------------------------------------------------
CREATE USER MAPPING FOR postgres
    SERVER dbsync_server
    OPTIONS (
        user 'fdw_reader',
        password 'fdw_test_123'
    );

-------------------------------------------------------------------------------
-- 3c. Staging-schema för foreign tables
-------------------------------------------------------------------------------
CREATE SCHEMA dbsync_staging;

-------------------------------------------------------------------------------
-- 3d. Importera tabellerna från db-sync
-------------------------------------------------------------------------------
IMPORT FOREIGN SCHEMA mergin_trad
    FROM SERVER dbsync_server
    INTO dbsync_staging;

-------------------------------------------------------------------------------
-- Verifiering: Kan vi läsa fjärrtabellen?
-------------------------------------------------------------------------------
SELECT '=== Foreign table: dbsync_staging.trad_p ===' AS info;
SELECT fid, art, stamdiameter, skick, notering,
       ST_AsText(geom) AS geom_wkt
FROM dbsync_staging.trad_p;
