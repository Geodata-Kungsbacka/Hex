# Avinstallera Hex

**Gäller:** Fullständig borttagning av Hex från en databas.

---

## Varning

Avinstallation tar bort alla event-triggers, funktioner, konfigurationstabeller
och anpassade datatyper som Hex installerade. Tabeller och scheman i databasen
**berörs inte** – data raderas inte. Historiktabeller (`_h`) och QA-funktioner
som Hex skapade per tabell tas **inte** bort automatiskt och måste rensas manuellt
om de inte längre behövs.

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
DROP EVENT TRIGGER IF EXISTS notifiera_geoserver_trigger;
DROP EVENT TRIGGER IF EXISTS validera_schemanamn_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_standardiserade_roller_trigger;
DROP EVENT TRIGGER IF EXISTS ta_bort_schemaroller_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_vy_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_kolumntillagg_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_ny_tabell_trigger;
DROP EVENT TRIGGER IF EXISTS hantera_borttagen_tabell_trigger;

-- 2. Triggerfunktioner
DROP FUNCTION IF EXISTS public.notifiera_geoserver();
DROP FUNCTION IF EXISTS public.hantera_standardiserade_roller();
DROP FUNCTION IF EXISTS public.ta_bort_schemaroller();
DROP FUNCTION IF EXISTS public.hantera_ny_vy();
DROP FUNCTION IF EXISTS public.hantera_kolumntillagg();
DROP FUNCTION IF EXISTS public.hantera_ny_tabell();
DROP FUNCTION IF EXISTS public.hantera_borttagen_tabell();

-- 3. Hjälpfunktioner
DROP FUNCTION IF EXISTS public.tilldela_rollrattigheter(text, text, text);
DROP FUNCTION IF EXISTS public.skapa_historik_qa(text, text);
DROP FUNCTION IF EXISTS public.uppdatera_sekvensnamn(text, text, text);
DROP FUNCTION IF EXISTS public.byt_ut_tabell(text, text, text);

-- 4. Regelfunktioner
DROP FUNCTION IF EXISTS public.aterskapa_kolumnegenskaper(text, text, kolumnegenskaper);
DROP FUNCTION IF EXISTS public.aterskapa_tabellregler(text, text, tabellregler);
DROP FUNCTION IF EXISTS public.spara_kolumnegenskaper(text, text);
DROP FUNCTION IF EXISTS public.spara_tabellregler(text, text);

-- 5. Valideringsfunktioner
DROP FUNCTION IF EXISTS public.validera_geometri(geometry, float) CASCADE;
DROP FUNCTION IF EXISTS public.validera_schemanamn();
DROP FUNCTION IF EXISTS public.validera_vynamn(text, text);
DROP FUNCTION IF EXISTS public.validera_tabell(text, text);

-- 6. Strukturfunktioner
DROP FUNCTION IF EXISTS public.hamta_kolumnstandard(text, text, geom_info);
DROP FUNCTION IF EXISTS public.hamta_geometri_definition(text, text);
DROP FUNCTION IF EXISTS public.system_owner();

-- 7. Konfigurationstabeller
DROP TABLE IF EXISTS public.hex_afvaktande_geometri;
DROP TABLE IF EXISTS public.hex_systemanvandare;
DROP TABLE IF EXISTS public.hex_metadata;
DROP TABLE IF EXISTS public.standardiserade_roller;
DROP TABLE IF EXISTS public.standardiserade_kolumner;

-- 8. Anpassade datatyper (sist)
DROP TYPE IF EXISTS public.tabellregler;
DROP TYPE IF EXISTS public.kolumnegenskaper;
DROP TYPE IF EXISTS public.kolumnkonfig;
DROP TYPE IF EXISTS public.geom_info;
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
- Historiktabeller (`_h`) och deras triggers/funktioner per tabell
  måste tas bort manuellt om de inte längre behövs.
