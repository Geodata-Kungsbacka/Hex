# Hantera rollmallar

**Gäller:** Styrning av vilka roller som automatiskt skapas när nya scheman läggs till.

---

## Bakgrund

Tabellen `standardiserade_roller` definierar vilka roller Hex ska skapa
automatiskt vid `CREATE SCHEMA`. Varje rad är en rollmall. Du kan lägga till
nya mallar, till exempel för en ny applikation som ska ha åtkomst till
vissa scheman.

---

## Kolumner i `standardiserade_roller`

| Kolumn | Beskrivning |
|--------|-------------|
| `rollnamn` | Namnmönster för rollen, t.ex. `r_{schema}`. `{schema}` ersätts med det faktiska schemanamnet. |
| `rolltyp` | `read` eller `write` – styr vilka rättigheter som tilldelas. |
| `schema_uttryck` | SQL-uttryck som avgör för vilka scheman mallen ska gälla (se exempel nedan). |
| `global_roll` | `true` = rollen är global och skapas en gång (inte per schema). `false` = skapas per schema. |
| `ta_bort_med_schema` | `true` = rollen tas bort automatiskt när schemat droppas. |
| `login_roller` | Array med suffix för inloggningsroller, t.ex. `{_geoserver,_qgis}`. Kan vara `NULL`. |
| `beskrivning` | Fritext för dokumentation. |

---

## Visa befintliga rollmallar

```sql
SELECT rollnamn, rolltyp, schema_uttryck, global_roll, login_roller, ta_bort_med_schema
FROM standardiserade_roller
ORDER BY rollnamn;
```

---

## Lägga till en rollmall för en ny applikation

Exempel: en ny applikation (`_cesium`) ska få läsrättigheter på alla `sk0`-scheman.

```sql
INSERT INTO standardiserade_roller (
    rollnamn, rolltyp, schema_uttryck,
    global_roll, ta_bort_med_schema, login_roller, beskrivning
) VALUES (
    'r_{schema}',
    'read',
    'LIKE ''sk0_%''',
    false,
    true,
    ARRAY['_cesium'],
    'Läsroll för Cesium-applikationen på sk0-scheman'
);
```

En inloggningsroll `r_<schema>_cesium` skapas nu automatiskt för alla
kommande `sk0`-scheman.

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
DELETE FROM standardiserade_roller
WHERE rollnamn = 'r_{schema}' AND login_roller = ARRAY['_cesium'];
```

---

## Viktigt att tänka på

- Ändringar i `standardiserade_roller` gäller **bara nya scheman** som skapas
  efter ändringen. Befintliga scheman påverkas inte automatiskt.
- Om du vill lägga till en roll för ett befintligt schema måste du göra det manuellt
  med `CREATE ROLE` och `GRANT`.
