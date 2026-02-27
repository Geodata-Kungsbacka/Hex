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

## Två typer av användare

### Personers AD-konton

Vanliga användare autentiseras via Active Directory (AD). PostgreSQL-rollen
skapas **utan lösenord** – AD hanterar inloggningen. Rollnamnet ska matcha
AD-kontots korta inloggningsnamn (UPN-prefix), t.ex. `annand` för Anna Andersson.

```sql
CREATE ROLE annand WITH LOGIN;
GRANT CONNECT ON DATABASE <databasnamn> TO annand;
```

### Systemkonton (tjänster utan AD)

Tjänster och verktyg som ansluter utan AD (t.ex. FME, GeoServer-lyssnaren)
behöver ett lösenord. Använd alltid ett starkt, unikt lösenord per tjänst.

```sql
CREATE ROLE fme WITH LOGIN PASSWORD 'valj_ett_starkt_losenord';
GRANT CONNECT ON DATABASE <databasnamn> TO fme;
```

---

## Tilldela åtkomst till schema

**Läsrättigheter på ett specifikt schema:**
```sql
GRANT r_sk1_kba_bygg TO annand;
```

**Skrivrättigheter på ett specifikt schema:**
```sql
GRANT w_sk1_kba_bygg TO annand;
```

**Läsrättigheter på alla öppna (sk0) scheman:**
```sql
GRANT r_sk0_global TO annand;
```

**Läsrättigheter på alla kommunala (sk1) scheman:**
```sql
GRANT r_sk1_global TO annand;
```

Flera roller kan tilldelas i en sats:
```sql
GRANT r_sk1_global, w_sk1_kba_bygg TO annand;
```

---

## Verifiera

```sql
-- Kontrollera rollmedlemskap för en användare
SELECT rolname
FROM pg_roles
WHERE pg_has_role('annand', oid, 'member')
  AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;
```

---

## Ta bort en användare

```sql
REVOKE ALL ON DATABASE <databasnamn> FROM annand;
DROP ROLE annand;
```

> Om användaren äger objekt i databasen måste dessa först överlåtas eller
> tas bort innan rollen kan droppas.

---

## Tillfällig åtkomstkontroll

För att tillfälligt blockera en användares inloggning utan att ta bort rollen:

```sql
ALTER ROLE annand NOLOGIN;
-- Återaktivera:
ALTER ROLE annand LOGIN;
```
