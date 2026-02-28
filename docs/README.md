# Hex – Administratörsdokumentation

Kortfattade guider för vanliga administratörsuppgifter i Hex.

| # | Uppgift | Dokument |
|---|---------|----------|
| 1 | Lägga till systemanvändare (t.ex. FME, GDAL) | [01_lagg-till-systemanvandare.md](01_lagg-till-systemanvandare.md) |
| 2 | Lägga till en databasanvändare | [02_lagg-till-databasanvandare.md](02_lagg-till-databasanvandare.md) |
| 3 | Skapa ett nytt schema | [03_skapa-schema.md](03_skapa-schema.md) |
| 4 | Hantera rollmallar | [04_hantera-rollmallar.md](04_hantera-rollmallar.md) |
| 5 | Anpassa standardkolumner | [05_anpassa-standardkolumner.md](05_anpassa-standardkolumner.md) |
| 6 | Övervaka väntande geometri (FME-flöden) | [06_overvaka-vantande-geometri.md](06_overvaka-vantande-geometri.md) |
| 7 | Granska ändringshistorik | [07_granska-andringshistorik.md](07_granska-andringshistorik.md) |
| 8 | Hantera GeoServer-lyssnaren | [08_geoserver-lyssnaren.md](08_geoserver-lyssnaren.md) |
| 9 | Installera eller uppdatera Hex | [09_installera-uppdatera-hex.md](09_installera-uppdatera-hex.md) |
| 10 | Avinstallera Hex | [10_avinstallera-hex.md](10_avinstallera-hex.md) |

## Bakgrund

Hex är ett PostgreSQL-system som automatiserar struktureringen av geodata.
All administration sker via direkta SQL-kommandon mot databasen eller via
installationsskriptet `install_hex.py`.

Det finns inget webbgränssnitt – de flesta uppgifter utförs i **pgAdmin** eller **psql**
som en användare med tillräckliga databasrättigheter (normalt ägarrollen, t.ex. `gis_admin`).
