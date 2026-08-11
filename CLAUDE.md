# Repo Instructions for Claude

## Language

All code comments and documentation (docstrings, inline comments, markdown files, SQL comments) should be written in **Swedish**.

---

## SQL Review Checklist

Run these checks against `src/sql/` when reviewing SQL changes.

### 1. Ogiltiga `format()`-specifiers i PostgreSQL

PostgreSQL:s `format()` stöder bara `%s`, `%I`, `%L` och `%%`.
C-stil-specifiers som `%.0f`, `%.3f`, `%d`, `%f`, `%i`, `%u` m.fl. stöds **inte** och orsakar körningsfel.

```bash
# Fånga %.Nf / %.Nd-stil
grep -rPn 'format\([^)]*%\.\d+[a-zA-Z]' src/sql/

# Fånga C-stil: %d, %f, %i, %u, %x, %e, %g osv.
grep -rPn 'format\(.*%[dfiuoxeEgGbB]' src/sql/
```

**Fix:** Använd `round(val, 2)::text` för tal, `%s` för strängar, `%I` för identifierare, `%L` för literaler.

---

### 2. `EXECUTE` med strängkonkatenering (`||`)

Dynamisk SQL byggd med `||` är en SQL-injektionsrisk.

```bash
grep -rPn 'EXECUTE\s+.*\|\|' src/sql/
```

**Fix:** Använd `format()` med `%I`/`%L` och `EXECUTE ... USING` istället.

---

### 3. `SECURITY DEFINER` utan `SET search_path`

`SECURITY DEFINER`-funktioner körs som sin ägare. Utan ett låst `search_path` kan ett skadligt schema kapa anrop via objektskuggning.

```bash
grep -rl 'SECURITY DEFINER' src/sql/ | while read f; do
  grep -q 'SET search_path' "$f" || echo "Saknar SET search_path: $f"
done
```

> **OBS:** Detta är ett känt pågående problem i repot. Flagga berörda filer men blockera inte — fixar rullas ut successivt.

**Fix:** Lägg till `SET search_path = public` i funktionsdefinitionen, efter `SECURITY DEFINER`.

---

### 4. Icke-ASCII-tecken i lagrade SQL-strängar (teckenkodningsfälla)

SQL-filer med icke-ASCII-tecken (svenska å/ä/ö m.fl.) i **lagrade** strängvärden — dvs. i `COMMENT ON`, `INSERT INTO` eller liknande — kan producera mojibake (`fÃ¶r` istället för `för`) om klientkodningen inte är tillförlitligt satt till UTF-8.

**Riskfyllt mönster:** `client_encoding='UTF8'` som `psycopg2.connect()`-argument ber libpq om rätt kodning på protokollnivå men uppdaterar **inte** psycopg2:s egna Python-sidiga kodningsstatus på ett tillförlitligt sätt.

**Rätt fix:** Anropa `conn.set_client_encoding('UTF8')` explicit efter anslutning.

```bash
# Verifiera att set_client_encoding anropas efter varje connect() i Python-installatörer
grep -n "psycopg2.connect\|set_client_encoding" install_hex.py

# Hitta SQL-filer med icke-ASCII i COMMENT ON-rader
grep -rPn 'COMMENT\s+ON\s+.*[^\x00-\x7F]' src/sql/
```

**Fix:** Se till att `conn.set_client_encoding('UTF8')` anropas i installatören innan SQL körs. Förlita dig **inte** enbart på `client_encoding='UTF8'` i `psycopg2.connect()`-argumenten.

---

## Allmänna kodfakta

- All SQL riktar sig mot PostgreSQL — inga MySQL/SQLite-idiom.
- Spatiala funktioner använder PostGIS; `geometry`-typen och `ST_*`-funktioner är förväntade.
- FME läser direkt från PostgreSQL-vyer — returnera inte `NULL` där FME förväntar sig ett typat värde.
