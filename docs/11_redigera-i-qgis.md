# Redigera Hex-lager i QGIS

**Gäller:** Vad som händer när en användare redigerar ett Hex-lager i QGIS, och varför `gid` beter sig som den gör.

---

## Bakgrund

`gid` är Hex primärnyckel och definieras som:

```sql
gid integer NOT NULL GENERATED ALWAYS AS IDENTITY
```

`GENERATED ALWAYS` betyder att databasen – inte klienten – äger värdet.
Utöver det ersätter triggern `hex_tvinga_gid` alltid ett klientvalt `gid`
med nästa sekvensvärde vid `INSERT`.

QGIS använder `gid` som objekt-id (feature id) för lagret. Det är det värde
QGIS skickar i `WHERE gid = N` när användaren ändrar eller raderar ett objekt.

---

## Vad användaren ska förvänta sig

| Åtgärd i QGIS | Resultat |
|---------------|----------|
| Rita ett nytt objekt | Fungerar. `gid` fylls i av databasen och syns direkt i attributtabellen. |
| Ändra vilket attribut som helst **utom** `gid` | Fungerar. |
| Flytta eller ändra geometri | Fungerar. |
| Radera ett objekt | Fungerar. |
| Ändra `gid` | **Går inte.** Se nedan. |

Så länge `gid` lämnas ifred fungerar redigering precis som i vilket
PostGIS-lager som helst.

---

## Varför `gid` inte går att ändra

PostgreSQL accepterar **bara** nyckelordet `DEFAULT` som nytt värde för en
`GENERATED ALWAYS`-kolumn i en `UPDATE`. Alla andra värden avvisas:

```sql
UPDATE sk1_kba_geo.vagar_l SET gid = 4    WHERE gid = 1;  -- fel
UPDATE sk1_kba_geo.vagar_l SET gid = gid  WHERE gid = 1;  -- fel, samma värde
UPDATE sk1_kba_geo.vagar_l SET gid = 1    WHERE gid = 1;  -- fel
```

```
ERROR:  column "gid" can only be updated to DEFAULT
DETAIL:  Column "gid" is an identity column defined as GENERATED ALWAYS.
```

Det finns alltså **ingen tillåten siffra** – inte "nästa lediga", inte det
värde raden redan har. Endast:

```sql
UPDATE sk1_kba_geo.vagar_l SET gid = DEFAULT WHERE gid = 1;  -- OK, ger nytt gid
```

Regeln avfyras dessutom före alla triggers, så den kan inte fångas upp eller
skrivas om på databassidan. QGIS skickar aldrig `DEFAULT` för ett värde
användaren skrivit in, utan just det inskrivna talet – därför blir det alltid
fel.

### Konsekvensen är större än den ser ut

QGIS samlar alla attributändringar för en rad i **en** `UPDATE`-sats:

```sql
UPDATE sk1_kba_geo.vagar_l SET namn = 'Storgatan', gid = 9 WHERE gid = 2;
```

Faller satsen på `gid` går **hela satsen** förlorad – även ändringen av
`namn`. När `Spara lagerändringar` misslyckas rullas hela redigeringsbufferten
tillbaka, alltså även ändringar på andra objekt i samma session.

---

## Så undviker användaren problemet

### 1. Dölj `gid` i attributformuläret (rekommenderat)

Gör kolumnen oredigerbar en gång per lager, så kan ingen råka ändra den:

1. **Lageregenskaper → Attributformulär**
2. Markera fältet `gid` i listan
3. Bocka ur **Redigerbar**

Spara inställningen så att den gäller för alla:

* **Lageregenskaper → Stil → Spara stil → I databasen**, eller
* lägg lagret i det gemensamma QGIS-projektet med inställningen redan gjord.

### 2. Om felet redan uppstått

Ändringen ligger kvar i redigeringsbufferten och blockerar varje nytt
sparförsök. Gör så här:

1. **Ångra** (`Ctrl+Z`) tills `gid`-ändringen är borta – attributtabellen visar
   ursprungsvärdet igen
2. Spara på nytt

Går det inte att hitta ändringen: avsluta redigeringsläget och välj **Kasta**.
Allt osparat i sessionen försvinner, så spara hellre ofta.

### 3. Om ett `gid` verkligen behöver bytas

Det är ett administratörsingrepp, inte en QGIS-uppgift. `gid` är en
surrogatnyckel utan betydelse i sak – behovet beror oftast på att något annat
ska lösas på ett annat sätt. Måste det ändå göras:

```sql
UPDATE sk1_kba_geo.vagar_l SET gid = DEFAULT WHERE gid = 42;
```

Raden får då nästa värde ur sekvensen – inte ett värde du väljer. Externa
referenser till det gamla `gid` (GeoServer, WFS, kopplade tabeller) slutar
peka rätt.

---

## Varför `gid` inte längre är obligatoriskt att fylla i

I Hex-versioner före primärnyckeln på `gid` saknade tabellerna unikt index.
QGIS letar bara upp kolumnens `nextval()`-default när kolumnen är `NOT NULL`,
har ett unikt index och saknar egen `DEFAULT`. Utan index fick QGIS inget
defaultvärde och visade `gid` som ett **tomt obligatoriskt fält** – OK-knappen
i attributformuläret var utgråad tills användaren skrev in ett tal, som
`hex_tvinga_gid` sedan ändå kastade.

Med `PRIMARY KEY (gid)` på plats hittar QGIS sekvensen, låter bli att fråga
efter `gid`, och utelämnar kolumnen helt ur sin `INSERT`.

Kontrollera att ett lager har nyckeln:

```sql
SELECT public.sakerstall_gid_primarnyckel('sk1_kba_geo', 'vagar_l');
```

`redan finns` betyder att allt är som det ska. Se
[09_installera-uppdatera-hex.md](09_installera-uppdatera-hex.md) för hur
befintliga tabeller migreras.
