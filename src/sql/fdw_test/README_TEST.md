# postgres_fdw test — två rena databaser

Testar sync-mekaniken utan Hex. Simulerar flödet:
`db-sync (fältdata) → postgres_fdw → lokal tabell med revision + historik`

## Körordning

| Steg | Fil | Kör mot |
|------|-----|---------|
| 1 | `01_skapa_testdatabaser.sql` | `postgres` (som superuser) |
| 2 | `02_dbsync_setup.sql` | `fdw_test_dbsync` |
| 3 | `03_hex_fdw_setup.sql` | `fdw_test_hex` |
| 4 | `04_hex_lokal_tabell.sql` | `fdw_test_hex` |
| 5 | `05_sync_funktion.sql` | `fdw_test_hex` |
| 6 | `06_testa_sync.sql` | `fdw_test_hex` (6b mot `fdw_test_dbsync`) |
| 7 | `07_stadning.sql` | `postgres` (städar upp allt) |

## Vad testas?

- **Sync 1**: Första import (5 träd INSERTs, inga historikrader)
- **Sync 2**: Simulerat fältarbete (1 UPDATE + 1 INSERT + 1 DELETE → historikrader skapas)
- **Sync 3**: Idempotens (inga ändringar → inga onödiga historikrader)
