# Installera eller uppdatera Hex

**Gäller:** Första installation av Hex i en databas, eller uppdatering till en ny version.

---

## Förutsättningar

- Python 3 installerat på maskinen som kör installationsskriptet.
- Tillgång till databasen som en PostgreSQL-roll med `SUPERUSER` eller en roll med
  tillräckliga rättigheter för att skapa event-triggers och objekt i `public`-schemat.
  Normalt ägarrollen, t.ex. `gis_admin`.
- Källkoden från repositoryt (`install_hex.py` och `src/`).

---

## Steg 1 – Konfigurera installationsskriptet

Öppna `install_hex.py` i en texteditor och fyll i:

```python
DB_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "dbname":   "geodata",      # Databas att installera Hex i
    "user":     "gis_admin",    # Databasanvändare
    "password": "losenord_har"
}

OWNER_ROLE = "gis_admin"        # Rollen som ska äga Hex-objekt
```

> **OBS – `localhost` på Windows Server:** Om du installerar mot en lokal
> PostgreSQL-instans på Windows, byt `"localhost"` mot `"127.0.0.1"` i
> `host`-fältet. På moderna Windows-servrar kan `localhost` lösas till `::1`
> (IPv6) i stället för `127.0.0.1`, beroende på `hosts`-filens ordning. Om
> PostgreSQL lyssnar på `127.0.0.1` men Python ansluter via `::1` (eller
> vice versa) misslyckas installationen med `connection refused`. Använd
> samma literala adress i `DB_CONFIG` och i `pg_hba.conf`.

> Installationsskriptet måste köras **en gång per databas** om du har
> flera databaser som ska ha Hex.

---

## Steg 2 – Kör installationen

```bash
python install_hex.py
```

Skriptet installerar alla typer, tabeller, funktioner, triggers och event-triggers
i rätt ordning. En utskrift bekräftar varje steg.

---

## Verifiera installationen

```sql
-- Alla event triggers ska synas
SELECT evtname, evtevent, evtenabled
FROM pg_event_trigger
ORDER BY evtname;

-- Konfigurationstabellerna ska finnas
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND (tablename LIKE '%hex%'
   OR tablename LIKE 'standardiserade%')
ORDER BY tablename;
```

---

## Uppdatera Hex till en ny version

Använd flaggan `--upgrade` som sparar dina anpassade inställningar, avinstallerar,
installerar om med den nya versionen och återställer inställningarna automatiskt:

```bash
git pull                          # Hämta senaste versionen
python install_hex.py --upgrade   # Uppgradera med bevarade inställningar
```

Följande tabeller bevaras automatiskt vid `--upgrade`:
- `standardiserade_kolumner` — anpassade standardkolumner
- `standardiserade_roller` — anpassade rollmallar
- `standardiserade_datakategorier` — anpassade datakategorier
- `standardiserade_skyddsnivaer` — anpassade skyddsnivåer
- `hex_systemanvandare` — registrerade systemanvändare
- `hex_grupprattigheter` — AD-grupp-till-Hex-roll-mappningar
- `hex_role_credentials` — autogenererade lösenord för `gs_r_`/`gs_w_`-roller

> **OBS:** `--upgrade` bevarar konfigurationsdata men tar bort och återskapar
> alla Hex-funktioner, triggers och typer. Kör gärna en manuell säkerhetskopia
> av databasen innan uppgradering i produktionsmiljö.

---

## Migrering: primärnyckel på `gid`

Hex-tabeller skapade före den här versionen saknar `PRIMARY KEY (gid)`. Utan
unikt index hittar QGIS inte gid-sekvensen och kräver att användaren fyller i
`gid` manuellt vid varje nytt objekt – se
[11_redigera-i-qgis.md](11_redigera-i-qgis.md).

Installationen kör `underhall_hex()` automatiskt, som lägger på nyckeln på alla
befintliga tabeller. Inga data ändras.

> **Planera in ett servicefönster.** `ALTER TABLE ... ADD PRIMARY KEY` tar
> ACCESS EXCLUSIVE-lås och bygger index. På stora tabeller blockerar det både
> läsning och skrivning under bygget. Kostnaden tas bara en gång per tabell.

### Tabeller med dubbletter i `gid`

Äldre data kan innehålla dubbletter (samma `gid` på flera rader). Sådana
tabeller hoppas över och rapporteras i installationsloggen:

```
✓ sk1_kba_geo.vagar_l → gid_primarnyckel (dubbletter: 3)
```

Kör då manuellt, en tabell i taget:

```sql
-- 1. Se vad som skulle ändras (torrkörning – ändrar inget)
SELECT * FROM public.reparera_gid_dubbletter('sk1_kba_geo', 'vagar_l');

-- 2. Numrera om dubbletterna (ändrar data och kan inte ångras)
SELECT * FROM public.reparera_gid_dubbletter('sk1_kba_geo', 'vagar_l', true);

-- 3. Lägg på nyckeln
SELECT public.sakerstall_gid_primarnyckel('sk1_kba_geo', 'vagar_l');
```

Raden med lägst `ctid` i varje dubblettgrupp behåller sitt `gid`; övriga får
nästa sekvensvärde. Omnumreringen loggas i historiktabellen. Kontrollera först
om något externt (GeoServer-lager, WFS-anrop, kopplade tabeller) refererar till
de `gid` som byts.

Lista alla tabeller som fortfarande saknar nyckel:

```sql
SELECT * FROM public.underhall_hex()
WHERE  trigger_namn = 'gid_primarnyckel'
  AND  atgard <> 'redan finns';
```

---

## Manuell installation (alternativ)

Om du föredrar att köra SQL direkt, se installationsordningen i `README.md`
under avsnittet *Detaljerad installationsordning*. Starta alltid med
`src/sql/00_config/system_owner.sql` och ange ägarrollen där.

---

## Kontrollera systemstatus

```sql
-- Verifiera att triggers är aktiva
SELECT evtname, evtenabled
FROM pg_event_trigger
WHERE evtenabled != 'D'
ORDER BY evtname;

-- Kontrollera standardkolumner
SELECT kolumnnamn, ordinal_position
FROM standardiserade_kolumner
ORDER BY ordinal_position;
```
