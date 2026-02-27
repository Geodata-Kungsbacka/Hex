# Installera eller uppdatera Hex

**Gäller:** Första installation av Hex i en databas, eller uppdatering till en ny version.

---

## Förutsättningar

- Python 3 installerat på maskinen som kör installationsskriptet.
- Tillgång till databasen som en PostgreSQL-roll med `SUPERUSER` eller en roll med
  tillräckliga rättigheter för att skapa event-triggers och objekt i `public`-schemat.
  Normalt ägarrollen, t.ex. `gis_admin`.
- Källkoden från repositoryt (`install_hex.py` och `src/`).

---

## Steg 1 – Konfigurera installationsskriptet

Öppna `install_hex.py` i en texteditor och fyll i:

```python
DB_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "dbname":   "geodata",      # Databas att installera Hex i
    "user":     "gis_admin",    # Databasanvändare
    "password": "losenord_har"
}

OWNER_ROLE = "gis_admin"        # Rollen som ska äga Hex-objekt
```

> Installationsskriptet måste köras **en gång per databas** om du har
> flera databaser som ska ha Hex.

---

## Steg 2 – Kör installationen

```bash
python install_hex.py
```

Skriptet installerar alla typer, tabeller, funktioner, triggers och event-triggers
i rätt ordning. En utskrift bekräftar varje steg.

---

## Verifiera installationen

```sql
-- Alla event triggers ska synas
SELECT evtname, evtevent, evtenabled
FROM pg_event_trigger
ORDER BY evtname;

-- Konfigurationstabellerna ska finnas
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename LIKE '%hex%'
   OR tablename LIKE 'standardiserade%'
ORDER BY tablename;
```

---

## Uppdatera Hex till en ny version

En uppdatering görs genom att köra `install_hex.py` igen. Skriptet kör
`CREATE OR REPLACE` på funktioner och triggers, och hanterar
strukturändringar i tabellerna.

```bash
git pull          # Hämta senaste versionen
python install_hex.py
```

> **OBS:** Konfigurationstabellerna (`standardiserade_kolumner`,
> `standardiserade_roller`, `hex_systemanvandare`) berörs normalt inte
> vid uppdatering – befintliga rader bevaras.

---

## Manuell installation (alternativ)

Om du föredrar att köra SQL direkt, se installationsordningen i `README.md`
under avsnittet *Detaljerad installationsordning*. Starta alltid med
`src/sql/00_config/system_owner.sql` och ange ägarrollen där.

---

## Kontrollera systemstatus

```sql
-- Verifiera att triggers är aktiva
SELECT evtname, evtenabled
FROM pg_event_trigger
WHERE evtenabled != 'D'
ORDER BY evtname;

-- Kontrollera standardkolumner
SELECT kolumnnamn, ordinal_position
FROM standardiserade_kolumner
ORDER BY ordinal_position;
```
