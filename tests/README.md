# Hex-tester

Testsviten består av SQL-sviter som körs mot en riktig PostgreSQL-databas med
Hex installerat, samt Python-sviter för GeoServer-lyssnaren.

---

## Förutsättningar

- PostgreSQL 16 eller senare med PostGIS, och Hex installerat i testdatabasen
  (se [docs/09_installera-uppdatera-hex.md](../docs/09_installera-uppdatera-hex.md)).
- Anslutning som superuser. Sviterna skapar och tar bort scheman, roller och
  event-triggerberoende objekt.
- För Python-sviterna: `pip install psycopg2-binary requests`.

> **Använd en engångsdatabas.** Sviterna skapar och droppar scheman som
> `sk1_kba_stress` och `sk0_ext_fmetest`, och de tar bort roller som hör till
> dem. Kör dem aldrig mot produktion.

Sätt upp en testdatabas:

```bash
createdb hex_test
```

Peka sedan `DATABASES` i `install_hex.py` på testdatabasen:

```python
DATABASES = [
    {
        "host": "localhost",
        "port": 5432,
        "dbname": "hex_test",
        "user": "postgres",
        "password": "...",
        "owner_role": "gis_admin",
    },
]
```

```bash
python3 install_hex.py
```

Installern skapar `postgis` och `pgcrypto`, och skapar ägarrollen
(`gis_admin` ovan) som `NOLOGIN` om den inte redan finns i klustret.

---

## Kör alla tester

```bash
PGDATABASE=hex_test PGUSER=postgres python3 tests/run_all_tests.py
```

Skriptet kör varje svit, tolkar resultaten och skriver ut en sammanfattning.
Avslutskoden är 0 bara om samtliga sviter passerade, vilket gör det användbart
i CI.

```
SVIT                                 PASS  XFAIL   FAIL   STATUS
reserved_words_test.sql                24      0      0   OK
stress_test.sql                        28     14      0   OK
...
TOTALT                                456     15      0
```

Flaggor:

| Flagga            | Effekt                                  |
|-------------------|-----------------------------------------|
| `--only sql`      | Kör bara SQL-sviterna                   |
| `--only python`   | Kör bara Python-sviterna                |
| `-v`, `--verbose` | Skriv ut fullständig utdata per svit    |

Anslutningen styrs med libpq:s standardvariabler (`PGDATABASE`, `PGUSER`,
`PGHOST`, `PGPORT`, `PGPASSWORD`). Utan dem används `hex_test` på `localhost`
som `postgres`.

---

## Kör en enskild svit

```bash
# SQL-svit
psql -d hex_test -f tests/test_regression.sql

# Python-svit
python3 tests/test_pg_notify_listener.py
PGHOST=localhost PGUSER=postgres PGPASSWORD=hemligt python3 tests/test_pg_notify_listener.py
```

---

## Resultatkonventioner

SQL-sviterna rapporterar på två sätt. Båda tolkas av `run_all_tests.py`:

1. **Meddelandenivå** — `NOTICE ... PASSED` (eller `GODKÄNT`) är godkänt,
   `WARNING ... FAILED` (eller `MISSLYCKAT` / `BUG`) är underkänt. Att köra
   sviten med `psql` utan att sänka `client_min_messages` är alltså en
   förutsättning för att se resultaten.
2. **Resultattabell** — sviten samlar rader i en tabell med kolumnen `status`
   och skriver ut den på slutet.

| Status  | Betydelse                                                          |
|---------|--------------------------------------------------------------------|
| `PASS`  | Testet gjorde det som förväntades                                   |
| `XFAIL` | Förväntat fel – Hex blockerade korrekt något otillåtet. Räknas som godkänt |
| `FAIL`  | Underkänt                                                           |

SRID-varningar (`har SRID 3006 – förväntar 3007`) är avsiktliga i flera sviter
och betyder inte att ett test misslyckats.

---

## Sviterna

| Fil                            | Täcker                                                        |
|--------------------------------|---------------------------------------------------------------|
| `reserved_words_test.sql`      | Kolumnnamn som är reserverade ord i QA-triggers                |
| `stress_test.sql`              | Namnvalidering, rollhantering, historik, konfigurationsgränser |
| `test_dummy_srid.sql`          | Dummy-geometrier och registrering av avvikande SRID            |
| `test_edge_cases.sql`          | CREATE/ALTER TABLE-varianter, schemanamngivning, specialfall   |
| `test_extended_ab.sql`         | sk2-scheman och vy-validering                                  |
| `test_extended_cd.sql`         | Klientsimulering (GeoServer, QGIS, FME) och strukturella fall  |
| `test_extended_efg.sql`        | Historiksynk, dataöverlevnad, QA-triggersäkerhet               |
| `test_fme.sql`                 | FME:s tvåstegsmönster för tabellskapande                       |
| `test_geometry_validation.sql` | `hex_validera_geometri` och geometrikvalitet                    |
| `test_regression.sql`          | Regressionsskydd för tidigare rättade buggar                   |
| `test_role_permissions.sql`    | Roller och rättigheter per schema                              |
| `test_underhall.sql`           | `hex_underhall()` – reparation av triggers, roller, ägarskap    |
| `test_underhall_hex.sql`       | Ägarskapsreparation och idempotens i underhållet               |
| `test_schema_namnbyte.sql`     | Blockering av `ALTER SCHEMA ... RENAME TO`                     |
| `test_grupprattigheter.sql`    | `hex_tillampa_grupprattigheter()` – AD-grupproll → Hex-roll     |
| `test_client_encoding.py`      | Att lyssnaren alltid sätter UTF-8 som klientkodning             |
| `test_installer.py`            | `install_hex.py` – ägarskapsomskrivning och installationsordning |
| `test_installer_livscykel.py`  | Uppgradering, avinstallation och förutsättningskontroller       |
| `test_pg_notify_listener.py`   | `pg_notify`-flödet mot GeoServer (GeoServer mockas)             |

Python-sviterna kräver inte att Hex är installerat. `test_installer.py`
behöver ingen databas alls – den testar installerns rena funktioner och
konsistensen i `INSTALL_ORDER` mot filerna på disk.

`test_installer_livscykel.py` skapar och droppar en egen engångsdatabas
(`hex_test_livscykel`) och rör aldrig `hex_test`. Den hoppas över automatiskt
om ingen superuser-anslutning finns. Anslutningen styrs med `PGHOST`,
`PGUSER`, `PGPASSWORD` och `PGPORT` — `PGDATABASE` används inte.

`test_pg_notify_listener.py` använder en riktig databasanslutning för
LISTEN/NOTIFY men mockar GeoServer.
