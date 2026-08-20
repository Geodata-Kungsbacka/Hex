#!/usr/bin/env python3
"""
Test: install_hex.py – installationens livscykel mot en riktig databas.

Täcker de vägar som varken SQL-sviterna eller test_installer.py når:
uppgradering (snapshot/restore av inställningar), avinstallation och
kontrollera_forutsattningar().

Sviten skapar och droppar en egen engångsdatabas (hex_test_livscykel) och
rör aldrig den vanliga testdatabasen. Kan den inte ansluta som superuser
hoppas hela sviten över i stället för att misslyckas.

Anslutning styrs med libpq:s standardvariabler (PGHOST, PGUSER, PGPASSWORD,
PGPORT). PGDATABASE används INTE – sviten har alltid sin egen databas.

Kör med:
    PGHOST=localhost PGUSER=postgres PGPASSWORD=... python3 tests/test_installer_livscykel.py
"""

import os
import select
import sys
import time
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

try:
    import psycopg2
    from psycopg2 import sql as pgsql
except ImportError:  # pragma: no cover
    psycopg2 = None

import install_hex  # noqa: E402

TESTDB = "hex_test_livscykel"
AGARROLL = "hex_livscykel_agare"


def _admin_params():
    """Anslutningsparametrar mot underhållsdatabasen postgres."""
    return {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": int(os.environ.get("PGPORT", 5432)),
        "user": os.environ.get("PGUSER", "postgres"),
        "dbname": "postgres",
        **({"password": os.environ["PGPASSWORD"]} if "PGPASSWORD" in os.environ else {}),
    }


def _db_config():
    """Installerns db-dict för engångsdatabasen."""
    cfg = _admin_params()
    cfg["dbname"] = TESTDB
    cfg["owner_role"] = AGARROLL
    return cfg


def _kan_ansluta():
    """True om en superuser-anslutning går att upprätta."""
    if psycopg2 is None:
        return False
    try:
        conn = psycopg2.connect(**_admin_params())
    except Exception:
        return False
    try:
        cur = conn.cursor()
        cur.execute("SELECT current_setting('is_superuser')")
        return cur.fetchone()[0] == "on"
    finally:
        conn.close()


KAN_KORA = _kan_ansluta()


def _admin_exec(*satser):
    """Kör satser i autocommit mot postgres-databasen."""
    conn = psycopg2.connect(**_admin_params())
    conn.autocommit = True
    try:
        cur = conn.cursor()
        for sats in satser:
            cur.execute(sats)
    finally:
        conn.close()


def _skapa_tom_databas():
    _ta_bort_databas()
    _admin_exec(f'CREATE DATABASE "{TESTDB}"')


def _ta_bort_databas():
    _admin_exec(
        f'DROP DATABASE IF EXISTS "{TESTDB}" WITH (FORCE)',
    )


def _koppla():
    """Anslutning mot engångsdatabasen, med UTF-8 satt som i installern."""
    params = {k: v for k, v in _db_config().items() if k != "owner_role"}
    conn = psycopg2.connect(**params)
    conn.set_client_encoding("UTF8")
    return conn


def _fraga(sql, params=None):
    conn = _koppla()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        return cur.fetchall()
    finally:
        conn.close()


