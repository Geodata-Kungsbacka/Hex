# Anpassa standardkolumner

**Gäller:** Styrning av vilka kolumner som automatiskt läggs till i alla nya tabeller.

---

## Bakgrund

Tabellen `standardiserade_kolumner` definierar vilka kolumner Hex lägger till
automatiskt när en tabell skapas med `CREATE TABLE`. Standarduppsättningen är:

| Kolumn | Position | Typ | Schema | Uppdateras av |
|--------|----------|-----|--------|---------------|
| `gid` | 1 (först) | `integer GENERATED ALWAYS AS IDENTITY` | Alla | – |
| `skapad_tidpunkt` | −4 (sist) | `timestamptz DEFAULT now()` | Alla | DEFAULT |
| `skapad_av` | −3 (sist) | `character varying DEFAULT current_user` | `_kba_` | DEFAULT |
| `andrad_tidpunkt` | −2 (sist) | `timestamptz` | `_kba_` | Trigger |
| `andrad_av` | −1 (sist) | `character varying` | `_kba_` | Trigger |

> `skapad_av`, `andrad_tidpunkt` och `andrad_av` läggs bara till i `_kba_`-scheman
> (manuellt redigerad kommunal data). Externa och systemscheman får bara `gid` och `skapad_tidpunkt`.

Negativa positioner placeras sist i tabellen, i stigande ordning, direkt före geometrikolumnen.

---

## Kolumner i `standardiserade_kolumner`

| Kolumn | Beskrivning |
|--------|-------------|
| `kolumnnamn` | Kolumnens namn |
| `ordinal_position` | Positiv = räknas från start, negativ = placeras sist |
| `datatyp` | SQL-typ, t.ex. `text`, `timestamptz`, `integer` |
| `default_varde` | DEFAULT-uttryck, t.ex. `now()`, `current_user` |
| `schema_uttryck` | Filtrera vilka scheman som får kolumnen (se nedan) |
| `historik_qa` | `true` = uppdateras av trigger, `false` = använder DEFAULT |
| `beskrivning` | Fritext för dokumentation |

---

## Visa befintliga standardkolumner

```sql
SELECT kolumnnamn, ordinal_position, datatyp, schema_uttryck, historik_qa
FROM standardiserade_kolumner
ORDER BY ordinal_position;
```

---

## Lägga till en ny standardkolumn

Exempel: en kolumn `extern_id` som bara ska läggas till i externa (`_ext_`) scheman.

```sql
INSERT INTO standardiserade_kolumner (
    kolumnnamn, ordinal_position, datatyp,
    schema_uttryck, historik_qa, beskrivning
) VALUES (
    'extern_id',
    2,
    'text',
    'LIKE ''%_ext_%''',
    false,
    'ID från extern datakälla'
);
```

Kolumnen hamnar nu på position 2 (direkt efter `gid`) i alla tabeller
som skapas i `_ext_`-scheman.

---

## Exempel på `schema_uttryck`

| Uttryck | Vilka scheman matchar |
|---------|----------------------|
| `IS NOT NULL` | Alla scheman (standard) |
| `LIKE '%_ext_%'` | Externa datakällor |
| `LIKE '%_kba_%'` | Interna kommunala scheman |
| `= 'sk0_ext_sgu'` | Exakt detta schema |

---

## Ändra ett befintligt standardvärde

```sql
UPDATE standardiserade_kolumner
SET default_varde = 'now()'
WHERE kolumnnamn = 'skapad_tidpunkt';
```

---

## Ta bort en standardkolumn

```sql
DELETE FROM standardiserade_kolumner
WHERE kolumnnamn = 'extern_id';
```

---

## Viktigt att tänka på

- Ändringar gäller **bara nya tabeller** som skapas efter ändringen.
  Befintliga tabeller påverkas inte.
- Kolumner med `historik_qa = true` uppdateras automatiskt av triggern
  vid varje `UPDATE` eller `DELETE` – dessa bör inte ha `DEFAULT`-värden
  som skriver över triggerns arbete.
- Positionen avgör kolumnordningen: lägre positiva värden hamnar
  längre till vänster, och negativa värden placeras i slutet av tabellen.
