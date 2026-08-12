# Lägga till en databasanvändare

**Gäller:** Att ge en person eller ett system tillgång till ett eller flera scheman i databasen.

---

## Bakgrund

Hex skapar automatiskt fyra roller för **varje** schema när det skapas,
oavsett säkerhetsnivå (sk0/sk1/sk2/skx):

| Roll | Typ | Rättigheter | Tilldelas till |
|------|-----|-------------|-----------------|
| `r_<schema>` | NOLOGIN grupproll | Läsrättigheter på detta specifika schema | AD-användare/AD-grupper |
| `w_<schema>` | NOLOGIN grupproll | Läs- och skrivrättigheter på detta specifika schema | AD-användare/AD-grupper |
| `gs_r_<schema>` | LOGIN-tjänstekonto | Ärver läsrättigheter från `r_<schema>` | GeoServer (autogenererat lösenord i `hex_rolluppgifter`) |
| `gs_w_<schema>` | LOGIN-tjänstekonto | Ärver skrivrättigheter från `w_<schema>` | GeoServer (autogenererat lösenord i `hex_rolluppgifter`) |

> **Det finns inga längre globala läsroller som spänner över flera scheman.**
> Tidigare fanns `r_sk0_global`/`r_sk1_global` – en delad läsroll per
> säkerhetsnivå (`schema_uttryck LIKE 'sk0_%'` respektive `'sk1_%'`) som gav
> läsåtkomst till samtliga scheman på den nivån utan separat tilldelning per
> schema. De togs bort när rollkonfigurationen förenklades till en roll per
> schema (`schema_uttryck = 'IS NOT NULL'`, commit `1c8e36d`), och rollerna
> delades sedan upp i dagens NOLOGIN/LOGIN-par för att hindra AD-användare
> från att av misstag hamna i `hex_geoserver_roller` (4-rollsstrukturen,
> commit `da9934b`). Idag skapas alltså `r_<schema>`/`w_<schema>` per
> schema utan undantag – det finns ingen roll som automatiskt täcker "alla
> sk0-scheman" eller liknande.
>
> Behöver en AD-grupp läsåtkomst till många scheman på en gång (det
> `r_sk0_global` gav gratis), är ersättningen `hex_grupprattigheter`: en
> DBA-hanterad mappningstabell där varje rad kopplar en AD-synkad grupproll
> till en enskild Hex-schemaroll (`r_<schema>`). Lägg till en rad per schema
> gruppen ska kunna läsa, och applicera mappningarna med
> `SELECT hex_tillampa_grupprattigheter();`. Se
> `src/sql/02_tables/hex_grupprattigheter.sql` och
> `src/sql/03_functions/04_utility/hex_tillampa_grupprattigheter.sql`.

`gs_r_<schema>`/`gs_w_<schema>` är systemkonton avsedda för GeoServer och
ska normalt **inte** tilldelas till personers AD-konton — tilldela
`r_<schema>`/`w_<schema>` till användare och grupper istället.

En ny användare skapas som en PostgreSQL-inloggningsroll och placeras sedan
i relevant grupproll (`r_<schema>` och/eller `w_<schema>`).

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
GRANT r_sk0_ext_sgu TO annand;
```

**Skrivrättigheter på ett specifikt schema (alla säkerhetsnivåer):**
```sql
GRANT w_sk1_kba_bygg TO annand;
```

Flera roller kan tilldelas i en sats:
```sql
GRANT r_sk0_ext_sgu, w_sk1_kba_bygg TO annand;
```

**Läsrättigheter på flera scheman på en gång** (t.ex. alla öppna sk0-scheman
för en AD-grupp): det finns ingen längre en enda roll som täcker detta
automatiskt — lägg istället till en rad per schema i
`hex_grupprattigheter` och applicera med `hex_tillampa_grupprattigheter()`,
se [Bakgrund](#bakgrund) ovan.

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