def tearDownModule():
    """
    Städa bort ägarrollen installern skapade.

    Roller är gemensamma för hela klustret och försvinner inte med
    databasen. Körs sist, när alla klassers databaser är borta och rollen
    därför inte äger något.
    """
    if not KAN_KORA:
        return
    try:
        _ta_bort_databas()
        _admin_exec(f'DROP ROLE IF EXISTS "{AGARROLL}"')
    except Exception as e:  # pragma: no cover
        print(f"VARNING: kunde inte städa bort {AGARROLL}: {e}", file=sys.stderr)


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgradering(unittest.TestCase):
    """
    upgrade() sparar inställningar, avinstallerar, installerar om och
    återställer. Det som ska överleva är DBA:ns egna ändringar och tillägg.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        # DBA-anpassningar av olika slag, ett per bevarandemekanism:
        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()

        # 1. Ändrat värde på en systemdefinierad rad (PRESERVE_CONFIG: UPDATE)
        cur.execute(
            "UPDATE public.hex_standardiserade_kolumner"
            " SET default_varde = 'CURRENT_TIMESTAMP'"
            " WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        # 2. Egen tillagd rad som inte finns i standarduppsättningen
        #    (PRESERVE_CONFIG: INSERT tillbaka)
        cur.execute(
            "INSERT INTO public.hex_standardiserade_skyddsnivaer"
            " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
            " VALUES ('sk9', 'Egen skyddsnivå för test', false, false)"
        )
        # 3. Rent användarhanterad tabell (PRESERVE_USER_DATA)
        cur.execute(
            "INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)"
            " VALUES ('etl_verktyg', 'Tillagd av DBA')"
        )
        cur.execute(
            "INSERT INTO public.hex_grupprattigheter (ad_grupproll, hex_roll, beskrivning)"
            " VALUES ('ad_livscykel', 'r_sk0_ext_livscykel', 'Tillagd av DBA')"
        )
        conn.close()

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_andrat_standardvarde_bevaras(self):
        """En ändrad systemrad ska behålla DBA:ns värde efter uppgradering."""
        rader = _fraga(
            "SELECT default_varde FROM public.hex_standardiserade_kolumner"
            " WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        self.assertEqual(rader, [("CURRENT_TIMESTAMP",)])

    def test_egen_tillagd_rad_bevaras(self):
        """En rad DBA lagt till ska finnas kvar efter uppgradering."""
        rader = _fraga(
            "SELECT prefix FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE prefix = 'sk9'"
        )
        self.assertEqual(rader, [("sk9",)])

    def test_systemanvandare_bevaras(self):
        """PRESERVE_USER_DATA: användarhanterade rader ska återställas."""
        rader = _fraga(
            "SELECT anvandare FROM public.hex_systemanvandare ORDER BY anvandare"
        )
        anvandare = [r[0] for r in rader]
        self.assertIn("etl_verktyg", anvandare)
        self.assertIn("fme", anvandare, "standardraden för FME ska finnas kvar")

    def test_grupprattigheter_bevaras(self):
        rader = _fraga(
            "SELECT ad_grupproll, hex_roll FROM public.hex_grupprattigheter"
        )
        self.assertIn(("ad_livscykel", "r_sk0_ext_livscykel"), rader)

    def test_inga_dubbletter_efter_uppgradering(self):
        """
        Återställningen får inte lägga tillbaka rader som redan finns.

        Uppgraderingen kör UPDATE följt av INSERT vid rowcount 0; en
        felaktig nyckeljämförelse skulle ge dubbletter.
        """
        for tabell, nyckel in (
            ("hex_standardiserade_kolumner", "kolumnnamn"),
            ("hex_standardiserade_skyddsnivaer", "prefix"),
            ("hex_standardiserade_datakategorier", "prefix"),
            ("hex_standardiserade_roller", "rollnamn"),
            ("hex_systemanvandare", "anvandare"),
        ):
            with self.subTest(tabell=tabell):
                rader = _fraga(
                    f"SELECT {nyckel}, count(*) FROM public.{tabell}"
                    f" GROUP BY {nyckel} HAVING count(*) > 1"
                )
                self.assertEqual(rader, [], f"dubbletter i {tabell}")

    def test_objekten_finns_efter_uppgradering(self):
        """Uppgraderingen ska lämna en fullt installerad databas."""
        (antal_trig,) = _fraga(
            "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"
        )[0]
        self.assertEqual(antal_trig, 10)

        (antal_fn,) = _fraga(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
            " WHERE n.nspname = 'public' AND p.proname LIKE 'hex\\_%'"
        )[0]
        self.assertGreater(antal_fn, 25)

    def test_agarskap_foljer_owner_role(self):
        """
        Uppgraderingen ska inte tappa ägarskapet.

        hex_tillampa_grupprattigheter är SECURITY DEFINER och måste ägas av
        owner_role för att ha rätt – och bara rätt – rättigheter.
        """
        rader = _fraga(
            "SELECT pg_get_userbyid(p.proowner)"
            " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
            " WHERE n.nspname = 'public' AND p.proname = 'hex_tillampa_grupprattigheter'"
        )
        self.assertEqual(rader, [(AGARROLL,)])


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingFranArvdaNamn(unittest.TestCase):
    """
    REGRESSION: uppgradering från en installation gjord före hex_-prefixet.

    snapshot_settings() letade bara efter de hex_-prefixade tabellnamnen. I en
    databas som ännu bar de gamla namnen hittade den ingenting, medan
    LEGACY_UNINSTALL_SQL droppade de gamla tabellerna strax därpå. Uppgraderingen
    sparade alltså noll rader, installerade om standardvärdena och hade inget att
    lägga tillbaka – DBA:ns egna inställningar (t.ex. publiceras_geoserver = true
    för skx) försvann tyst.

    Sviten installerar den nuvarande versionen och döper sedan tillbaka tabeller
    och kolumner till namnen de hade före bytet. Det ger samma utgångsläge som en
    databas som aldrig hunnit uppgraderas, utan att gammal kod behöver checkas ut.
    """

    # Namnen som gällde före bytet. Kolumnbytena speglar
    # install_hex.LEGACY_TABLE_NAMES.
    ARVDA_NAMN_SQL = """
    ALTER TABLE public.hex_standardiserade_skyddsnivaer
        RENAME TO standardiserade_skyddsnivaer;

    ALTER TABLE public.hex_standardiserade_datakategorier
        RENAME TO standardiserade_datakategorier;
    ALTER TABLE public.standardiserade_datakategorier
        RENAME COLUMN hex_validera_geometri TO validera_geometri;

    ALTER TABLE public.hex_standardiserade_kolumner
        RENAME TO standardiserade_kolumner;
    -- Kolumnen tillkom efter namnbytet och saknas i en ärvd databas.
    ALTER TABLE public.standardiserade_kolumner
        DROP COLUMN anvandare_kan_redigera;

    ALTER TABLE public.hex_standardiserade_roller
        RENAME TO standardiserade_roller;
    ALTER TABLE public.standardiserade_roller
        RENAME COLUMN kan_logga_in TO with_login;

    ALTER TABLE public.hex_rolluppgifter RENAME TO hex_role_credentials;
    ALTER TABLE public.hex_role_credentials RENAME COLUMN rollnamn TO rolname;
    ALTER TABLE public.hex_role_credentials RENAME COLUMN losenord TO password;
    ALTER TABLE public.hex_role_credentials RENAME COLUMN kan_logga_in TO rolcanlogin;
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()

        # DBA-anpassningar, samma slag som i TestUppgradering men i en databas
        # som strax får sina gamla tabellnamn tillbaka.
        cur.execute(
            "UPDATE public.hex_standardiserade_skyddsnivaer"
            " SET publiceras_geoserver = true WHERE prefix = 'skx'"
        )
        cur.execute(
            "INSERT INTO public.hex_standardiserade_skyddsnivaer"
            " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
            " VALUES ('sk7', 'Egen skyddsnivå för test', true, false)"
        )
        cur.execute(
            "UPDATE public.hex_standardiserade_datakategorier"
            " SET hex_validera_geometri = true WHERE prefix = 'ext'"
        )
        cur.execute(
            "UPDATE public.hex_standardiserade_kolumner"
            " SET default_varde = 'CURRENT_TIMESTAMP' WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        cur.execute(
            "UPDATE public.hex_standardiserade_roller"
            " SET beskrivning = 'DBA-anpassad' WHERE rollnamn = 'w_{schema}'"
        )
        # Så såg det ut före 4-rollsrefaktorn: behörighetsgrupperna hade LOGIN.
        cur.execute(
            "UPDATE public.hex_standardiserade_roller"
            " SET kan_logga_in = true WHERE rollnamn IN ('r_{schema}', 'w_{schema}')"
        )
        cur.execute(
            "INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)"
            " VALUES ('gs_r_sk0_ext_arvd', 'hemligt', true)"
        )
        cur.execute(
            "INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)"
            " VALUES ('etl_arvd', 'Tillagd av DBA')"
        )

        # Tillbaka till de gamla namnen, och uppgradera därifrån.
        cur.execute(cls.ARVDA_NAMN_SQL)
        conn.close()

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_tabellerna_bar_de_nya_namnen(self):
        """Uppgraderingen ska lämna databasen med enbart hex_-prefixade namn."""
        kvar = _fraga(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
            " AND tablename IN ('standardiserade_skyddsnivaer',"
            " 'standardiserade_datakategorier', 'standardiserade_kolumner',"
            " 'standardiserade_roller', 'hex_role_credentials') ORDER BY 1"
        )
        self.assertEqual([r[0] for r in kvar], [])

    def test_andrad_systemrad_bevaras(self):
        """Det rapporterade felet: skx skulle publiceras och blev återställd."""
        rader = _fraga(
            "SELECT publiceras_geoserver FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE prefix = 'skx'"
        )
        self.assertEqual(rader, [(True,)])

    def test_egen_tillagd_rad_bevaras(self):
        rader = _fraga(
            "SELECT beskrivning, publiceras_geoserver"
            " FROM public.hex_standardiserade_skyddsnivaer WHERE prefix = 'sk7'"
        )
        self.assertEqual(rader, [("Egen skyddsnivå för test", True)])

    def test_omdopt_kolumn_bevaras(self):
        """validera_geometri hette så före bytet och ska landa i hex_validera_geometri."""
        rader = _fraga(
            "SELECT hex_validera_geometri FROM public.hex_standardiserade_datakategorier"
            " WHERE prefix = 'ext'"
        )
        self.assertEqual(rader, [(True,)])

    def test_kolumnstandard_bevaras(self):
        """Tabellen saknade anvandare_kan_redigera – övriga kolumner ska ändå med."""
        rader = _fraga(
            "SELECT default_varde FROM public.hex_standardiserade_kolumner"
            " WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        self.assertEqual(rader, [("CURRENT_TIMESTAMP",)])

    def test_rollbeskrivning_bevaras(self):
        rader = _fraga(
            "SELECT beskrivning FROM public.hex_standardiserade_roller"
            " WHERE rollnamn = 'w_{schema}'"
        )
        self.assertEqual(rader, [("DBA-anpassad",)])

    def test_login_flaggan_aterstalls_inte(self):
        """
        SÄKERHET: kan_logga_in får inte skrivas tillbaka från snapshoten.

        En databas från tiden före 4-rollsrefaktorn har r_/w_ med with_login =
        true. Skrevs det värdet tillbaka efter installationen skulle rollerna
        skapas med LOGIN och hamna i hex_geoserver_roller — pg_hba-hålet som
        95ead68 stängde. Kolumnen är listad under hex_agda i PRESERVE_CONFIG.
        """
        rader = _fraga(
            "SELECT rollnamn, kan_logga_in FROM public.hex_standardiserade_roller"
            " WHERE rollnamn IN ('r_{schema}', 'w_{schema}', 'gs_r_{schema}')"
            " ORDER BY 1"
        )
        self.assertEqual(
            rader,
            [("gs_r_{schema}", True), ("r_{schema}", False), ("w_{schema}", False)],
        )

    def test_rolluppgifter_bevaras(self):
        """hex_role_credentials(rolname, password, rolcanlogin) -> hex_rolluppgifter."""
        rader = _fraga(
            "SELECT losenord, kan_logga_in FROM public.hex_rolluppgifter"
            " WHERE rollnamn = 'gs_r_sk0_ext_arvd'"
        )
        self.assertEqual(rader, [("hemligt", True)])

    def test_anvandarhanterad_tabell_bevaras(self):
        """hex_systemanvandare bytte aldrig namn och ska bevaras som förr."""
        rader = _fraga(
            "SELECT anvandare FROM public.hex_systemanvandare WHERE anvandare = 'etl_arvd'"
        )
        self.assertEqual(rader, [("etl_arvd",)])

    def test_inga_dubbletter(self):
        for tabell, nyckel in (
            ("hex_standardiserade_skyddsnivaer", "prefix"),
            ("hex_standardiserade_datakategorier", "prefix"),
            ("hex_standardiserade_kolumner", "kolumnnamn"),
            ("hex_standardiserade_roller", "rollnamn"),
            ("hex_rolluppgifter", "rollnamn"),
        ):
            with self.subTest(tabell=tabell):
                rader = _fraga(
                    f"SELECT {nyckel}, count(*) FROM public.{tabell}"
                    f" GROUP BY {nyckel} HAVING count(*) > 1"
                )
                self.assertEqual(rader, [], f"dubbletter i {tabell}")


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingBevararDrifttillstand(unittest.TestCase):
    """
    REGRESSION: PRESERVE_STATE – drifttillståndet överlevde inte uppgraderingen.

    hex_metadata, hex_dummy_geometrier, hex_afvaktande_geometri och
    hex_avvikande_srid droppas av UNINSTALL_SQL och skapades tomma igen. Till
    skillnad från triggers och funktioner går innehållet inte att härleda ur
    databasen, och två saker slutade fungera efteråt:

      * hex_underhall() bygger hex_ta_bort_dummy-triggern ur hex_dummy_geometrier.
        Tom tabell -> ingen trigger -> dummy-raden blev kvar när första riktiga
        raden infogades, och läckte ut i vyerna FME läser.
      * hex_metadata är mappningen OID -> historiktabell. Tom tabell -> historiken
        följde inte med vid ALTER TABLE ... RENAME TO, utan blev en föräldralös
        tabell under det gamla namnet.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("CREATE SCHEMA sk0_kba_drift")
        cur.execute(
            "CREATE TABLE sk0_kba_drift.hus_p"
            " (namn text, geom geometry(Point, 3007))"
        )
        # Tabell med avvikande koordinatsystem – granskningsraden ska överleva.
        cur.execute(
            "CREATE TABLE sk0_kba_drift.fel_srid_p"
            " (namn text, geom geometry(Point, 3006))"
        )
        conn.close()

        cls.fore = {
            tabell: _fraga(f"SELECT count(*) FROM public.{tabell}")[0][0]
            for tabell in (
                "hex_metadata",
                "hex_dummy_geometrier",
                "hex_avvikande_srid",
            )
        }

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

        # Läs av tillståndet direkt efter uppgraderingen. De två funktionsproven
        # nedan ändrar tabellerna (INSERT tar bort dummy-raden, RENAME skriver om
        # hex_metadata) och kör före de läsande i unittests bokstavsordning.
        cls.efter = {
            tabell: _fraga(f"SELECT count(*) FROM public.{tabell}")[0][0]
            for tabell in cls.fore
        }
        cls.metadata_hus_p = _fraga(
            "SELECT parent_schema, parent_table, history_table FROM public.hex_metadata"
            " WHERE parent_table = 'hus_p'"
        )

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_utgangslaget_hade_tillstand(self):
        """Provet är meningslöst om tabellerna var tomma redan före."""
        for tabell, antal in self.fore.items():
            with self.subTest(tabell=tabell):
                self.assertGreater(antal, 0, f"{tabell} var tom redan före uppgraderingen")

    def test_tillstandet_finns_kvar(self):
        for tabell, antal in self.fore.items():
            with self.subTest(tabell=tabell):
                self.assertEqual(
                    self.efter[tabell], antal,
                    f"{tabell} tappade rader vid uppgradering",
                )

    def test_metadata_pekar_pa_ratt_tabell(self):
        self.assertEqual(
            self.metadata_hus_p, [("sk0_kba_drift", "hus_p", "hus_p_h")]
        )

    def test_dummy_raden_tas_bort_vid_forsta_riktiga_insert(self):
        """hex_ta_bort_dummy måste vara återkopplad efter uppgraderingen."""
        conn = _koppla()
        conn.autocommit = True
        try:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO sk0_kba_drift.hus_p (namn, geom)"
                " VALUES ('riktig', ST_SetSRID(ST_MakePoint(1, 1), 3007))"
            )
            cur.execute("SELECT count(*) FROM sk0_kba_drift.hus_p")
            self.assertEqual(
                cur.fetchone()[0], 1, "dummy-raden blev kvar bredvid den riktiga"
            )
        finally:
            conn.close()

    def test_historiken_foljer_med_vid_namnbyte(self):
        """Utan hex_metadata blir hus_p_h föräldralös när tabellen döps om."""
        conn = _koppla()
        conn.autocommit = True
        try:
            conn.cursor().execute(
                "ALTER TABLE sk0_kba_drift.hus_p RENAME TO byggnad_p"
            )
        finally:
            conn.close()
        tabeller = [
            r[0]
            for r in _fraga(
                "SELECT tablename FROM pg_tables WHERE schemaname = 'sk0_kba_drift'"
                " ORDER BY 1"
            )
        ]
        self.assertIn("byggnad_p_h", tabeller)
        self.assertNotIn("hus_p_h", tabeller)


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestOminstallationBevararKonfig(unittest.TestCase):
    """
    REGRESSION: en vanlig ominstallation (utan --upgrade) skrev över DBA:ns
    inställningar. Ingen snapshot finns på den vägen, så värdena var borta.

    Tre satser gjorde det: ON CONFLICT DO UPDATE i hex_standardiserade_kolumner
    och hex_standardiserade_roller, samt en villkorslös UPDATE av sk0.anonym_las.
    De två förstnämnda var engångsmigreringar som aldrig slutade avfyras.

    Undantaget är kan_logga_in och arvs_fran på de fyra standardrollerna. Dem
    äger Hex: r_/w_ måste vara NOLOGIN, annars hamnar de i hex_geoserver_roller.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.hex_standardiserade_kolumner"
            " SET default_varde = 'CURRENT_TIMESTAMP', historik_qa = true,"
            "     anvandare_kan_redigera = true"
            " WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        cur.execute(
            "UPDATE public.hex_standardiserade_skyddsnivaer"
            " SET anonym_las = false WHERE prefix = 'sk0'"
        )
        cur.execute(
            "UPDATE public.hex_standardiserade_roller"
            " SET beskrivning = 'DBA-anpassad', rolltyp = 'write'"
            " WHERE rollnamn = 'gs_r_{schema}'"
        )
        # Det Hex äger: r_ ska tvingas tillbaka till NOLOGIN.
        cur.execute(
            "UPDATE public.hex_standardiserade_roller"
            " SET kan_logga_in = true WHERE rollnamn = 'r_{schema}'"
        )
        conn.close()

        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_andrat_standardvarde_bevaras(self):
        """docs/05 beskriver UPDATE av default_varde som ett stött arbetssätt."""
        rader = _fraga(
            "SELECT default_varde, historik_qa, anvandare_kan_redigera"
            " FROM public.hex_standardiserade_kolumner"
            " WHERE kolumnnamn = 'skapad_tidpunkt'"
        )
        self.assertEqual(rader, [("CURRENT_TIMESTAMP", True, True)])

    def test_avstangd_anonym_lasning_bevaras(self):
        """Engångsmigreringen av sk0 får inte avfyras vid varje installation."""
        rader = _fraga(
            "SELECT anonym_las FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE prefix = 'sk0'"
        )
        self.assertEqual(rader, [(False,)])

    def test_beskrivande_rollkolumner_bevaras(self):
        rader = _fraga(
            "SELECT beskrivning, rolltyp FROM public.hex_standardiserade_roller"
            " WHERE rollnamn = 'gs_r_{schema}'"
        )
        self.assertEqual(rader, [("DBA-anpassad", "write")])

    def test_login_flaggan_tvingas_tillbaka(self):
        """kan_logga_in är Hex:s – r_/w_ måste vara NOLOGIN (95ead68)."""
        rader = _fraga(
            "SELECT rollnamn, kan_logga_in FROM public.hex_standardiserade_roller"
            " WHERE rollnamn IN ('r_{schema}', 'w_{schema}') ORDER BY 1"
        )
        self.assertEqual(rader, [("r_{schema}", False), ("w_{schema}", False)])


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingNotifierarGeoServer(unittest.TestCase):
    """
    REGRESSION: GeoServer-notifieringen såg inte kundens publiceras_geoserver.

    Steg 10 i hex_underhall() skickar pg_notify('geoserver_schema', <schema>)
    för varje schema vars prefix har publiceras_geoserver = true. install()
    avslutar med att köra hex_underhall() — och i upgrade() sker det INNAN
    restore_settings() lagt tillbaka kundens konfiguration. Vid det laget står
    hex_standardiserade_skyddsnivaer på INSERT-defaultarna (sk0/sk1 true,
    sk2/skx false), så ett skx-schema som ska publiceras hoppades över.

    Samma uppgradering roterar dessutom gs_r_/gs_w_-lösenorden. Ett schema som
    aldrig notifierades fick alltså nya lösenord i databasen medan GeoServers
    datastore blev kvar med de gamla — trasigt tills någon körde
    hex_underhall() manuellt eller startade om lyssnaren.

    upgrade() kör numera om underhållet efter återställningen.
    """

    SCHEMAN = ("sk0_kba_gs", "skx_kba_gs", "sk9_kba_gs")

    @staticmethod
    def _samla_notiser(conn, vanta=2.0):
        """Läser notiser tills anslutningen varit tyst i `vanta` sekunder.

        Ett ensamt poll() läser bara det som råkar ligga i bufferten just då och
        missar notiser som skickats från en senare transaktion.
        """
        ut = []
        slut = time.time() + vanta
        while time.time() < slut:
            if select.select([conn], [], [], 0.2)[0]:
                conn.poll()
                while conn.notifies:
                    ut.append(conn.notifies.pop(0).payload)
                slut = time.time() + vanta
        return ut

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        # Kundens konfiguration: skx publiceras (avviker från default), och ett
        # helt eget prefix läggs till.
        cur.execute(
            "UPDATE public.hex_standardiserade_skyddsnivaer"
            " SET publiceras_geoserver = true WHERE prefix = 'skx'"
        )
        cur.execute(
            "INSERT INTO public.hex_standardiserade_skyddsnivaer"
            " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
            " VALUES ('sk9', 'DBA-tillagd nivå', true, false)"
        )
        for schema in cls.SCHEMAN:
            cur.execute(f"CREATE SCHEMA {schema}")
        conn.close()

        # Lyssna innan uppgraderingen startar – notiser levereras vid COMMIT.
        lyssnare = _koppla()
        lyssnare.autocommit = True
        lyssnare.cursor().execute("LISTEN geoserver_schema")
        cls._samla_notiser(lyssnare, vanta=0.5)  # rensa det som redan skickats

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

        cls.notiser = cls._samla_notiser(lyssnare)
        lyssnare.close()

        cls.konfig = _fraga(
            "SELECT prefix, beskrivning, publiceras_geoserver, anonym_las"
            " FROM public.hex_standardiserade_skyddsnivaer ORDER BY prefix"
        )
        cls.uppgifter = _fraga(
            "SELECT rollnamn, losenord FROM public.hex_rolluppgifter"
            " WHERE rollnamn LIKE 'gs\\_%' ORDER BY rollnamn"
        )

    @classmethod
    def tearDownClass(cls):
        try:
            conn = _koppla()
            conn.autocommit = True
            cur = conn.cursor()
            for schema in cls.SCHEMAN:
                cur.execute(f"DROP SCHEMA IF EXISTS {schema} CASCADE")
            conn.close()
        except Exception:  # pragma: no cover
            pass
        _ta_bort_databas()
        for schema in cls.SCHEMAN:
            for prefix in ("r_", "w_", "gs_r_", "gs_w_"):
                try:
                    _admin_exec(f'DROP ROLE IF EXISTS "{prefix}{schema}"')
                except Exception:  # pragma: no cover
                    pass

    def test_standardschemat_notifieras(self):
        """sk0 publicerades redan i defaultkonfigurationen."""
        self.assertIn("sk0_kba_gs", self.notiser)

    def test_skx_schemat_notifieras(self):
        """Kärnan i buggen: skx står som false i defaultarna, true hos kunden."""
        self.assertIn(
            "skx_kba_gs", self.notiser,
            "skx_kba_gs fick ingen geoserver_schema-notis under uppgraderingen"
            f" (mottagna: {self.notiser})",
        )

    def test_dba_tillagt_prefix_notifieras(self):
        """Ett prefix som inte alls finns i INSERT-defaultarna."""
        self.assertIn(
            "sk9_kba_gs", self.notiser,
            f"sk9_kba_gs fick ingen notis (mottagna: {self.notiser})",
        )

    def test_ej_publicerat_prefix_notifieras_inte(self):
        """Notifieringen ska följa konfigurationen, inte skicka till alla."""
        self.assertNotIn("sk2_kba_gs", self.notiser)

    def test_konfigurationen_overlevde(self):
        """Ingen regression i själva bevarandet."""
        self.assertEqual(
            self.konfig,
            [
                ("sk0", "Öppen publik data", True, True),
                ("sk1", "Kommunal data med begränsad åtkomst", True, False),
                ("sk2", "Begränsad känslig data", False, False),
                ("sk9", "DBA-tillagd nivå", True, False),
                ("skx", "Okänd / oklassificerad data (endast GIS-administratörer)", True, False),
            ],
        )

    def test_lagrade_uppgifter_stammer_med_rollernas_losenord(self):
        """
        Uppgraderingen roterar gs_-lösenorden. Det som ligger i
        hex_rolluppgifter måste vara det roller faktiskt autentiserar med,
        annars sätter lyssnaren upp en datastore som inte kan logga in.
        """
        self.assertTrue(self.uppgifter, "inga gs_-uppgifter att kontrollera")
        params = {k: v for k, v in _db_config().items() if k != "owner_role"}
        for rollnamn, losenord in self.uppgifter:
            with self.subTest(roll=rollnamn):
                anslutning = psycopg2.connect(
                    **{**params, "user": rollnamn, "password": losenord}
                )
                anslutning.close()


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestAvinstallation(unittest.TestCase):
    """uninstall() ska inte lämna kvar några Hex-objekt i databasen."""

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        install_hex.uninstall(_db_config())

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_inga_event_triggers_kvar(self):
        rader = _fraga("SELECT evtname FROM pg_event_trigger WHERE evtname LIKE 'hex%'")
        self.assertEqual(rader, [])

    def test_inga_funktioner_kvar(self):
        rader = _fraga(
            "SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
            " WHERE n.nspname = 'public' AND p.proname LIKE 'hex\\_%' ORDER BY 1"
        )
        self.assertEqual([r[0] for r in rader], [])

    def test_inga_tabeller_kvar(self):
        rader = _fraga(
            "SELECT tablename FROM pg_tables"
            " WHERE schemaname = 'public' AND tablename LIKE 'hex%' ORDER BY 1"
        )
        self.assertEqual([r[0] for r in rader], [])

    def test_inga_typer_kvar(self):
        rader = _fraga(
            "SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace"
            " WHERE n.nspname = 'public' AND t.typname LIKE 'hex%'"
            " AND t.typtype = 'c' ORDER BY 1"
        )
        self.assertEqual([r[0] for r in rader], [])

    def test_ominstallation_fungerar(self):
        """Efter avinstallation ska en ny installation gå igenom."""
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        (antal,) = _fraga(
            "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"
        )[0]
        self.assertEqual(antal, 10)


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestArvdaObjekt(unittest.TestCase):
    """
    En databas installerad före namnbytet till hex_-prefix bär kvar objekt
    under sina gamla namn. Den kvarlämnade event-triggern hantera_ny_tabell_trigger
    är det som gör dem farliga: den avfyras på nästa CREATE TABLE, slår mot
    public.hex_systemanvandare innan tabellen hunnit skapas och river hela
    installationstransaktionen.
    """

    # Ett representativt urval ärvda objekt – event-trigger med funktion,
    # en gammal typ och två gamla tabeller.
    ARVT_SQL = """
    CREATE FUNCTION public.hantera_ny_tabell() RETURNS event_trigger
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    DECLARE ar_systemanvandare boolean;
    BEGIN
        SELECT EXISTS (
            SELECT 1 FROM public.hex_systemanvandare
            WHERE anvandare IN (lower(session_user))
        ) INTO ar_systemanvandare;
    END; $$;

    CREATE TYPE public.geom_info AS (typ text);
    CREATE TABLE public.standardiserade_skyddsnivaer (prefix text);
    CREATE TABLE public.hex_role_credentials (rolname text);

    -- Sist: annars avfyras triggern på tabellerna ovan och river uppsättningen.
    CREATE EVENT TRIGGER hantera_ny_tabell_trigger ON DDL_COMMAND_END
        WHEN TAG IN ('CREATE TABLE')
        EXECUTE PROCEDURE public.hantera_ny_tabell();
    """

    def setUp(self):
        _skapa_tom_databas()
        conn = _koppla()
        try:
            conn.cursor().execute(self.ARVT_SQL)
            conn.commit()
        finally:
            conn.close()

    def tearDown(self):
        _ta_bort_databas()

    def test_installation_gar_igenom(self):
        """Ärvda event-triggers får inte stoppa en ren installation."""
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        (antal,) = _fraga(
            "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"
        )[0]
        self.assertEqual(antal, 10)

    def test_installation_tar_bort_arvda_event_triggers(self):
        """
        Bara event-triggarna rensas vid installation. Tabellerna kan bära
        data och lämnas orörda tills användaren avinstallerar.
        """
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        kvar = _fraga(
            "SELECT evtname FROM pg_event_trigger WHERE evtname NOT LIKE 'hex%'"
        )
        self.assertEqual(kvar, [])
        self.assertEqual(
            _fraga(
                "SELECT count(*) FROM pg_tables"
                " WHERE schemaname = 'public'"
                " AND tablename = 'standardiserade_skyddsnivaer'"
            )[0][0],
            1,
        )

    def test_avinstallation_tar_bort_alla_arvda_objekt(self):
        """Avinstallationen ska lämna databasen fri från gamla namn."""
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        install_hex.uninstall(_db_config())

        self.assertEqual(_fraga("SELECT evtname FROM pg_event_trigger"), [])
        self.assertEqual(
            _fraga(
                "SELECT p.proname FROM pg_proc p"
                " JOIN pg_namespace n ON n.oid = p.pronamespace"
                " WHERE n.nspname = 'public' AND p.proname = 'hantera_ny_tabell'"
            ),
            [],
        )
        self.assertEqual(
            _fraga(
                "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
                " AND tablename IN ('standardiserade_skyddsnivaer',"
                " 'hex_role_credentials') ORDER BY 1"
            ),
            [],
        )
        self.assertEqual(
            _fraga(
                "SELECT t.typname FROM pg_type t"
                " JOIN pg_namespace n ON n.oid = t.typnamespace"
                " WHERE n.nspname = 'public' AND t.typname = 'geom_info'"
            ),
            [],
        )

    def test_uppgradering_gar_igenom(self):
        """upgrade() ska klara samma databas – det var vägen felet uppstod på."""
        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))
        (antal,) = _fraga(
            "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"
        )[0]
        self.assertEqual(antal, 10)


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestAgarrollNone(unittest.TestCase):
    """
    owner_role=None: den anslutande användaren äger objekten.

    REGRESSION: konfigurationen gick tidigare inte att installera alls.
    Installern tog då bort ägarskapssatserna ur SQL:en före körning, och
    strök raden med OWNER TO i stället för hela satsen. Eftersom de flesta
    filer skrev satsen över två rader blev det kvar ett dinglande ALTER utan
    avslutning, och installationen dog på första typfilen med "syntax error
    at end of input". Filerna sätter numera ägaren mot hex_systemagare() och
    installern rör inte SQL:en, så borttagningen finns inte längre.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        cfg = _db_config()
        cfg["owner_role"] = None
        install_hex.install(cfg, base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_installationen_ar_komplett(self):
        (antal,) = _fraga(
            "SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"
        )[0]
        self.assertEqual(antal, 10)

    def test_anslutande_anvandare_ager_allt(self):
        """Utan owner_role ska inga objekt ha någon annan ägare."""
        anslutande = os.environ.get("PGUSER", "postgres")
        for sql, vad in (
            ("SELECT DISTINCT pg_get_userbyid(p.proowner)"
             " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
             " WHERE n.nspname = 'public' AND p.proname LIKE 'hex\\_%'", "funktioner"),
            ("SELECT DISTINCT pg_get_userbyid(evtowner) FROM pg_event_trigger", "event-triggers"),
            ("SELECT DISTINCT tableowner FROM pg_tables"
             " WHERE schemaname = 'public' AND tablename LIKE 'hex%'", "tabeller"),
        ):
            with self.subTest(objekt=vad):
                self.assertEqual([r[0] for r in _fraga(sql)], [anslutande])

    def test_hex_fungerar_efter_installation(self):
        """Installationen ska inte bara gå igenom, utan faktiskt fungera."""
        conn = _koppla()
        conn.autocommit = True
        try:
            cur = conn.cursor()
            cur.execute("CREATE SCHEMA sk0_ext_noneprov")
            cur.execute(
                "CREATE TABLE sk0_ext_noneprov.prov_p"
                " (namn text, geom geometry(Point, 3007))"
            )
            cur.execute(
                "SELECT column_name FROM information_schema.columns"
                " WHERE table_schema = 'sk0_ext_noneprov' AND table_name = 'prov_p'"
                " ORDER BY ordinal_position"
            )
            kolumner = [r[0] for r in cur.fetchall()]
            # Hex lägger till gid först och flyttar geometrin sist
            self.assertEqual(kolumner[0], "gid")
            self.assertEqual(kolumner[-1], "geom")

            cur.execute(
                "SELECT count(*) FROM pg_roles WHERE rolname LIKE '%sk0\\_ext\\_noneprov'"
            )
            self.assertEqual(cur.fetchone()[0], 4)
            cur.execute("DROP SCHEMA sk0_ext_noneprov CASCADE")
        finally:
            conn.close()


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestForutsattningar(unittest.TestCase):
    """kontrollera_forutsattningar() – versionsgolv och skrivbart public."""

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_inga_varningar_pa_hardad_databas(self):
        """En databas med PostgreSQL 15-standard ska inte ge varningar."""
        conn = _koppla()
        try:
            cur = conn.cursor()
            cur.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            self.assertEqual(install_hex.kontrollera_forutsattningar(cur), [])
        finally:
            conn.close()

    def test_varnar_nar_public_ar_skrivbart(self):
        """
        CREATE på public för PUBLIC ska ge en varning.

        Utan den kan vem som helst skugga ett Hex-objekt som en
        SECURITY DEFINER-funktion sedan slår upp.
        """
        conn = _koppla()
        try:
            cur = conn.cursor()
            cur.execute("GRANT CREATE ON SCHEMA public TO PUBLIC")
            varningar = install_hex.kontrollera_forutsattningar(cur)
            self.assertEqual(len(varningar), 1)
            self.assertIn("PUBLIC", varningar[0])
            self.assertIn("REVOKE CREATE", varningar[0])
        finally:
            conn.close()

    def test_avbryter_mot_for_gammal_server(self):
        """
        Versionsgolvet ska stoppa installationen, inte bara varna.

        En riktig PostgreSQL 15-server går inte att starta i sviten, så
        cursorn ersätts med en stubbe som rapporterar äldre version.
        """

        class StubCursor:
            def execute(self, *_a, **_kw):
                pass

            def fetchone(self):
                return (150000, "PostgreSQL 15.0 (stub)")

        with self.assertRaises(RuntimeError) as ctx:
            install_hex.kontrollera_forutsattningar(StubCursor())
        self.assertIn("PostgreSQL 16", str(ctx.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
