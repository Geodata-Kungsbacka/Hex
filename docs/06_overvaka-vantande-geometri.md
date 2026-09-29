# Övervaka väntande geometri

**Gäller:** Tabeller som skapats av ett ETL-verktyg (t.ex. FME) men ännu inte fått sin geometrikolumn.

---

## Bakgrund

Verktyg registrerade i `hex_systemanvandare` får skapa tabeller med geometrisuffix
(standard `_p`, `_l`, `_y`, `_g`, se `hex_installningar`) utan att ha en
geometrikolumn vid `CREATE TABLE`.
Hex registrerar dessa tabeller i `hex_afvaktande_geometri` och väntar på att
geometrikolumnen ska läggas till — med `ALTER TABLE ADD COLUMN geom geometry(...)`,
med PostGIS `AddGeometryColumn()`, eller med `ALTER TABLE` via `EXECUTE` i en
funktion.

När geometrikolumnen väl läggs till:
1. Suffixet kontrolleras mot geometritypen — fel suffix avbryter `ALTER TABLE`
2. SRID ≠ `hex_srid()` (standard 3007) ger en `WARNING` och en rad i `hex_avvikande_srid`
3. GiST-index skapas
4. Geometrivalidering aktiveras – för scheman vars datakategori har
   `hex_validera_geometri = true` i `hex_standardiserade_datakategorier`
   (standardkonfiguration: `_kba_`)
5. Raden tas bort från `hex_afvaktande_geometri`
6. En dummy-geometrirad läggs in, och `geom` läggs till i historiktabellen

En rad som **ligger kvar länge** för en tabell **utan** `geom` indikerar att
verktyget **aldrig slutförde sitt andra steg**.

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

## Tabell som har `geom` men står kvar

Har tabellen fått sin geometrikolumn men raden ändå ligger kvar, lades
kolumnen till på en väg Hex inte kände igen (äldre versioner missade t.ex.
`AddGeometryColumn()`). GiST-index, geometrivalidering och historik saknas då.
`hex_underhall()` slutför sådana tabeller — det sker automatiskt vid
`install_hex.py --upgrade`, eller manuellt:

```sql
SELECT * FROM public.hex_underhall()
WHERE trigger_namn = 'afvaktande_geometri';
```

`atgard = 'slutförd'` betyder att tabellen är klar och borttagen ur listan.

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
