# AI Code Review Checklist

This document is intended to be read by an AI assistant before reviewing SQL changes in this repo.
Run the grep commands below against `src/sql/` to identify potential issues.

---

## 1. Invalid PostgreSQL `format()` specifiers

PostgreSQL's `format()` only supports `%s`, `%I`, `%L`, and `%%`.
C-style specifiers like `%.0f`, `%.3f`, `%d`, `%f`, `%i`, `%u`, etc. are **not** supported and will cause runtime errors.

```bash
# Catch %.Nf / %.Nd style specifiers
grep -rPn 'format\([^)]*%\.\d+[a-zA-Z]' src/sql/

# Catch bare C-style specifiers: %d, %f, %i, %u, %x, %e, %g etc.
grep -rPn 'format\(.*%[dfiuoxeEgGbB]' src/sql/
```

**Fix:** Use `round(val, 2)::text` for numbers, `%s` for plain strings, `%I` for identifiers, `%L` for literals.

---

## 2. `EXECUTE` with string concatenation (`||`)

Dynamic SQL built with `||` is a SQL injection risk.

```bash
grep -rPn 'EXECUTE\s+.*\|\|' src/sql/
```

**Fix:** Use `format()` with `%I`/`%L` and `EXECUTE ... USING` instead.

---

## 3. `SECURITY DEFINER` without `SET search_path`

`SECURITY DEFINER` functions run as their owner. Without a pinned `search_path`, a malicious schema could intercept calls via object shadowing.

```bash
# List SECURITY DEFINER functions that do NOT have SET search_path
grep -rl 'SECURITY DEFINER' src/sql/ | while read f; do
  grep -q 'SET search_path' "$f" || echo "Missing SET search_path: $f"
done
```

> **Note:** This is a known ongoing issue in this repo. Flag affected files but do not block on it — fixes are being rolled out incrementally.

**Fix:** Add `SET search_path = public` to the function definition, after `SECURITY DEFINER`.

---

## 4. Non-ASCII characters in stored SQL strings (encoding pitfall)

SQL files with non-ASCII characters (Swedish å/ä/ö and similar) in **stored** string values — i.e. inside `COMMENT ON`, `INSERT INTO`, or any literal that ends up in the database — can produce mojibake (`fÃ¶r` instead of `för`) if the client encoding is not reliably set to UTF-8.

**The danger pattern:** `client_encoding='UTF8'` passed as a `psycopg2.connect()` keyword argument tells libpq to request that encoding at the PostgreSQL-protocol level, but does NOT reliably update psycopg2's own Python-side encoding state. If psycopg2's internal encoding differs from the server's expectation, UTF-8 bytes are stored as if they were Latin-1 characters, producing double-encoded garbage.

**The reliable fix:** call `conn.set_client_encoding('UTF8')` explicitly after connecting. This is the psycopg2-documented method and guarantees the Python-side encoding is set correctly regardless of psycopg2 version or environment locale.

Check that `install_hex.py` (or any other Python installer) calls `conn.set_client_encoding('UTF8')` after every `psycopg2.connect()` call:

```bash
# Verify set_client_encoding is called after every connect() in Python installers
grep -n "psycopg2.connect\|set_client_encoding" install_hex.py
```

Check for SQL files that contain non-ASCII characters inside stored string literals (`COMMENT ON`, `INSERT`, `DO $$ … $$` blocks that write strings):

```bash
# Find SQL files with non-ASCII in COMMENT ON lines
grep -rPn 'COMMENT\s+ON\s+.*[^\x00-\x7F]' src/sql/
```

**Fix:** Ensure `conn.set_client_encoding('UTF8')` is called in the installer before executing any SQL. Do NOT rely on `client_encoding='UTF8'` in `psycopg2.connect()` kwargs alone.

---

## 5. General notes

- All SQL targets PostgreSQL (no MySQL/SQLite idioms).
- Spatial functions use PostGIS; `geometry` type and `ST_*` functions are expected.
- FME reads directly from PostgreSQL views — avoid returning `NULL` where FME expects a typed value.
