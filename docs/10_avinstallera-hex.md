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
DROP FUNCTION IF EXISTS public.tillämpa_grupprattigheter();
DROP FUNCTION IF EXISTS public.hex_lagg_till_dummy_geometri(text, text, hex_geom_info);
DROP FUNCTION IF EXISTS public.hex_ta_bort_dummy_rad() CASCADE;
DROP FUNCTION IF EXISTS public.hex_tvinga_gid_fran_sekvens() CASCADE;
DROP FUNCTION IF EXISTS public.hex_underhall();
DROP FUNCTION IF EXISTS public.reparera_rad_triggers();
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

-- 7. Konfigurationsfunktioner och roller
DROP FUNCTION IF EXISTS public.hex_schema_regex();
DROP FUNCTION IF EXISTS public.hex_systemagare();
DROP ROLE IF EXISTS hex_geoserver_roller;

-- 8. Konfigurationstabeller
DROP TABLE IF EXISTS public.hex_role_credentials;
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
