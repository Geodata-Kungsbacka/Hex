# Instruktioner för Claude i det här repot

## Språk

Alla kodkommentarer och all dokumentation (docstrings, inline-kommentarer, markdown-filer, SQL-kommentarer) ska skrivas på **svenska**. Det gäller även den här filen.

---

## Checklista för SQL-granskning

Kör de här kontrollerna mot `src/sql/` när du granskar SQL-ändringar.

### 1. Ogiltiga `format()`-specifierare i PostgreSQL

PostgreSQL:s `format()` stöder bara `%s`, `%I`, `%L` och `%%`.
Specifierare i C-stil som `%.0f`, `%.3f`, `%d`, `%f`, `%i`, `%u` m.fl. stöds **inte** och orsakar körningsfel.

```bash
# Fånga %.Nf / %.Nd-stil
grep -rPn 'format\([^)]*%\.\d+[a-zA-Z]' src/sql/

# Fånga C-stil: %d, %f, %i, %u, %x, %e, %g osv.
grep -rPn 'format\(.*%[dfiuoxeEgGbB]' src/sql/
```

**Åtgärd:** Använd `round(val, 2)::text` för tal, `%s` för strängar, `%I` för identifierare och `%L` för literaler.

---

### 2. `EXECUTE` med strängkonkatenering (`||`)

Dynamisk SQL som byggs med `||` är en risk för SQL-injektion.

```bash
grep -rPn 'EXECUTE\s+.*\|\|' src/sql/
```

**Åtgärd:** Använd `format()` med `%I`/`%L` samt `EXECUTE ... USING` istället.

---

### 3. `SECURITY DEFINER` utan `SET search_path`

`SECURITY DEFINER`-funktioner körs som sin ägare. Utan ett låst `search_path` kan ett skadligt schema kapa anrop genom att skugga objekt.

```bash
grep -rl 'SECURITY DEFINER' src/sql/ | while read f; do
  grep -q 'SET search_path' "$f" || echo "Saknar SET search_path: $f"
done
```

> **OBS:** Det här är ett känt pågående problem i repot. Flagga berörda filer men blockera inte — åtgärder rullas ut successivt.

**Åtgärd:** Lägg till `SET search_path = public` i funktionsdefinitionen, efter `SECURITY DEFINER`.

---

### 4. Icke-ASCII-tecken i lagrade SQL-strängar (teckenkodningsfälla)

SQL-filer med icke-ASCII-tecken (svenska å/ä/ö m.fl.) i **lagrade** strängvärden — dvs. i `COMMENT ON`, `INSERT INTO` eller liknande — kan ge mojibake (`fÃ¶r` istället för `för`) om klientkodningen inte är tillförlitligt satt till UTF-8.

**Riskfyllt mönster:** `client_encoding='UTF8'` som argument till `psycopg2.connect()` ber libpq om rätt kodning på protokollnivå, men uppdaterar **inte** psycopg2:s eget Python-sidiga kodningstillstånd på ett tillförlitligt sätt.

**Rätt åtgärd:** Anropa `conn.set_client_encoding('UTF8')` explicit efter anslutning.

```bash
# Verifiera att set_client_encoding anropas efter varje connect() i Python-installatörer
grep -n "psycopg2.connect\|set_client_encoding" install_hex.py

# Hitta SQL-filer med icke-ASCII i COMMENT ON-rader
grep -rPn 'COMMENT\s+ON\s+.*[^\x00-\x7F]' src/sql/
```

**Åtgärd:** Se till att `conn.set_client_encoding('UTF8')` anropas i installatören innan SQL körs. Förlita dig **inte** enbart på `client_encoding='UTF8'` i argumenten till `psycopg2.connect()`. Anropet finns redan på plats i `install_hex.py` — kontrollen ovan är till för att fånga regressioner.

---

## Allmänna kodfakta

- All SQL riktar sig mot PostgreSQL — inga MySQL/SQLite-idiom.
- Spatiala funktioner använder PostGIS; typen `geometry` och `ST_*`-funktioner är förväntade.
- FME läser direkt från PostgreSQL-vyer — returnera inte `NULL` där FME förväntar sig ett typat värde.
