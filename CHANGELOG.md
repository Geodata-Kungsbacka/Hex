# Ändringslogg

Alla märkbara ändringar i Hex dokumenteras i den här filen.

Formatet bygger på [Keep a Changelog](https://keepachangelog.com/sv/1.1.0/).
Versionerna motsvarar taggarna i repot (`Beta`, `v.1.0.0`). Loggen är
sammanställd i efterhand ur commit-historiken. Datum avser commit- eller
merge-datum.

---

## [Ej släppt]

Ändringar efter `v.1.0.0` på grenen `naming-convention/hex-prefix`
(PR #131–#171).

### Ändrat – brytande

- **`hex_`-prefix på samtliga databasobjekt.** Alla tabeller, typer, funktioner
  och event-triggers har bytt namn, och filerna i `src/sql/` följer samma
  namn. Några exempel:
  - `standardiserade_*` → `hex_standardiserade_*` (roller, kolumner,
    skyddsnivåer, datakategorier)
  - `tabellregler`, `kolumnkonfig`, `geom_info`, `kolumnegenskaper` →
    `hex_tabellregler` osv.
  - `system_owner()` → `hex_systemagare()`, `underhall_hex()` →
    `hex_underhall()`, `hantera_kolumntillagg()` → `hex_hantera_ny_kolumn()`,
    `notifiera_geoserver*()` → `hex_notifiera_gs*()`,
    `hantera_standardiserade_roller()` → `hex_hantera_std_roller()`,
    `tillämpa_grupprattigheter()` → `hex_tillampa_grupprattigheter()`
  - `hex_role_credentials` → `hex_rolluppgifter` med svenska kolumnnamn
    (`rollnamn`, `losenord`, `kan_logga_in`, `skapad_tidpunkt`), och
    `with_login` → `kan_logga_in` i `hex_standardiserade_roller`.
- **Versionskrav: PostgreSQL 16 eller senare.** Installern avbryter mot äldre
  servrar. Testsviten körs mot både 16 och 17.
- Ägarskapet i SQL-filerna sätts via `hex_systemagare()` i stället för
  hårdkodade rollnamn. Installerns omskrivning av `OWNER TO`
  (`process_sql()` m.fl.) är borttagen; filerna körs som de står, vilket gör
  manuell installation likvärdig med installerns.
- Engelska tester och kommentarer är översatta till svenska. Testfilerna i
  `tests/` har genomgående `test_`-prefix.

### Tillagt

- **`PRIMARY KEY (gid)` på Hex-tabeller** via `hex_sakerstall_gid_primarnyckel()`
  (eller `UNIQUE (gid)` om tabellen redan har en annan PK). Utan unikt index
  gav QGIS inget standardvärde för `gid`, och dubbletter kunde skrivas tyst.
  `hex_underhall()` migrerar befintliga tabeller. `hex_reparera_gid_dubbletter()`
  rapporterar och numrerar om dubbletter (torrkörning som standard).
- **Skydd av auditkolumner vid INSERT.** Ny kolumn `anvandare_kan_redigera` i
  `hex_standardiserade_kolumner` styr vilka kolumner som alltid skrivs över.
  Triggern `hex_tvinga_anvandarvarden` sätter `skapad_av`, `skapad_tidpunkt`,
  `andrad_av` och `andrad_tidpunkt` oavsett vad klienten (FME, QGIS) skickar.
- **Skriv-workspace för WFS-T.** GeoServer-lyssnaren skapar `{schema}_w` med
  tjänstekontot `gs_w_{schema}` utöver läs-workspacet `{schema}`.
- **Ägarskapsreparation i `hex_underhall()`**: schema, tabeller, sekvenser,
  vyer och funktioner förs över till `hex_systemagare()` (identitetssekvenser
  hoppas över).
- `hex_aterskapa_qa_trigger()` – gemensam regenerering av QA-triggern för
  `ADD COLUMN` och `RENAME COLUMN`.
- `hex_kolumntyp()` – samlat uppslag av kolumntyp, som tidigare
  rekonstruerades för hand på tre ställen.
- Upptäckt och städning av föräldralösa GeoServer-workspaces.
- Installern skapar ägarrollen (NOLOGIN) om den saknas och varnar om det.
- Installationsvarningar samlas och upprepas i sammanfattningen. Förkontroll
  varnar om `PUBLIC` har `CREATE` på `public`.
- `--upgrade` bevarar drifttillstånd (`hex_metadata`, `hex_dummy_geometrier`,
  `hex_afvaktande_geometri`, `hex_avvikande_srid`) och kör underhållet igen
  efter återställningen.
- REST-anrop mot GeoServer som tar mer än 5 s loggas med varaktighet.
- Testsviter: `test_underhall.sql`, `test_schema_namnbyte.sql`,
  `test_grupprattigheter.sql`, `test_installer_livscykel.py`,
  `test_gid_primarnyckel.sql`, test för `client_encoding` och
  GeoServer-notifieringen, samt testköraren `tests/test_run_all.py`.
- `CLAUDE.md` med språkregel, namnkonvention, SQL-granskningschecklista och
  regler för `HEX-MIGRERING`-märkning.
- SessionStart-hook som sätter upp testmiljön i webbsessioner.

### Ändrat

- Ägarrollen får `WITH ADMIN OPTION` på `r_`/`w_`-rollerna så att den kan
  dela ut dem vidare utan superuser. `hex_underhall()` uppgraderar befintliga
  tilldelningar.
- `hex_hantera_std_roller` och `hex_hantera_ny_tabell` för över ägarskapet
  till `hex_systemagare()`. `hex_tilldela_rollrattigheter` använder `GRANT ALL`.
- Lyssnarens schemamönster är trådlokalt, så databaser i multi-DB-läge inte
  skriver över varandras mönster.
- Periodisk avstämning: standardintervall 3600 s → 43 200 s (12 h).
- Datastorernas anslutningspool: `min connections` 1 → 0,
  `Max connection idle time` 300 s, `max connections` 10,
  `Connection timeout` 10 s.
- Lyssnartjänstens visningsnamn är `HexGeoServerListener`, samma som
  tjänstnamnet.
- Omstruktureringen bevarar `UNLOGGED`, beräknade kolumner och
  typmodifierare.
- Ominstallation utan `--upgrade` skriver inte längre över DBA:ns
  konfiguration (`ON CONFLICT DO NOTHING`).

### Rättat

- `hex_underhall()` kraschade på ägarskapssvepet för historiktabeller med
  geometri.
- `hex_hantera_ny_kolumn` reagerade på `ALTER TABLE` som inte var
  `ADD COLUMN` (t.ex. `OWNER TO`).
- Temp-kolumner lämnades kvar när omstruktureringen misslyckades.
- QA-triggern använde `OLD.*`, som inte matchade historiktabellen efter
  `ADD COLUMN`. Explicita kolumnlistor används nu.
- `RENAME COLUMN` speglades inte i historiktabellen.
- Användarkolumner togs bort tyst om namnet krockade med en standardkolumn
  som inte gällde schemat.
- `CREATE TABLE` föll på `GENERATED ALWAYS AS (...)` med funktionsanrop och
  på arraykolumner (t.ex. `text[]`).
- `hex_tvinga_gid_fran_sekvens` släppte igenom upprepade klient-`gid` från
  och med andra raden i en flerradig INSERT.
- `hex_blockera_schema_namnbyte` blockerade Hex:s egna `ALTER SCHEMA ... OWNER
  TO` när den yttre satsen innehöll frasen `RENAME TO`.
- Fel `LOGIN`/`NOLOGIN` på roller vid uppgradering från tvårollsstrukturen.
- `--upgrade` tappade inställningar lagrade under namnen före `hex_`-prefixet,
  och kvarlämnade gamla event-triggers fällde installationen.
- ACL-regler jämfördes som strängar och skrevs om vid varje avstämning.
  De jämförs nu som mängder.
- GeoServer 3.x: lyssnaren känner igen idempotenta fall i rollhanteringen
  trots att GeoServer 3 svarar 400 i stället för 404.
- `.env`-reservläsaren strippade inte inline-kommentarer.
- Testkörarens sammanfattning räknade överhoppade tester som godkända och
  tolkade `expected failures` fel.
- `RAISE` med `%I` och tappade å/ä/ö i felmeddelanden.
- Dokumentationen rättad mot faktiskt beteende på flera punkter, bl.a.
  README:s manuella avinstallation och triggerordningen vid `CREATE SCHEMA`.

### Säkerhet

- `SECURITY DEFINER`-funktioner låser `search_path` till `public, pg_temp`
  (tidigare bara `public`), vilket stänger skuggning via temporära tabeller.

### Borttaget

- Reparations- och migreringsmekanik för övergången till `hex_`-prefixet
  (`reparera_hex.py`, `LEGACY_*` i installern, schemamigreringen i
  `hex_underhall()`), sedan samtliga produktionsdatabaser uppgraderats.
- `hex_tvinga_auditkolumner`, ersatt av `hex_tvinga_anvandarvarden`.

---

## [1.0.0] – 2026-06-18

Tagg `v.1.0.0` (PR #76–#130).

### Tillagt

- **Direkta PostgreSQL-anslutningar för GeoServer** i stället för JNDI.
  Inloggningsroller skapas med lagrade uppgifter (`hex_role_credentials`,
  kräver `pgcrypto`).
- **Fyrrollsstruktur per schema**: `r_`/`w_` (NOLOGIN, AD-behörighetsgrupper)
  och `gs_r_`/`gs_w_` (LOGIN, GeoServer-tjänstekonton).
- `hex_geoserver_roller` för autentisering i `pg_hba.conf`.
- `hex_grupprattigheter` och `tillämpa_grupprattigheter()` för att ge en
  AD-grupp åtkomst till många scheman.
- GeoServer-roller och ACL-regler skapas vid schemapublicering.
- `anonym_las` i skyddsnivåtabellen för anonym WMS/WFS-läsning per prefix.
- Avstämning mot GeoServer vid start och återanslutning, samt periodisk
  avstämning (standard 1 h) som reparerar saknade workspaces, datastores,
  namespace-URI:er och ACL-regler. Namespace-URI:ns bas är konfigurerbar.
- `blockera_schema_namnbyte` – blockerar `ALTER SCHEMA ... RENAME TO`.
- `hex_schema_regex()` – schemamönster ur konfigurationstabellerna i stället
  för hårdkodade `sk[0-2]`-mönster.
- `underhall_hex()` (tidigare `reparera_rad_triggers()`) utökat med
  behörigheter, GeoServer-notifiering och migrering av JNDI-roller.
- Installern: flera databaser i en körning, idempotent körning, läget
  `--upgrade` som bevarar konfiguration, och kontroll av `pgcrypto`.
- Sekvensrättigheter för skrivroller.
- Testsvit för rollbehörigheter.
- Dokumentation för offline-installation på servrar utan internet.

### Ändrat

- Geometrivalideringen förenklad: parametern `tolerans`, storlekskontroller
  och `ST_IsSimple` är borttagna. Kvar är `ST_IsValid`, icke-tom geometri,
  exakta dubblettpunkter och `NOT ST_HasArc`.
- Lyssnaren skriver alltid datastore-uppgifter med PUT när storen finns, och
  faller tillbaka på PUT när POST svarar "already exists".
- Daglig loggrotation för lyssnaren.

### Rättat

- `NullPointerException` när en store öppnades i GeoServers gränssnitt.
- ACL-anrop som gav 409.
- Beräknade (`GENERATED`) kolumner trunkerades av typen `name` i ett
  `CASE`-uttryck.
- Geometrins `CHECK` lades på dubbelt om den redan återställts.
- UTF-8-avkodningsfel för svenska tecken i svar från PostgreSQL;
  installern använder `conn.set_client_encoding('UTF8')`.
- Markörläcka och avstämning vid återanslutning i lyssnaren.
- Falsk orphan-varning i multi-DB-konfiguration.

### Borttaget

- JNDI-referenser och globala läsroller (`r_sk0_global`, `r_sk1_global`).
- `requirements.txt`.

---

## [Beta] – 2026-03-24

Tagg `Beta` (PR #1–#75). Första sammanhängande versionen under namnet Hex.

### Tillagt

- **Event-triggers för DDL**: `CREATE SCHEMA`, `CREATE TABLE`,
  `ALTER TABLE ... ADD COLUMN`, `RENAME TO`, `CREATE VIEW`, `DROP TABLE` och
  `DROP SCHEMA`.
- Validering av schema-, tabell- och vynamn; tabellnamn begränsas till
  54 tecken. `_h`-suffixet reserveras för historiktabeller.
- Standardkolumner (`gid`, `skapad_av`, `skapad_tidpunkt`, `andrad_av`,
  `andrad_tidpunkt` m.fl.) styrda av konfigurationstabeller.
- Historik- och QA-triggers med `_h`-tabeller. `hex_metadata` spårar
  historiktabeller via OID så att de följer med vid namnbyte.
- Geometrivalidering, GiST-index och `CHECK` på geometrityp. Beskrivande
  felmeddelanden för QGIS-användare (`forklara_geometrifel`).
- `ST_IsSimple`- och `ST_HasArc`-kontroller.
- SRID-granskning via `hex_avvikande_srid`.
- Dummy-geometri i tomma geometritabeller så att QGIS kan läsa dem.
- FME:s tvåstegsskapande av tabeller hanteras via `hex_systemanvandare` och
  `hex_afvaktande_geometri`.
- Trigger som tvingar `gid` från sekvensen.
- `reparera_rad_triggers()` för att koppla tillbaka radtriggers efter
  ominstallation.
- Tabeller för skyddsnivåer och datakategorier; `skx`-scheman hanteras som
  `sk2`.
- **GeoServer-lyssnare** (`pg_notify`) som skapar workspace och store vid
  `CREATE SCHEMA` och städar vid `DROP SCHEMA`. Stöd för flera databaser,
  återförsök med backoff, e-postnotifiering (även oautentiserat SMTP-relä)
  och Windows-tjänst.
- Installer (`install_hex.py`) med installation och avinstallation.
- Testsviter: regressions-, utökade, stress-, kantfalls-, FME-, geometri-,
  reserverade ord- och `pg_notify`-tester.
- Administratörsdokumentation i `docs/`, `LOGIC_MAP.md` med Mermaid-diagram
  och `src/geoserver/SETUP.md`.

### Ändrat

- Separata inloggningsroller `_geoserver`/`_cesium`/`_qgis` ersatta av en
  `_pub`-roll.
- Namnen på skyddsnivåer och datakategorier lagras i egna tabeller.

### Rättat

- GiST-index och geometri-`CHECK` förstördes av kolumnomstruktureringen.
- Kolumnnamn som är reserverade ord (t.ex. `left`, `right`) gav syntaxfel.
- QA-triggern avfyrades under kolumnomflyttningen.
- Kollisioner vid identifierarlängd, `PRIMARY KEY` som krockade med `gid`,
  `pg_temp`-scheman som behandlades som Hex-scheman.
- Namespace-URI sattes till bara schemanamnet.
- Ogiltiga `format()`-specifierare i `forklara_geometrifel`.
- `WITH ADMIN OPTION` borttaget vid rolltilldelning (grantor-kedjefel i
  PostgreSQL 17); `REASSIGN OWNED`/`DROP OWNED` före `DROP ROLE`.

### Säkerhet

- `SET search_path` på `SECURITY DEFINER`-funktioner.
- Validering av schemanamn i lyssnaren mot injektion via `pg_notify`.

---

## Förhistoria – Praxis (2025-05 – 2026-02)

Projektet började som **Praxis** och döptes om till Hex i februari 2026
(`install_praxis.py` → `install_hex.py`).

- 2025-05: event-triggers, typer och funktioner för tabellregler,
  kolumnegenskaper och validering. Automatiska `r_`/`w_`-roller per schema.
- 2025-06–07: filtrering av vilka tabeller som får standardkolumner.
- 2025-07–08: triggers för QA och historik.
- 2025-09: konfigurationstabell och triggers för standardiserade roller.
- 2026-01–02: `install_praxis.py`, schemanamnskontroll, GiST-index och
  geometri-`CHECK`, rollägare.

[Ej släppt]: https://github.com/Geodata-Kungsbacka/Hex/compare/v.1.0.0...naming-convention/hex-prefix
[1.0.0]: https://github.com/Geodata-Kungsbacka/Hex/compare/Beta...v.1.0.0
[Beta]: https://github.com/Geodata-Kungsbacka/Hex/releases/tag/Beta
