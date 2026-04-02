# Skapa ett nytt schema

**Gäller:** Att skapa ett nytt dataschema som Hex ska hantera automatiskt.

---

## Bakgrund

När ett schema skapas triggar Hex automatiskt:

1. **Namnvalidering** – ogiltiga namn blockeras direkt.
2. **Rollskapande** – läs- och skrivrättighetsroller skapas enligt konfigurationen i `standardiserade_roller`.
3. **GeoServer-publicering** – för `sk0`- och `sk1`-scheman skickas en notifiering till GeoServer-lyssnaren som skapar en workspace och PostGIS-datastore.

---

## Namngivningskonvention

Schemanamn måste följa mönstret: **`<skyddsnivå>_(ext|kba|sys)_<beskrivning>`**

Giltiga skyddsnivåer och datakategorier hämtas dynamiskt ur konfigurationstabellerna
`standardiserade_skyddsnivaer` och `standardiserade_datakategorier`. Med
standardkonfigurationen gäller:

| Del | Värden | Betydelse |
|-----|--------|-----------|
| `sk0` | öppen data | Tillgänglig för alla; publiceras automatiskt till GeoServer |
| `sk1` | kommunal data | Kräver inloggning; publiceras automatiskt till GeoServer |
| `sk2` | begränsad data | Känslig, begränsad åtkomst; publiceras **inte** till GeoServer |
| `skx` | oklassificerad data | Används av GIS-administratörer för testprojekt o.d.; publiceras **inte** till GeoServer |
| `ext` | externa källor | Data från myndigheter, leverantörer m.m. |
| `kba` | interna källor | Data som produceras internt |
| `sys` | systemdata | Systemspecifik data |

---

## Förutsättningar

- Anslutning som PostgreSQL-roll med rättighet att skapa scheman (normalt ägarrollen, t.ex. `gis_admin`).
- Beslut om säkerhetsnivå (sk0/sk1/sk2/skx), kategori (ext/kba/sys) och ett beskrivande namn.

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
`r_sk1_global`, `r_sk1_global_pub` m.fl. (läsroller skapas globalt för sk1, inte per schema, baserat på `standardiserade_roller`).

### 3. Ge användare åtkomst

Se [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md) för hur du
tilldelar roller till användare.

---

## Ogiltiga namn – blockeras av Hex

```sql
CREATE SCHEMA min_data;        -- FEL: Följer inte mönstret
CREATE SCHEMA sk3_ext_test;    -- FEL: sk3 finns inte (giltiga: sk0, sk1, sk2, skx)
CREATE SCHEMA sk0_foo_bygg;    -- FEL: "foo" är inte en giltig datakategori
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
> GeoServer-workspace tas bort automatiskt, och tar med sig Store och Layers däri.

---

## Byta namn på ett schema – INTE TILLÅTET

`ALTER SCHEMA ... RENAME TO` är blockerat av Hex och ger ett felmeddelande.

**Varför?** Schemanamnet är identitetsnyckeln för ett helt ekosystem av beroenden som skapades när schemat anlades:

| Beroende | Hur det påverkas av ett namnbyte |
|---|---|
| GeoServer-workspace | Namnges identiskt med schemat. Workspace blir föräldralös; lager försvinner från WMS/WFS. |
| Databasroller `r_…` / `w_…` | Härleds från schemanamnet. Befintliga roller pekar på ett schema som inte finns; nya schemat saknar roller. |
| `hex_role_credentials` | Autentiseringsuppgifter lagras med rollnamnet som nyckel. GeoServer-lyssnaren hittar inga uppgifter för det nya schemanamnet. |
| `hex_metadata` | `parent_schema` lagras som text. Tabellerna tappar kopplingen till sina historiktabeller och triggar. |

Eftersom skyddsnivå och datakategori dessutom är kodade i själva schemanamnet (`sk0_kba_bygg` → nivå `sk0`, kategori `kba`) går det inte heller att validera att ett nytt namn är konsistent med det befintliga innehållet.

**Rätt tillvägagångssätt** om du behöver byta namn:

```sql
-- Steg 1: Ta bort det gamla schemat (Hex städar upp roller och GeoServer)
DROP SCHEMA sk1_kba_gammalt CASCADE;

-- Steg 2: Skapa schemat med det nya namnet (Hex etablerar nytt ekosystem)
CREATE SCHEMA sk1_kba_nytt;
```
