# kba_pg

# PostgreSQL Triggerfunktioner

Detta projekt innehåller triggerfunktioner för automatisk tabellstrukturering i PostgreSQL med PostGIS.

## Funktioner

- `hantera_kolumntillagg()` - Hanterar när kolumner läggs till
- `hantera_geometri_definition()` - Analyserar geometrikolumner  
- `validera_tabell()` - Validerar tabellnamn
- `spara_tabellregler()` - Sparar tabellregler
- `aterskapa_tabellregler()` - Återskapar tabellregler

## Installation

1. Kör först alla skript i `/functions`-mappen
2. Kör sedan skripten i `/triggers`-mappen