# Avinstallera Hex

**Gäller:** Fullständig borttagning av Hex från en databas.

---

## Varning

Avinstallation tar bort alla event-triggers, funktioner, konfigurationstabeller
och anpassade datatyper som Hex installerade. Tabeller och scheman i databasen
**berörs inte** – data raderas inte.

**Obs:** Så länge Hex är installerat tas historiktabeller (`_h`) och
QA-triggerfunktioner (`trg_fn_*_qa`) bort automatiskt när föräldratabellen
droppas. Efter avinstallation är den event-triggern borta – kvarvarande `_h`-tabeller
och QA-funktioner måste därefter rensas manuellt vid behov.

---

## Metod 1 – Installationsskriptet (rekommenderat)

Konfigurationsuppgifterna i `install_hex.py` måste peka mot rätt databas
(se [09_installera-uppdatera-hex.md](09_installera-uppdatera-hex.md)).

```bash
python install_hex.py --uninstall
```

Skriptet kör alla `DROP`-satser i rätt ordning och rullar tillbaka om något
misslyckas.

---

## Metod 2 – Manuell SQL

Kör följande som superanvändare (t.ex. `postgres`) i aktuell databas.
Ordningen är viktig.

```sql
-- 1. Event triggers (måste tas bort innan funktioner)
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_borttagning_trigger;
DROP EVENT TRIGGER IF EXISTS hex_notifiera_gs_trigger;
DROP EVENT TRIGGER IF EXISTS hex_validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_blockera_schema_namnbyte_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_std_roller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_kolumn_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hex_hantera_borttagen_tabell_trigger;

-- 2. Triggerfunktioner
DROP FUNCTION IF EXISTS public.hex_notifiera_gs_borttagning();
DROP FUNCTION IF EXISTS public.hex_notifiera_gs();
DROP FUNCTION IF EXISTS public.hex_hantera_std_roller();
DROP FUNCTION IF EXISTS public.hex_ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_kolumn();
DROP FUNCTION IF EXISTS public.hex_hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hex_hantera_borttagen_tabell();
DROP FUNCTION IF EXISTS public.hex_kontrollera_geometri_trigger() CASCADE;

-- 3. Hjälpfunktioner
DROP FUNCTION IF EXISTS public.hex_tillampa_grupprattigheter();
DROP FUNCTION IF EXISTS public.hex_aterskapa_qa_trigger(text, text, text);
DROP FUNCTION IF EXISTS public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_ta_bort_dummy_rad() CASCADE;
DROP FUNCTION IF EXISTS public.hex_tvinga_gid_fran_sekvens() CASCADE;
DROP FUNCTION IF EXISTS public.hex_pausstatus();
DROP FUNCTION IF EXISTS public.hex_ateruppta(boolean);
DROP FUNCTION IF EXISTS public.hex_pausa(text, integer, boolean);
DROP FUNCTION IF EXISTS public.hex_triggerlage_sats(text);
DROP FUNCTION IF EXISTS public.hex_underhall();
DROP FUNCTION IF EXISTS public.hex_tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.hex_skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.hex_uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.hex_byt_ut_tabell(text, text, text);

-- 4. Regelfunktioner
DROP FUNCTION IF EXISTS public.hex_aterskapa_kolumnegenskaper(text, text, hex_kolumnegenskaper);
DROP FUNCTION IF EXISTS public.hex_aterskapa_tabellregler(text, text, hex_tabellregler);
DROP FUNCTION IF EXISTS public.hex_spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.hex_spara_tabellregler(text, text);

-- 5. Valideringsfunktioner
DROP FUNCTION IF EXISTS public.hex_forklara_geometrifel(geometry);
DROP FUNCTION IF EXISTS public.hex_validera_geometri(geometry) CASCADE;
DROP FUNCTION IF EXISTS public.hex_validera_schemanamn();
DROP FUNCTION IF EXISTS public.hex_blockera_schema_namnbyte();
DROP FUNCTION IF EXISTS public.hex_validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.hex_validera_tabell(text, text);

-- 6. Strukturfunktioner
DROP FUNCTION IF EXISTS public.hex_hamta_kolumnstandard(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_hamta_geometri_definition(text, text);

-- 7. Konfigurationsfunktioner
DROP FUNCTION IF EXISTS public.hex_schema_regex();
DROP FUNCTION IF EXISTS public.hex_systemagare();
-- OBS: hex_geoserver_roller tas INTE bort här – se avsnittet nedan.

-- 8. Konfigurationstabeller
DROP TABLE IF EXISTS public.hex_paus;
DROP TABLE IF EXISTS public.hex_rolluppgifter;
DROP TABLE IF EXISTS public.hex_avvikande_srid;
DROP TABLE IF EXISTS public.hex_dummy_geometrier;
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_grupprattigheter;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.hex_standardiserade_roller;
DROP TABLE IF EXISTS public.hex_standardiserade_kolumner;
DROP TABLE IF EXISTS public.hex_standardiserade_skyddsnivaer;
DROP TABLE IF EXISTS public.hex_standardiserade_datakategorier;

-- 9. Anpassade datatyper (sist)
DROP TYPE IF EXISTS public.hex_tabellregler;
DROP TYPE IF EXISTS public.hex_kolumnegenskaper;
DROP TYPE IF EXISTS public.hex_kolumnkonfig;
DROP TYPE IF EXISTS public.hex_geom_info;
```

---

---

## Rollen `hex_geoserver_roller` — ta inte bort den rutinmässigt

`hex_geoserver_roller` är en **klusterroll**, inte ett databasobjekt. Samma roll
delas av alla databaser i klustret som kör Hex, och den är målet för
`pg_hba.conf`-posten `+hex_geoserver_roller`.

Droppar du den när du avinstallerar Hex ur *en* databas förlorar alla
`gs_r_`/`gs_w_`-konton i klustrets **övriga** databaser sitt gruppmedlemskap.
De matchar då inte längre `pg_hba.conf`, och GeoServer tappar anslutningen till
scheman som inte har med den avinstallerade databasen att göra. Därför tar
varken `install_hex.py --uninstall` eller SQL:en ovan bort rollen.

Ska Hex bort ur **samtliga** databaser i klustret, och rollen inte längre
behövas, tar du bort den separat efteråt:

```sql
-- Kontrollera först att inga medlemmar finns kvar
SELECT m.rolname
FROM pg_auth_members am
JOIN pg_roles g ON g.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE g.rolname = 'hex_geoserver_roller';

-- Tom lista ovan → rollen kan tas bort
DROP ROLE hex_geoserver_roller;
```

Glöm inte att ta bort motsvarande `+hex_geoserver_roller`-post ur
`pg_hba.conf` och köra `SELECT pg_reload_conf();`.

---

## Efter avinstallation

- Event-triggers är borttagna – Hex kommer inte längre hantera `CREATE TABLE`,
  `CREATE SCHEMA` m.m. Befintliga tabeller och scheman fortsätter fungera.
- GeoServer-lyssnartjänsten kan stoppas och avinstalleras separat:
  ```cmd
  py geoserver_service.py stop
  py geoserver_service.py remove
  ```
- Historiktabeller (`_h`) och QA-triggerfunktioner (`trg_fn_*_qa`) som
  skapades innan avinstallationen finns kvar och måste tas bort manuellt
  om de inte längre behövs. (Framtida DROP TABLE på föräldratabellen
  utlöser inte längre automatisk städning – event-triggern är borta.)
