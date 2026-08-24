# Anpassa standardkolumner

**Gäller:** Styrning av vilka kolumner som automatiskt läggs till i alla nya tabeller.

---

## Bakgrund

Tabellen `hex_standardiserade_kolumner` definierar vilka kolumner Hex lägger till
automatiskt när en tabell skapas med `CREATE TABLE`. Standarduppsättningen är:

| Kolumn | Position | Typ | Schema | Uppdateras av |
|--------|----------|-----|--------|---------------|
| `gid` | 1 (först) | `integer GENERATED ALWAYS AS IDENTITY` | Alla | – |
| `skapad_tidpunkt` | −4 (sist) | `timestamptz DEFAULT now()` | Alla | DEFAULT |
| `skapad_av` | −3 (sist) | `character varying DEFAULT session_user` | `_kba_` | DEFAULT |
| `andrad_tidpunkt` | −2 (sist) | `timestamptz DEFAULT now()` | `_kba_` | DEFAULT vid INSERT, trigger vid UPDATE |
| `andrad_av` | −1 (sist) | `character varying DEFAULT session_user` | `_kba_` | DEFAULT vid INSERT, trigger vid UPDATE |

> Filtreringen ovan följer av `schema_uttryck` på respektive rad, inte av någon
> hårdkodad regel: med standardkonfigurationen läggs `skapad_av`,
> `andrad_tidpunkt` och `andrad_av` bara till i `_kba_`-scheman (manuellt
> redigerad kommunal data), så externa och systemscheman får bara `gid` och
> `skapad_tidpunkt`. Ändra `schema_uttryck` för att flytta gränsen.

> **`session_user`, inte `current_user`.** Hex använder genomgående
> `session_user` för användarspårning — i `skapad_av`, i QA-triggerns
> `andrad_av` och i historiktabellernas `h_av`. Det är medvetet: `session_user`
> är den faktiskt autentiserade inloggningen och påverkas inte av `SET ROLE`
> eller av att koden råkar köras i en `SECURITY DEFINER`-funktion, vilket
> `current_user` gör.

> **`andrad_*` är ifyllda redan vid INSERT.** QA-triggern är
> `BEFORE UPDATE OR DELETE` och rör aldrig en ny rad, men båda kolumnerna har
> ett `default_varde` (`NOW()` respektive `session_user`). En rad som aldrig
> uppdaterats har alltså `andrad_tidpunkt = skapad_tidpunkt` och
> `andrad_av = skapad_av` — inte `NULL`. Vill du kunna skilja en orörd rad från
> en uppdaterad, töm `default_varde` på de två raderna.

Negativa positioner placeras sist i tabellen, i stigande ordning, direkt före geometrikolumnen.

---

## Kolumner i `hex_standardiserade_kolumner`

| Kolumn | Beskrivning |
|--------|-------------|
| `kolumnnamn` | Kolumnens namn |
| `ordinal_position` | Positiv = räknas från start, negativ = placeras sist |
| `datatyp` | SQL-typ, t.ex. `text`, `timestamptz`, `integer` |
| `default_varde` | DEFAULT-uttryck, t.ex. `NOW()`, `session_user` |
| `schema_uttryck` | Filtrera vilka scheman som får kolumnen (se nedan) |
| `historik_qa` | `true` = uppdateras av trigger, `false` = använder DEFAULT |
| `anvandare_kan_redigera` | `false` = värdet tvingas till `default_varde` av en INSERT-trigger, så att en klient (t.ex. FME) inte kan skriva ett eget värde. Kräver att `default_varde` är satt. Samtliga fem standardkolumner har `false`. |
| `beskrivning` | Fritext för dokumentation |

---

## Visa befintliga standardkolumner

```sql
SELECT kolumnnamn, ordinal_position, datatyp, schema_uttryck, historik_qa
FROM hex_standardiserade_kolumner
ORDER BY ordinal_position;
```

---

## Lägga till en ny standardkolumn

Exempel: en kolumn `extern_id` som bara ska läggas till i externa (`_ext_`) scheman.

```sql
INSERT INTO hex_standardiserade_kolumner (
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
UPDATE hex_standardiserade_kolumner
SET default_varde = 'now()'
WHERE kolumnnamn = 'skapad_tidpunkt';
```

---

## Ta bort en standardkolumn

```sql
DELETE FROM hex_standardiserade_kolumner
WHERE kolumnnamn = 'extern_id';
```

---

## Viktigt att tänka på

- Ändringar gäller **bara nya tabeller** som skapas efter ändringen.
  Befintliga tabeller påverkas inte.
- Kolumner med `historik_qa = true` uppdateras automatiskt av triggern
  vid varje `UPDATE` eller `DELETE`. Ett `default_varde` på en sådan kolumn
  konkurrerar inte med triggern — DEFAULT gäller vid `INSERT`, triggern vid
  `UPDATE`/`DELETE` — men det avgör vad en aldrig uppdaterad rad innehåller.
  Standarduppsättningens `andrad_tidpunkt` och `andrad_av` har båda ett
  `default_varde` av just det skälet.
- Positionen avgör kolumnordningen: lägre positiva värden hamnar
  längre till vänster, och negativa värden placeras i slutet av tabellen.
