-------------------------------------------------------------------------------
-- STEG 2: Sätt upp db-sync-databasen (simulerad Mergin db-sync)
--
-- Kör detta mot: fdw_test_dbsync
-------------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS postgis;

-- Schema som simulerar ett Mergin-projekt
CREATE SCHEMA mergin_trad;

-- Trädtabell — enkel struktur, ingen Hex-logik
CREATE TABLE mergin_trad.trad_p (
    fid             integer PRIMARY KEY,
    art             text,
    stamdiameter    integer,        -- cm
    skick           text,           -- 'God', 'Nedsatt', 'Dålig'
    notering        text,
    geom            geometry(Point, 3007)
);

-- Testdata: några träd
INSERT INTO mergin_trad.trad_p (fid, art, stamdiameter, skick, notering, geom) VALUES
(1, 'Ek',    85, 'God',     'Stort träd vid parkeringen',  ST_SetSRID(ST_MakePoint(326000, 6398000), 3007)),
(2, 'Lind',  45, 'Nedsatt', 'Svampangrepp på stammen',     ST_SetSRID(ST_MakePoint(326050, 6398010), 3007)),
(3, 'Björk', 30, 'God',     NULL,                          ST_SetSRID(ST_MakePoint(326100, 6398020), 3007)),
(4, 'Ek',    60, 'Dålig',   'Toppbrott efter storm',       ST_SetSRID(ST_MakePoint(326150, 6398030), 3007)),
(5, 'Alm',   55, 'God',     'Resistklon',                  ST_SetSRID(ST_MakePoint(326200, 6398040), 3007));

-- En läsroll som fdw kommer använda
CREATE ROLE fdw_reader LOGIN PASSWORD 'fdw_test_123';
GRANT USAGE ON SCHEMA mergin_trad TO fdw_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mergin_trad TO fdw_reader;
