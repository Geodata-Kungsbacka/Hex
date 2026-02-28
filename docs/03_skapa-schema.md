# Skapa ett nytt schema

**Gäller:** Att skapa ett nytt dataschema som Hex ska hantera automatiskt.

---

## Bakgrund

När ett schema skapas triggar Hex automatiskt:

1. **Namnvalidering** – ogiltiga namn blockeras direkt.
2. **Rollskapande** – läs- och skrivrättighetsroller skapas enligt konfigurationen i `standardiserade_roller`.
3. **GeoServer-publicering** – för `sk0`- och `sk1`-scheman skickas en notifiering till GeoServer-lyssnaren som skapar en workspace och JNDI-datastore.

---

## Namngivningskonvention

Schemanamn måste följa mönstret: **`sk[0-2]_(ext|kba|sys)_<beskrivning>`**

| Del | Värden | Betydelse |
|-----|--------|-----------|
| `sk0` | öppen data | Tillgänglig för alla |
| `sk1` | kommunal data | Kräver inloggning |
| `sk2` | begränsad data | Känslig, begränsad åtkomst |
| `ext` | externa källor | Data från myndigheter, leverantörer m.m. |
| `kba` | interna källor | Data som produceras internt |
| `sys` | systemdata | Systemspecifik data |

---

## Förutsättningar

- Anslutning som PostgreSQL-roll med rättighet att skapa scheman (normalt ägarrollen, t.ex. `gis_admin`).
- Beslut om säkerhetsnivå (sk0/sk1/sk2), kategori (ext/kba/sys) och ett beskrivande namn.

---

## Steg

### 1. Skapa schemat

```sql
CREATE SCHEMA sk1_kba_parkering;
```

Ytterligare exempel:
```sql
CREATE SCHEMA sk0_ext_sgu;        -- Öppen data från SGU
CREATE SCHEMA sk1_kba_byggnader;  -- Kommunal byggnadsdata
CREATE SCHEMA sk2_sys_admin;      -- Begränsad systemdata
```

### 2. Verifiera att rollerna skapades

```sql
SELECT rolname
FROM pg_roles
WHERE rolname LIKE '%_parkering%'
ORDER BY rolname;
```

Du bör se `w_sk1_kba_parkering` (skrivrollen per schema) och de globala rollerna
`r_sk1_global`, `r_sk1_global_geoserver` m.fl. (läsroller skapas globalt för sk1, inte per schema).

### 3. Ge användare åtkomst

Se [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md) för hur du
tilldelar roller till användare.

---

## Ogiltiga namn – blockeras av Hex

```sql
CREATE SCHEMA min_data;        -- FEL: Följer inte mönstret
CREATE SCHEMA sk3_ext_test;    -- FEL: sk3 finns inte
CREATE SCHEMA sk0_foo_bygg;    -- FEL: "foo" är inte ext/kba/sys
```

Felmeddelandet berättar exakt vilket mönster som krävs.

> **Tips – versaler:** PostgreSQL omvandlar automatiskt onoterade identifierare till
> gemener, så `CREATE SCHEMA SK1_kba_bygg` skapar i praktiken `sk1_kba_bygg` och godkänns.
> Använd alltid gemener för att undvika förvirring.

---

## Ta bort ett schema

```sql
DROP SCHEMA sk1_kba_parkering CASCADE;
```

Hex tar automatiskt bort alla tillhörande roller (de som är märkta med
`ta_bort_med_schema = true` i `standardiserade_roller`).

> **OBS:** `CASCADE` tar bort alla tabeller och objekt i schemat – använd med försiktighet.
> GeoServer-workspace tas **inte** bort automatiskt och måste rensas manuellt vid behov.
