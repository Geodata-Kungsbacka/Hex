# Skapa ett nytt schema

**Gäller:** Att skapa ett nytt dataschema som Hex ska hantera automatiskt.

---

## Bakgrund

När ett schema skapas triggar Hex automatiskt tre saker:

- **Rollskapande** – läs- och skrivrättighetsroller skapas enligt konfigurationen i `hex_standardiserade_roller`.
- **GeoServer-publicering** – för skyddsnivåer med `publiceras_geoserver = true` i `hex_standardiserade_skyddsnivaer` (standardkonfiguration: `sk0` och `sk1`) skickas en notifiering till GeoServer-lyssnaren som skapar en workspace och PostGIS-datastore.
- **Namnvalidering** – ogiltiga namn blockeras, vilket river tillbaka schemat och allt ovanstående i samma transaktion.

> **Körordning:** PostgreSQL kör Hex tre `CREATE SCHEMA`-triggers i alfabetisk
> ordning efter triggernamn, inte i den ordning man logiskt skulle förvänta
> sig – rollskapande och GeoServer-notifiering körs faktiskt **före**
> namnvalideringen, inte efter. Det märks inte i praktiken: ett ogiltigt namn
> gör att hela `CREATE SCHEMA`-satsen (schema, roller och en eventuell köad
> GeoServer-notifiering) rullas tillbaka som en enhet, eftersom `pg_notify`
> inte levereras till lyssnare förrän vid `COMMIT`. Se LOGIC_MAP.md avsnitt 2
> för den exakta körordningen och varför.

---

## Namngivningskonvention

Schemanamn måste följa mönstret: **`<skyddsnivå>_<datakategori>_<beskrivning>`**

Giltiga skyddsnivåer och datakategorier hämtas dynamiskt ur konfigurationstabellerna
`hex_standardiserade_skyddsnivaer` och `hex_standardiserade_datakategorier`. Med
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
- Beslut om säkerhetsnivå, datakategori och ett beskrivande namn. Med
  standardkonfigurationen: nivå `sk0`/`sk1`/`sk2`/`skx` och kategori
  `ext`/`kba`/`sys` (se tabellen ovan). Kör frågan under
  [Ogiltiga namn](#ogiltiga-namn--blockeras-av-hex) för att se vad som
  faktiskt är registrerat i din databas.

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

Med standardkonfigurationen i `hex_standardiserade_roller` bör du se fyra
roller: `r_sk1_kba_parkering` och `w_sk1_kba_parkering`
(NOLOGIN-behörighetsgrupper för AD-användare) samt `gs_r_sk1_kba_parkering`
och `gs_w_sk1_kba_parkering` (LOGIN-tjänstekonton för GeoServer, med
lösenord i `hex_rolluppgifter`). Har du lagt till egna rollmallar ser du fler
– se [04_hantera-rollmallar.md](04_hantera-rollmallar.md). De fyra
standardmallarna skapas per schema – det finns inga delade roller som
spänner över flera scheman, se
[02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md#bakgrund).

### 3. Ge användare åtkomst

Se [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md) för hur du
tilldelar roller till användare.

---

## Ogiltiga namn – blockeras av Hex

```sql
CREATE SCHEMA min_data;        -- FEL: Följer inte mönstret
CREATE SCHEMA sk3_ext_test;    -- FEL: sk3 finns inte i hex_standardiserade_skyddsnivaer
CREATE SCHEMA sk0_foo_bygg;    -- FEL: "foo" finns inte i hex_standardiserade_datakategorier
```

Felmeddelandet berättar exakt vilket mönster som krävs.

Mönstret byggs om vid varje validering, så listan över giltiga värden är alltid
det som står i konfigurationstabellerna just nu:

```sql
SELECT prefix, beskrivning FROM hex_standardiserade_skyddsnivaer ORDER BY prefix;
SELECT prefix, beskrivning FROM hex_standardiserade_datakategorier ORDER BY prefix;
```

Behöver du en ny nivå eller kategori lägger du till en rad i respektive tabell —
ingen kodändring krävs.

> **Tips – versaler:** PostgreSQL omvandlar automatiskt onoterade identifierare till
> gemener, så `CREATE SCHEMA SK1_kba_bygg` skapar i praktiken `sk1_kba_bygg` och godkänns.
> Använd alltid gemener för att undvika förvirring.

---

## Ta bort ett schema

```sql
DROP SCHEMA sk1_kba_parkering CASCADE;
```

Hex tar automatiskt bort alla tillhörande roller (de som är märkta med
`ta_bort_med_schema = true` i `hex_standardiserade_roller`).

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
| `hex_rolluppgifter` | Autentiseringsuppgifter lagras med rollnamnet som nyckel. GeoServer-lyssnaren hittar inga uppgifter för det nya schemanamnet. |
| `hex_metadata` | `parent_schema` lagras som text. Tabellerna tappar kopplingen till sina historiktabeller och triggar. |

Eftersom skyddsnivå och datakategori dessutom är kodade i själva schemanamnet (`sk0_kba_bygg` → nivå `sk0`, kategori `kba`) går det inte heller att validera att ett nytt namn är konsistent med det befintliga innehållet.

**Rätt tillvägagångssätt** om du behöver byta namn:

```sql
-- Steg 1: Ta bort det gamla schemat (Hex städar upp roller och GeoServer)
DROP SCHEMA sk1_kba_gammalt CASCADE;

-- Steg 2: Skapa schemat med det nya namnet (Hex etablerar nytt ekosystem)
CREATE SCHEMA sk1_kba_nytt;
```
