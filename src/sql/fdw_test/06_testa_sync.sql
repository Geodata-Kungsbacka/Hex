-------------------------------------------------------------------------------
-- STEG 6: Testa hela flödet
--
-- Kör detta mot: fdw_test_hex (förutom 6b som körs mot fdw_test_dbsync)
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- 6a. Första sync — alla 5 träd ska INSERTas
-------------------------------------------------------------------------------
SELECT '=== SYNC 1: Första körningen ===' AS steg;
SELECT * FROM public.sync_trad_fran_dbsync();
-- Förväntat: insatta=5, uppdaterade=0, borttagna=0

SELECT '=== Lokal trad_p efter sync 1 ===' AS steg;
SELECT gid, art, stamdiameter, skick, skapad_av, skapad_tidpunkt,
       andrad_av, andrad_tidpunkt
FROM public.trad_p ORDER BY gid;
-- skapad_av/skapad_tidpunkt ska vara satt, andrad_av/andrad_tidpunkt ska vara NULL

SELECT '=== Historik efter sync 1 ===' AS steg;
SELECT * FROM public.trad_p_h ORDER BY h_tidpunkt;
-- Ska vara TOM — inga uppdateringar/borttagningar ännu


-------------------------------------------------------------------------------
-- 6b. Simulera fältarbete (KÖR MOT fdw_test_dbsync!)
--     Ändra ett träd, lägg till ett nytt, ta bort ett
-------------------------------------------------------------------------------
-- *** KÖR DETTA I EN SEPARAT ANSLUTNING MOT fdw_test_dbsync ***
--
-- UPDATE mergin_trad.trad_p
-- SET    skick = 'Dålig', notering = 'Rötskada upptäckt'
-- WHERE  fid = 3;
--
-- INSERT INTO mergin_trad.trad_p (fid, art, stamdiameter, skick, notering, geom)
-- VALUES (6, 'Lönn', 25, 'God', 'Nyplanterad',
--         ST_SetSRID(ST_MakePoint(326250, 6398050), 3007));
--
-- DELETE FROM mergin_trad.trad_p WHERE fid = 4;
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- 6c. Andra sync — ska fånga ändringarna (KÖR MOT fdw_test_hex)
-------------------------------------------------------------------------------
SELECT '=== SYNC 2: Efter fältändringar ===' AS steg;
SELECT * FROM public.sync_trad_fran_dbsync();
-- Förväntat: insatta=1 (fid 6), uppdaterade=1 (fid 3), borttagna=1 (fid 4)

SELECT '=== Lokal trad_p efter sync 2 ===' AS steg;
SELECT gid, art, stamdiameter, skick, notering,
       skapad_av, skapad_tidpunkt,
       andrad_av, andrad_tidpunkt
FROM public.trad_p ORDER BY gid;
-- gid 3: andrad_av + andrad_tidpunkt ska vara satt nu
-- gid 4: borta
-- gid 6: ny rad

SELECT '=== Historik efter sync 2 ===' AS steg;
SELECT h_typ, h_tidpunkt, h_av, gid, art, skick, notering
FROM public.trad_p_h ORDER BY h_tidpunkt;
-- Ska innehålla:
--   'U' — gid 3 (gamla värdet: skick='God', notering=NULL)
--   'D' — gid 4 (eken som togs bort)


-------------------------------------------------------------------------------
-- 6d. Tredje sync — inget ändrat, ska vara idempotent
-------------------------------------------------------------------------------
SELECT '=== SYNC 3: Ingen förändring ===' AS steg;
SELECT * FROM public.sync_trad_fran_dbsync();
-- Förväntat: insatta=0, uppdaterade=0, borttagna=0

SELECT '=== Historik efter sync 3 (ska vara oförändrad) ===' AS steg;
SELECT count(*) AS antal_historikrader FROM public.trad_p_h;
-- Ska fortfarande vara 2 rader (samma som efter sync 2)
