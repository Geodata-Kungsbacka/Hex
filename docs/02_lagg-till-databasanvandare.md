# Lägga till en databasanvändare

**Gäller:** Att ge en person eller ett system tillgång till ett eller flera scheman i databasen.

---

## Bakgrund

Hex skapar automatiskt roller för varje schema när det skapas:

| Roll | Rättigheter |
|------|-------------|
| `r_<schema>` | Läsrättigheter (SELECT) |
| `w_<schema>` | Läs- och skrivrättigheter (SELECT, INSERT, UPDATE, DELETE) |
| `r_sk0_global` | Läsrättigheter på alla `sk0`-scheman |
| `r_sk1_global` | Läsrättigheter på alla `sk1`-scheman |

En ny användare skapas som en PostgreSQL-inloggningsroll och placeras sedan
i relevant grupproll.

---

## Förutsättningar

- Anslutning som PostgreSQL-superanvändare eller en roll med `CREATEROLE`-rättighet (t.ex. ägarrollen `gis_admin`).
- Beslut om vilka scheman/rättigheter användaren ska ha.

---

## Steg

### 1. Skapa inloggningsrollen

```sql
CREATE ROLE anna_andersson WITH LOGIN PASSWORD 'valj_ett_starkt_losenord';
```

Byt ut `anna_andersson` och lösenordet efter behov. Använd alltid ett starkt lösenord.

### 2. Ge CONNECT-rättighet på databasen

```sql
GRANT CONNECT ON DATABASE <databasnamn> TO anna_andersson;
```

### 3. Tilldela lämplig grupproll

**Läsrättigheter på ett specifikt schema:**
```sql
GRANT r_sk1_kba_bygg TO anna_andersson;
```

**Skrivrättigheter på ett specifikt schema:**
```sql
GRANT w_sk1_kba_bygg TO anna_andersson;
```

**Läsrättigheter på alla öppna (sk0) scheman:**
```sql
GRANT r_sk0_global TO anna_andersson;
```

**Läsrättigheter på alla kommunala (sk1) scheman:**
```sql
GRANT r_sk1_global TO anna_andersson;
```

Flera roller kan tilldelas i en sats:
```sql
GRANT r_sk1_global, w_sk1_kba_bygg TO anna_andersson;
```

### 4. Verifiera

```sql
-- Kontrollera rollmedlemskap
SELECT rolname
FROM pg_roles
WHERE pg_has_role('anna_andersson', oid, 'member')
  AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;
```

---

## Ta bort en användare

```sql
-- Ta bort rollmedlemskap
REVOKE ALL ON DATABASE <databasnamn> FROM anna_andersson;

-- Ta bort inloggningsrollen
DROP ROLE anna_andersson;
```

> Om användaren äger objekt i databasen måste dessa först överlåtas eller tas bort
> innan rollen kan droppas.

---

## Tillfällig åtkomstkontroll

För att tillfälligt blockera en användares inloggning utan att ta bort rollen:

```sql
ALTER ROLE anna_andersson NOLOGIN;
-- Återaktivera:
ALTER ROLE anna_andersson LOGIN;
```
