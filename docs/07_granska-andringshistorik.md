# Granska ändringshistorik

**Gäller:** Spårning av vem som ändrat eller raderat data, och vad som ändrades.

---

## Bakgrund

För varje tabell i ett schema som har minst en kolumn med `historik_qa = true`
i `hex_standardiserade_kolumner` skapar Hex automatiskt en historiktabell med
suffixet `_h`. Historiktabellen innehåller alla kolumner från originaltabellen
plus tre extra:

| Kolumn | Beskrivning |
|--------|-------------|
| `h_typ` | `U` = uppdatering, `D` = radering |
| `h_tidpunkt` | Tidpunkt för händelsen |
| `h_av` | Databasanvändaren som utförde ändringen (`session_user` — den autentiserade inloggningen, opåverkad av `SET ROLE`) |

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
    -- Lista kolumner manuellt. Utelämna h_typ, h_tidpunkt, h_av och gid.
    namn, kapacitet, geom
)
SELECT namn, kapacitet, geom
FROM sk1_kba_parkering.p_platser_p_h
WHERE gid = 42
  AND h_typ = 'D'
ORDER BY h_tidpunkt DESC
LIMIT 1;
```

> **OBS:** Raden får ett **nytt** `gid`. Det ursprungliga går inte att återställa:
> `gid` är `GENERATED ALWAYS`, och även med `OVERRIDING SYSTEM VALUE` byter
> triggern `hex_tvinga_gid` ut klientens värde mot nästa sekvensvärde. Samma sak
> gäller kolumner med `anvandare_kan_redigera = false` (i standardkonfigurationen
> `skapad_av`, `skapad_tidpunkt`, `andrad_av` och `andrad_tidpunkt`) — de får
> värdena för den som gör återställningen. Refererar något externt till det
> gamla `gid` måste den kopplingen uppdateras.

---

## Kontrollera om en tabell har historik aktiverat

```sql
SELECT parent_table, history_table, created_by, created_at
FROM hex_metadata
WHERE parent_schema = 'sk1_kba_parkering'
  AND parent_table = 'p_platser_p';
```

Returnerar en rad om historik är aktiverat, annars tomt. `created_by` visar
vilken inloggning som skapade tabellen (`NULL` för tabeller registrerade innan
kolumnen fanns).

---

## När modertabellen ändras

Historiktabellen följer med automatiskt vid `ALTER TABLE`:

| Ändring i modertabellen | Vad som händer i `_h` |
|-------------------------|-----------------------|
| `ADD COLUMN` (även via `AddGeometryColumn()`) | Kolumnen läggs till |
| `DROP COLUMN` | Kolumnen ligger kvar med sina gamla värden; nya rader får `NULL` |
| Kolumnen läggs tillbaka med samma typ | Den befintliga kolumnen återanvänds |
| `ALTER COLUMN TYPE`, eller tillbaka med annan typ | Konverteras om inget värde ändras, annars arkiveras den gamla kolumnen som `<kolumn>_arkiv_<ÅÅÅÅMMDD>` |
| `RENAME COLUMN` | Kolumnen döps om i `_h` |
| `RENAME TO` | `_h`, sekvens, historikindex, GiST-index, primärnyckel, triggerfunktioner och QA-trigger döps om; QA-kroppen byggs om. Det gamla namnet kan återanvändas med egen historik |
| Ändring direkt i `_h` (t.ex. `DROP COLUMN`) | Saknade kolumner läggs tillbaka, triggern byggs om. Värdena i en borttagen `_h`-kolumn är borta — den läggs tillbaka tom |
| `SET SCHEMA` | Blockeras. Skapa tabellen i målschemat och flytta datan med `INSERT ... SELECT` |

Historiktabeller som redan hamnat ur synk rättas av `install_hex.py --upgrade`,
som kör underhållet. Det går också att köra för en tabell eller för alla:

```sql
SELECT public.hex_synka_historik('sk1_kba_parkering', 'p_platser_p');
SELECT * FROM public.hex_underhall()
WHERE trigger_namn IN ('afvaktande_geometri', 'historiksynk');
```

Underhållet returnerar `synkad: N ändringar` för tabeller som rättades och
`redan synkad` för övriga.

Värden som aldrig loggades kan inte återskapas. Saknade `_h` en kolumn när en
rad ändrades är den kolumnen `NULL` i den historikraden.
