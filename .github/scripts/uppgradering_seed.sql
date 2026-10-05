-- Användardata som uppgraderingskontrollen bygger upp innan upgrade() körs.
--
-- Körs två gånger av kontrollera_uppgradering.py: en gång under basversionen
-- (databasen som sedan uppgraderas) och en gång under den nya versionen
-- (referensdatabasen). Efter uppgraderingen ska objekten se likadana ut i båda.
-- Täcker de vanligaste formerna: tabell med historik (sk1_kba), tabell utan
-- historik (sk0_ext), tabell utan geometri, vy, FME:s väntande tvåsteg,
-- egna index och constraints samt ett kolumnnamnbyte efter skapandet.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA sk0_ext_uppgr;
CREATE SCHEMA sk1_kba_uppgr;

CREATE TABLE sk1_kba_uppgr.vagar_l (
    namn  text NOT NULL,
    klass integer DEFAULT 1 CHECK (klass > 0),
    geom  geometry(LineString, 3007)
);
CREATE INDEX vagar_l_namn_idx ON sk1_kba_uppgr.vagar_l (namn);
INSERT INTO sk1_kba_uppgr.vagar_l (namn, geom)
VALUES ('Storgatan', 'SRID=3007;LINESTRING(0 0,10 10)'),
       ('Lillgatan', 'SRID=3007;LINESTRING(0 10,10 0)');
UPDATE sk1_kba_uppgr.vagar_l SET klass = 2 WHERE namn = 'Storgatan';
DELETE FROM sk1_kba_uppgr.vagar_l WHERE namn = 'Lillgatan';
ALTER TABLE sk1_kba_uppgr.vagar_l RENAME COLUMN namn TO vagnamn;

CREATE TABLE sk1_kba_uppgr.ansvar (
    vag_gid   integer,
    ansvarig  text
);
INSERT INTO sk1_kba_uppgr.ansvar (vag_gid, ansvarig) VALUES (1, 'Gatuenheten');

CREATE TABLE sk0_ext_uppgr.adresser_p (
    adress text UNIQUE,
    geom   geometry(Point, 3007)
);
INSERT INTO sk0_ext_uppgr.adresser_p (adress, geom)
VALUES ('Storgatan 1', 'SRID=3007;POINT(1 1)');

CREATE VIEW sk0_ext_uppgr.v_adresser_p AS
SELECT gid, adress, geom FROM sk0_ext_uppgr.adresser_p;

-- FME:s steg A utan steg B: tabellen står kvar som väntande i
-- hex_afvaktande_geometri och ska göra det även efter uppgraderingen.
SET application_name = 'fme';
CREATE TABLE sk0_ext_uppgr.import_y (objectid integer, namn text);
RESET application_name;
