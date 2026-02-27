# Övervaka väntande geometri

**Gäller:** Tabeller som skapats av ett ETL-verktyg (t.ex. FME) men ännu inte fått sin geometrikolumn.

---

## Bakgrund

Verktyg registrerade i `hex_systemanvandare` får skapa tabeller med geometrisuffix
(`_p`, `_l`, `_y`, `_g`) utan att ha en geometrikolumn vid `CREATE TABLE`.
Hex registrerar dessa tabeller i `hex_afvaktande_geometri` och väntar på att
`ALTER TABLE ADD COLUMN geom geometry(...)` ska köras.

När geometrikolumnen väl läggs till:
1. Raden tas bort från `hex_afvaktande_geometri`
2. GiST-index skapas
3. Geometrivalidering aktiveras (för `_kba_`-scheman)

En rad som **ligger kvar länge** indikerar att verktyget **aldrig slutförde sitt andra steg**.

---

## Kontrollera aktuell status

```sql
SELECT
    schema_namn,
    tabell_namn,
    registrerad_av,
    registrerad,
    now() - registrerad AS elapsed
FROM hex_afvaktande_geometri
ORDER BY registrerad;
```

---

## Tolka resultatet

| Elapsed | Bedömning |
|---------|-----------|
| Sekunder – minuter | Normalt – verktyget håller på |
| Timmar | Troligt fel – FME-jobbet kan ha kraschat |
| Dagar | Kritiskt – tabellen är troligen övergiven |

---

## Åtgärda en övergiven tabell

En tabell som aldrig fick sin geometrikolumn är ofullständig och bör
normalt tas bort och återskapas:

```sql
-- Kontrollera tabellens innehåll
SELECT * FROM <schema_namn>.<tabell_namn> LIMIT 5;

-- Ta bort tabellen (Hex rensar automatiskt hex_afvaktande_geometri)
DROP TABLE <schema_namn>.<tabell_namn>;
```

Starta sedan om ETL-jobbet som skapade tabellen.

---

## Manuell rensning (i undantagsfall)

Om tabellen redan är borttagen men raden ändå finns kvar:

```sql
DELETE FROM hex_afvaktande_geometri
WHERE schema_namn = '<schema>'
  AND tabell_namn = '<tabell>';
```

---

## Automatisera bevakning

Lägg upp en schemalagd fråga (t.ex. via `pg_cron` eller ett externt jobb)
som varnar om rader är äldre än förväntat:

```sql
SELECT schema_namn, tabell_namn, registrerad
FROM hex_afvaktande_geometri
WHERE registrerad < now() - interval '2 hours';
```

En tom resultatmängd är det normala utfallet.
