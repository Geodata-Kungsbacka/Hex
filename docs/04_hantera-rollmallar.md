# Hantera rollmallar

**Gäller:** Styrning av vilka roller som automatiskt skapas när nya scheman läggs till.

---

## Bakgrund

Tabellen `hex_standardiserade_roller` definierar vilka roller Hex ska skapa
automatiskt vid `CREATE SCHEMA`. Varje rad är en rollmall. Du kan lägga till
nya mallar, till exempel för en ny applikation som ska ha åtkomst till
vissa scheman.

> Kolumnerna `global_roll` och `login_roller` som tidigare fanns i den här
> tabellen är borttagna. De byggde en delad roll per säkerhetsnivå
> (`r_sk0_global` m.fl.) med separata `_pub`-suffixade inloggningsvarianter.
> Modellen ersattes av en roll per schema (`kan_logga_in` styr LOGIN/NOLOGIN
> direkt på raden) och senare av dagens fyra-rollsstruktur (`arvs_fran` låter
> `gs_r_`/`gs_w_` ärva från `r_`/`w_`). Se
> [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md#bakgrund)
> för bakgrunden och vad som ersatte de globala rollerna.

---

## Kolumner i `hex_standardiserade_roller`

| Kolumn | Beskrivning |
|--------|-------------|
| `rollnamn` | Namnmönster för rollen, t.ex. `r_{schema}`. `{schema}` ersätts med det faktiska schemanamnet. |
| `rolltyp` | `read` eller `write` – styr vilka rättigheter `hex_tilldela_rollrattigheter` beviljar. |
| `schema_uttryck` | SQL-uttryck som avgör för vilka scheman mallen ska gälla (se exempel nedan). |
| `ta_bort_med_schema` | `true` = rollen tas bort automatiskt när schemat droppas. |
| `kan_logga_in` | `true` = rollen skapas med `LOGIN` och ett autogenererat lösenord (sparas i `hex_rolluppgifter`), och läggs i `hex_geoserver_roller`. `false` = `NOLOGIN`-behörighetsgrupp avsedd för AD-användare/AD-grupper. |
| `arvs_fran` | Om satt: rollen får sina rättigheter genom `GRANT <arvs_fran> TO <rollnamn>` istället för ett direkt anrop till `hex_tilldela_rollrattigheter`. Stödjer `{schema}`-substitution. Används för att låta `gs_r_{schema}`/`gs_w_{schema}` ärva från `r_{schema}`/`w_{schema}` så att behörigheterna hålls synkroniserade. |
| `beskrivning` | Fritext för dokumentation. |

**Fördefinierade rader (installeras med Hex):**

| `rollnamn` | `rolltyp` | `schema_uttryck` | `kan_logga_in` | `arvs_fran` |
|---|---|---|---|---|
| `r_{schema}` | read | `IS NOT NULL` (alla) | false | — |
| `w_{schema}` | write | `IS NOT NULL` (alla) | false | — |
| `gs_r_{schema}` | read | `IS NOT NULL` (alla) | true | `r_{schema}` |
| `gs_w_{schema}` | write | `IS NOT NULL` (alla) | true | `w_{schema}` |

---

## Visa befintliga rollmallar

```sql
SELECT rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran, ta_bort_med_schema
FROM hex_standardiserade_roller
ORDER BY gid;
```

---

## Lägga till en rollmall

Roller skapas automatiskt baserat på innehållet i `hex_standardiserade_roller`
— inga specifika applikationsnamn är hårdkodade.

> **OBS:** `rollnamn` har ett unikt index. En ny mall måste därför ha ett
> namnmönster som inte redan finns — de fyra fördefinierade (`r_{schema}`,
> `w_{schema}`, `gs_r_{schema}`, `gs_w_{schema}`) matchar dessutom redan
> *alla* scheman via `schema_uttryck = 'IS NOT NULL'`. Att försöka lägga till
> t.ex. ännu en `gs_w_{schema}`-rad för en delmängd scheman ger
> `duplicate key value violates unique constraint
> "hex_standardiserade_roller_rollnamn_key"`. Vill du ändra villkoret för en
> befintlig mall är det en `UPDATE` av dess `schema_uttryck`, inte en ny rad.

Exempel: lägg till ett dedikerat läs-tjänstekonto för ett internt verktyg som
bara ska skapas för `sk2`-scheman (som inte publiceras till GeoServer via
`hex_notifiera_gs` och därför inte nås via GeoServers datastore-konton).

```sql
INSERT INTO hex_standardiserade_roller (
    rollnamn,
    rolltyp,
    schema_uttryck,
    kan_logga_in,
    arvs_fran,
    ta_bort_med_schema
) VALUES (
    'app_r_{schema}',       -- {schema} ersätts med det faktiska schemanamnet
    'read',
    'LIKE ''sk2_%''',       -- Matchar alla sk2-scheman
    true,                   -- LOGIN-tjänstekonto med autogenererat lösenord
    'r_{schema}',           -- Ärver behörigheter från NOLOGIN-gruppen r_{schema}
    true                    -- Tas bort när schemat droppas
);
```

Ett LOGIN-tjänstekonto `app_r_<schema>` skapas nu automatiskt för alla
kommande `sk2`-scheman, med lösenord sparat i `hex_rolluppgifter` och
rättigheter ärvda från `r_<schema>`.

---

## Exempel på `schema_uttryck`

| Uttryck | Vilka scheman matchar |
|---------|----------------------|
| `IS NOT NULL` | Alla scheman |
| `LIKE 'sk0_%'` | Alla sk0-scheman |
| `LIKE '%_kba_%'` | Alla interna kommunala scheman |
| `= 'sk1_kba_bygg'` | Exakt detta schema |
| `NOT LIKE '%_sys_%'` | Alla scheman utom sys-scheman |

---

## Ta bort en rollmall

Tar bort mallen, men **inte** roller som redan skapats:

```sql
DELETE FROM hex_standardiserade_roller
WHERE rollnamn = 'app_r_{schema}';
```

---

## Viktigt att tänka på

- Ändringar i `hex_standardiserade_roller` gäller **bara nya scheman** som skapas
  efter ändringen. Befintliga scheman påverkas inte automatiskt.
- Om du vill lägga till en roll för ett befintligt schema måste du göra det manuellt
  med `CREATE ROLE` och `GRANT`.
- Vill du ge en AD-grupp åtkomst till flera befintliga scheman på en gång
  (utan att det sker automatiskt vid schemaskapande), använd
  `hex_grupprattigheter` istället för en rollmall – se
  [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md#bakgrund).
