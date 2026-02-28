# Lägga till en systemanvändare

**Gäller:** ETL-verktyg och automatiserade processer som skapar tabeller i två steg,
t.ex. FME, GDAL, eller egna skript.

---

## Bakgrund

Vissa verktyg skapar tabeller i två separata steg:

1. `CREATE TABLE ... (datakolumner)` – utan geometrikolumn
2. `ALTER TABLE ... ADD COLUMN geom geometry(...)` – geometrin läggs till efteråt

Hex kräver normalt att en tabell med geometrisuffix (`_p`, `_l`, `_y`, `_g`) ska ha
sin geometrikolumn redan vid `CREATE TABLE`. Utan undantag blockeras dessa verktyg.

Lösningen är att registrera verktygets databasanvändare i `hex_systemanvandare`.
Hex känner då igen sessionen och skjuter upp geometrihanteringen tills det
andra steget körs.

FME (`fme`) är förregistrerat och behöver inte läggas till manuellt.

---

## Förutsättningar

- Anslutning till databasen som PostgreSQL-roll med rättighet att skriva till `public.hex_systemanvandare` (normalt ägarrollen, t.ex. `gis_admin`).
- Verktygets **databasanvändarnamn** – det namn som verktyget loggar in med i PostgreSQL.

---

## Steg

### 1. Ta reda på verktygets databasanvändarnamn

Hex matchar mot tre identifierare i denna ordning:
- `session_user` – den inloggade PostgreSQL-rollen
- `current_user` – aktuell roll (kan skilja sig vid `SET ROLE`)
- `application_name` – angivet i anslutningssträngen

Vanligaste fallet är att matcha på `session_user`. Kontrollera vilket namn
verktyget använder:

```sql
-- Kör i en session via verktygets anslutning:
SELECT session_user, current_user, current_setting('application_name');
```

### 2. Registrera verktyget

```sql
INSERT INTO hex_systemanvandare (anvandare, beskrivning)
VALUES ('gdal', 'GDAL/OGR – skapar tabeller i två steg');
```

Byt ut `'gdal'` mot verktygets faktiska databasanvändarnamn och
uppdatera beskrivningen efter behov.

### 3. Verifiera

```sql
SELECT anvandare, beskrivning FROM hex_systemanvandare;
```

---

## Ta bort en systemanvändare

Om ett verktyg inte längre används och ska behandlas som en vanlig användare:

```sql
DELETE FROM hex_systemanvandare WHERE anvandare = 'gdal';
```

---

## Kontrollera väntande tabeller

Efter att verktyget körts kan du se om det finns tabeller som väntar på sin geometrikolumn:

```sql
SELECT schema_namn, tabell_namn, registrerad,
       now() - registrerad AS elapsed
FROM hex_afvaktande_geometri
ORDER BY registrerad;
```

En rad som ligger kvar längre än förväntat indikerar att verktyget aldrig
slutförde sitt andra steg. Se [06_overvaka-vantande-geometri.md](06_overvaka-vantande-geometri.md).
