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

## 4. General notes

- All SQL targets PostgreSQL (no MySQL/SQLite idioms).
- Spatial functions use PostGIS; `geometry` type and `ST_*` functions are expected.
- FME reads directly from PostgreSQL views — avoid returning `NULL` where FME expects a typed value.
