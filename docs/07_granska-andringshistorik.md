# Granska ändringshistorik

**Gäller:** Spårning av vem som ändrat eller raderat data, och vad som ändrades.

---

## Bakgrund

För varje tabell i ett schema som har minst en kolumn med `historik_qa = true`
i `standardiserade_kolumner` skapar Hex automatiskt en historiktabell med
suffixet `_h`. Historiktabellen innehåller alla kolumner från originaltabellen
plus tre extra:

| Kolumn | Beskrivning |
|--------|-------------|
| `h_typ` | `U` = uppdatering, `D` = radering |
| `h_tidpunkt` | Tidpunkt för händelsen |
| `h_av` | Databasanvändaren som utförde ändringen |

Historiktabellen loggar automatiskt vid varje `UPDATE` och `DELETE`.
`INSERT` loggas inte – de syns i originaltabellen.

---

## Visa historik för en tabell

```sql
SELECT *
FROM sk1_kba_parkering.p_platser_p_h
ORDER BY h_tidpunkt DESC
LIMIT 50;
```

Ersätt `sk1_kba_parkering.p_platser_p_h` med aktuellt schema och tabellnamn + `_h`.

---

## Granska en specifik rad

```sql
SELECT h_typ, h_tidpunkt, h_av, *
FROM sk1_kba_parkering.p_platser_p_h
WHERE gid = 42
ORDER BY h_tidpunkt;
```

---

## Vad har en specifik användare ändrat?

```sql
SELECT h_typ, h_tidpunkt, gid
FROM sk1_kba_parkering.p_platser_p_h
WHERE h_av = 'anna_andersson'
  AND h_tidpunkt > now() - interval '30 days'
ORDER BY h_tidpunkt DESC;
```

---

## Lista alla tabeller med historik

```sql
SELECT parent_schema, parent_table, history_table
FROM hex_metadata
ORDER BY parent_schema, parent_table;
```

---

## Återställa en raderad rad

Historiktabellen innehåller radens fullständiga värden vid raderingstillfället.
För att återskapa den:

```sql
INSERT INTO sk1_kba_parkering.p_platser_p (
    -- Lista kolumner manuellt, exkludera h_typ, h_tidpunkt, h_av
    gid, namn, kapacitet, geom
)
SELECT gid, namn, kapacitet, geom
FROM sk1_kba_parkering.p_platser_p_h
WHERE gid = 42
  AND h_typ = 'D'
ORDER BY h_tidpunkt DESC
LIMIT 1;
```

> **OBS:** `gid` använder IDENTITY/sekvens – om du infogar ett specifikt `gid`-värde
> kan du behöva använda `OVERRIDING SYSTEM VALUE`.

---

## Kontrollera om en tabell har historik aktiverat

```sql
SELECT parent_table, history_table
FROM hex_metadata
WHERE parent_schema = 'sk1_kba_parkering'
  AND parent_table = 'p_platser_p';
```

Returnerar en rad om historik är aktiverat, annars tomt.
