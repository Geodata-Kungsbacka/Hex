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

import contextlib
import io
import os
import select
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

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
    Numera står ON CONFLICT DO NOTHING i båda INSERT-satserna, och sk0-raden
    sätts bara av INSERT:en. Testet vaktar att det förblir så.

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


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingFranAldreSchema(unittest.TestCase):
    """
    snapshot_settings/restore_settings tål att den gamla databasens schema
    skiljer sig från det nya.

    Det är hela poängen med "strukturell difftolerans" i restore_settings, och
    det är förutsättningen för varje framtida HEX-MIGRERING: en databas som
    uppgraderas från en äldre Hex-version har inte nödvändigtvis samma
    kolumner och tabeller som SQL-filerna skapar i dag. Fungerar inte
    toleransen faller uppgraderingen på det första schemaglappet, eller —
    värre — går igenom och tappar DBA:ns konfiguration tyst.

    Sviten gör tvärtom mot en vanlig uppgraderingstest: den installerar först
    dagens Hex och *bakar sedan tillbaka* schemat till något äldre, innan
    upgrade() körs. Fyra glapp samtidigt, alla i olika tabeller:

      1. En kolumn saknas       – anonym_las, som CLAUDE.md använder som
                                  typexempel på en kolumn som tillkom efter
                                  tabellen.
      2. Bara nyckeln finns kvar – båda datakolumnerna borta ur
                                  hex_standardiserade_datakategorier. Då körs
                                  ingen UPDATE alls, och restore_settings
                                  måste fråga efter raden i stället för att
                                  läsa cur.rowcount (som annars bär resultatet
                                  från föregående sats).
      3. En hel tabell saknas    – hex_grupprattigheter, som om den vore
                                  tillagd i en senare version.
      4. En död rad i tillståndet – hex_metadata med en OID som inte pekar på
                                  någon tabell.

    En vakt går inte att fästa så här: `if not _table_exists(...)` i _las är
    redundant, eftersom _table_columns() ger en tom mängd för en tabell som
    inte finns och funktionen då returnerar None ändå. Utfallet är identiskt
    med och utan raden, så inget beteendetest kan skilja dem åt.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()

        # DBA-ändring i en kolumn som finns kvar även i det gamla schemat.
        # Den ska överleva trots att grannkolumnen saknas.
        cur.execute(
            "UPDATE public.hex_standardiserade_skyddsnivaer"
            " SET publiceras_geoserver = true WHERE prefix = 'skx'"
        )
        # 1. Kolumn saknas.
        cur.execute(
            "ALTER TABLE public.hex_standardiserade_skyddsnivaer DROP COLUMN anonym_las"
        )
        # 2. Bara nyckelkolumnen kvar – plus en rad DBA lagt till själv.
        cur.execute(
            "ALTER TABLE public.hex_standardiserade_datakategorier DROP COLUMN beskrivning"
        )
        cur.execute(
            "ALTER TABLE public.hex_standardiserade_datakategorier"
            " DROP COLUMN hex_validera_geometri"
        )
        cur.execute(
            "INSERT INTO public.hex_standardiserade_datakategorier (prefix) VALUES ('egn')"
        )
        # 3. Hel tabell saknas.
        cur.execute("DROP TABLE public.hex_grupprattigheter")
        # Användardata i en tabell som *inte* rörts – ska inte påverkas av att
        # grannarna har schemaglapp.
        cur.execute(
            "INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)"
            " VALUES ('etl_verktyg', 'Tillagd av DBA')"
        )
        # 4. Död rad i drifttillståndet.
        cur.execute(
            "INSERT INTO public.hex_metadata"
            " (parent_oid, parent_schema, parent_table, history_schema,"
            "  history_table, trigger_funktion)"
            " VALUES (999999999, 'sk0_ext_borta', 't_p', 'sk0_ext_borta', 't_p_h', 'f')"
        )
        conn.close()

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    # -- 1. Kolumn som saknades ---------------------------------------------

    def test_saknad_kolumn_far_nya_schemats_standardvarde(self):
        """anonym_las fanns inte i snapshoten och ska komma från SQL-filen."""
        rader = dict(_fraga(
            "SELECT prefix, anonym_las FROM public.hex_standardiserade_skyddsnivaer"
        ))
        self.assertTrue(rader["sk0"], "sk0 har anonym_las = true i standardkonfigurationen")
        self.assertFalse(rader["sk1"])

    def test_dba_andring_i_kvarvarande_kolumn_bevaras(self):
        """
        Att en grannkolumn saknades får inte kosta DBA:ns värde.

        Utan difftoleransen skulle hela raden hoppas över, och skx falla
        tillbaka på publiceras_geoserver = false.
        """
        rader = _fraga(
            "SELECT publiceras_geoserver FROM public.hex_standardiserade_skyddsnivaer"
            " WHERE prefix = 'skx'"
        )
        self.assertEqual(rader, [(True,)])

    # -- 2. Bara nyckelkolumnen kvar ----------------------------------------

    def test_egen_rad_bevaras_nar_bara_nyckeln_fanns(self):
        """
        Raden DBA lagt till ska tillbaka, trots att inga datakolumner sparades.

        Det är den väg där ingen UPDATE körs och rowcount inte går att lita
        på – raden måste sökas upp med en egen SELECT.
        """
        rader = _fraga(
            "SELECT prefix FROM public.hex_standardiserade_datakategorier"
            " WHERE prefix = 'egn'"
        )
        self.assertEqual(rader, [("egn",)])

    def test_standardraderna_far_sina_riktiga_varden(self):
        """De systemdefinierade raderna ska komma från SQL-filen, inte tomma."""
        rader = dict(_fraga(
            "SELECT prefix, hex_validera_geometri"
            " FROM public.hex_standardiserade_datakategorier"
        ))
        self.assertTrue(rader["kba"], "kba validerar geometri i standardkonfigurationen")
        self.assertFalse(rader["ext"])
        self.assertFalse(rader["egn"], "DBA-raden får nya schemats standardvärde")

    def test_inga_dubbletter_efter_schemaglapp(self):
        for tabell, nyckel in (
            ("hex_standardiserade_skyddsnivaer", "prefix"),
            ("hex_standardiserade_datakategorier", "prefix"),
        ):
            with self.subTest(tabell=tabell):
                self.assertEqual(
                    _fraga(f"SELECT {nyckel} FROM public.{tabell}"
                           f" GROUP BY {nyckel} HAVING count(*) > 1"),
                    [], f"dubbletter i {tabell}",
                )

    # -- 3. Tabell som saknades ---------------------------------------------

    def test_saknad_tabell_aterskapas_tom(self):
        """En tabell som inte fanns att spara ska skapas om, inte fattas."""
        self.assertEqual(
            _fraga("SELECT count(*) FROM information_schema.tables"
                   " WHERE table_schema = 'public' AND table_name = 'hex_grupprattigheter'"),
            [(1,)],
        )
        self.assertEqual(_fraga("SELECT count(*) FROM public.hex_grupprattigheter"), [(0,)])

    # -- 4. Död rad i drifttillståndet ---------------------------------------

    def test_metadatarad_med_dod_oid_slangs(self):
        """
        En OID som inte pekar på något får inte läggas tillbaka.

        Raden skulle bli en död post som hex_hantera_borttagen_tabell() aldrig
        städar bort, eftersom tabellen den beskriver inte finns.
        """
        self.assertEqual(
            _fraga("SELECT parent_oid FROM public.hex_metadata WHERE parent_oid = 999999999"),
            [],
        )

    # -- Orörda tabeller och slutresultat -------------------------------------

    def test_anvandardata_i_orord_tabell_bevaras(self):
        anvandare = [r[0] for r in _fraga(
            "SELECT anvandare FROM public.hex_systemanvandare ORDER BY anvandare"
        )]
        self.assertIn("etl_verktyg", anvandare)
        self.assertIn("fme", anvandare)

    def test_databasen_ar_fullt_installerad_efterat(self):
        """Schemaglappen får inte lämna uppgraderingen halvfärdig."""
        self.assertEqual(
            _fraga("SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"),
            [(10,)],
        )


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingUtanNaturligNyckel(unittest.TestCase):
    """
    Saknas den naturliga nyckeln kastas snapshoten för tabellen.

    Utan nyckeln går de sparade raderna inte att matcha mot de nyskapade, och
    varje rad skulle läggas till som "användartillagd" – en full uppsättning
    dubbletter ovanpå standarduppsättningen. Att tappa DBA:ns ändringar är
    illa; att fylla hex_standardiserade_skyddsnivaer med skräp är värre,
    eftersom tabellen styr vilka schemanamn som är giltiga.

    Egen klass därför att mutationen (kolumnnamnbyte på nyckeln) gäller samma
    tabell som klassen ovan redan muterar.

    OBS: skyddet ligger på två ställen – snapshot_settings kastar posten, och
    restore_settings hoppar över den om nyckeln ändå saknas. Vakterna är
    redundanta med flit, så testet fäller inte den ena ensam. Det fäller att
    *båda* försvinner, vilket är den egenskap som betyder något.
    """

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        conn = _koppla()
        conn.autocommit = True
        conn.cursor().execute(
            "ALTER TABLE public.hex_standardiserade_skyddsnivaer"
            " RENAME COLUMN prefix TO gammalt_prefix"
        )
        conn.close()
        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_exakt_standarduppsattningen_finns(self):
        rader = sorted(r[0] for r in _fraga(
            "SELECT prefix FROM public.hex_standardiserade_skyddsnivaer"
        ))
        self.assertEqual(rader, ["sk0", "sk1", "sk2", "skx"])

    def test_gamla_kolumnnamnet_ar_borta(self):
        self.assertEqual(
            _fraga("SELECT count(*) FROM information_schema.columns"
                   " WHERE table_schema = 'public'"
                   "   AND table_name = 'hex_standardiserade_skyddsnivaer'"
                   "   AND column_name = 'gammalt_prefix'"),
            [(0,)],
        )

    def test_uppgraderingen_gick_igenom(self):
        self.assertEqual(
            _fraga("SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"),
            [(10,)],
        )


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingNarNyaSchematTappatKolumn(unittest.TestCase):
    """
    Andra riktningen: snapshoten har en kolumn som nya schemat inte skapar.

    Klasserna ovan tar bort kolumner ur den *gamla* databasen, och då är
    snapshoten redan en delmängd av det nya schemat – filtret
    "bara kolumner som finns i båda" gör ingen skillnad. Det biter först när
    en kolumn står kvar i PRESERVE_CONFIG medan SQL-filen slutat skapa den,
    vilket är precis vad som gäller mitt i en migrering där en kolumn tagits
    bort men bevarandelistan ännu inte städats.

    Utan filtret bygger restore_settings en UPDATE mot en kolumn som inte
    finns, och hela uppgraderingen faller efter att avinstallationen redan
    kört – databasen står då ominstallerad men utan DBA:ns konfiguration.

    PRESERVE_CONFIG och PRESERVE_USER_DATA patchas för att ställa upp läget;
    kolumnen finns på riktigt i den gamla databasen.
    """

    GAMMAL_KOLUMN = "gammal_flagga"

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        # Kolumner som bara den gamla databasen har.
        cur.execute(
            f"ALTER TABLE public.hex_standardiserade_skyddsnivaer"
            f" ADD COLUMN {cls.GAMMAL_KOLUMN} boolean NOT NULL DEFAULT true"
        )
        cur.execute(
            f"ALTER TABLE public.hex_systemanvandare"
            f" ADD COLUMN {cls.GAMMAL_KOLUMN} text"
        )
        # DBA-ändring i en kolumn som finns i båda scheman – den ska överleva.
        cur.execute(
            "UPDATE public.hex_standardiserade_skyddsnivaer"
            " SET beskrivning = 'DBA-text' WHERE prefix = 'sk2'"
        )
        cur.execute(
            "INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)"
            " VALUES ('etl_verktyg', 'Tillagd av DBA')"
        )
        conn.close()

        # Bevarandelistorna nämner kolumnen som om den ännu inte städats bort.
        config = {
            tabell: {**cfg, "restore": list(cfg["restore"])}
            for tabell, cfg in install_hex.PRESERVE_CONFIG.items()
        }
        config["hex_standardiserade_skyddsnivaer"]["restore"].append(cls.GAMMAL_KOLUMN)
        # För en rent användarhanterad tabell finns ingen nyckel att falla
        # tillbaka på: blir listan tom efter filtreringen måste raden hoppas
        # över, annars byggs ett INSERT helt utan kolumner.
        user_data = {**install_hex.PRESERVE_USER_DATA,
                     "hex_systemanvandare": [cls.GAMMAL_KOLUMN]}

        with patch.object(install_hex, "PRESERVE_CONFIG", config), \
                patch.object(install_hex, "PRESERVE_USER_DATA", user_data):
            install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    def test_uppgraderingen_gick_igenom(self):
        """Utan filtret faller upgrade() efter att avinstallationen redan kört."""
        self.assertEqual(
            _fraga("SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"),
            [(10,)],
        )

    def test_kolumnen_som_nya_schemat_saknar_aterskapas_inte(self):
        """Återställningen ska inte återinföra en kolumn SQL-filen tagit bort."""
        for tabell in ("hex_standardiserade_skyddsnivaer", "hex_systemanvandare"):
            with self.subTest(tabell=tabell):
                self.assertEqual(
                    _fraga(
                        "SELECT count(*) FROM information_schema.columns"
                        " WHERE table_schema = 'public' AND table_name = %s"
                        "   AND column_name = %s",
                        (tabell, self.GAMMAL_KOLUMN),
                    ),
                    [(0,)],
                )

    def test_ovriga_kolumner_aterstalls_anda(self):
        """Den borttagna kolumnen får inte dra med sig resten av raden."""
        self.assertEqual(
            _fraga("SELECT beskrivning FROM public.hex_standardiserade_skyddsnivaer"
                   " WHERE prefix = 'sk2'"),
            [("DBA-text",)],
        )

    def test_standarduppsattningen_ar_intakt(self):
        rader = sorted(r[0] for r in _fraga(
            "SELECT prefix FROM public.hex_standardiserade_skyddsnivaer"
        ))
        self.assertEqual(rader, ["sk0", "sk1", "sk2", "skx"])

    def test_tabell_utan_aterstallbara_kolumner_hoppas_over(self):
        """
        Inget att återställa ska bli ingen INSERT – inte ett tomt INSERT.

        hex_systemanvandare hade bara den borttagna kolumnen i bevarandelistan
        här, så DBA-raden går förlorad. Det är rätt utfall: det fanns inget
        att lägga tillbaka. Det som testas är att uppgraderingen inte faller.
        """
        anvandare = [r[0] for r in _fraga(
            "SELECT anvandare FROM public.hex_systemanvandare ORDER BY anvandare"
        )]
        self.assertEqual(anvandare, ["fme"], "standardraden ska finnas kvar")


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestFelvagar(unittest.TestCase):
    """
    Felvägarna i install(), uninstall(), upgrade() och kor_underhall().

    README lovar att installationsskriptet "rullar tillbaka om något
    misslyckas". Löftet är transaktionellt och gick inte att lita på förrän
    det testades: samtliga except-grenar var otäckta, så en ändring som råkade
    committa i förtid hade inte märkts.
    """

    def setUp(self):
        _skapa_tom_databas()

    def tearDown(self):
        _ta_bort_databas()

    def _installera(self):
        with contextlib.redirect_stdout(io.StringIO()):
            install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

    def _antal_hex_funktioner(self):
        return _fraga(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
            " WHERE n.nspname = 'public' AND p.proname LIKE 'hex\\_%'"
        )[0][0]

    def test_saknad_sql_fil_installerar_ingenting(self):
        """
        Avbryts installationen ska databasen vara orörd.

        install() hinner skapa tillägg och hex_systemagare() innan loopen över
        SQL-filerna. Committades något av det innan felet skulle databasen bli
        halvinstallerad – svårare att reda ut än en som aldrig rörts.
        """
        buf = io.StringIO()
        with self.assertRaises(FileNotFoundError) as ctx:
            with contextlib.redirect_stdout(buf):
                install_hex.install(_db_config(), base_path="/finns/inte")
        self.assertIn("Saknas:", str(ctx.exception))
        self.assertEqual(self._antal_hex_funktioner(), 0,
                         "transaktionen ska ha rullats tillbaka")
        self.assertIn("Transaktionen återställd", buf.getvalue())

    def test_avinstallation_rullar_tillbaka_vid_fel(self):
        """
        Ett fel mitt i UNINSTALL_SQL får inte lämna hälften borttaget.

        DROP-satserna körs i beroendeordning; avbryts de halvvägs står
        databasen med funktioner vars typer är borta. Därför ska hela satsen
        rullas tillbaka och felet kastas vidare.
        """
        self._installera()
        trasig = "DROP TABLE public.hex_systemanvandare; SELECT 1/0;"
        buf = io.StringIO()
        with patch.object(install_hex, "UNINSTALL_SQL", trasig):
            with self.assertRaises(psycopg2.Error):
                with contextlib.redirect_stdout(buf):
                    install_hex.uninstall(_db_config())
        self.assertEqual(
            _fraga("SELECT count(*) FROM information_schema.tables"
                   " WHERE table_schema = 'public' AND table_name = 'hex_systemanvandare'"),
            [(1,)],
            "tabellen som hann droppas ska vara tillbaka efter rollback",
        )
        self.assertIn("MISSLYCKADES", buf.getvalue())

    def test_underhallsfel_avbryter_inte_installationen(self):
        """
        kor_underhall() ska rapportera fel, inte kasta.

        Underhållet körs som ett eget steg efter commit just för att ett fel
        där inte ska rulla tillbaka en färdig installation. Anslutningen måste
        dessutom vara användbar efteråt, annars kan install() inte skriva ut
        sina varningar.
        """
        self._installera()
        conn = _koppla()
        cur = conn.cursor()
        cur.execute("DROP FUNCTION public.hex_underhall()")
        conn.commit()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                fel = install_hex.kor_underhall(cur, conn)
            self.assertIsNotNone(fel, "ett underhållsfel ska returneras som text")
            self.assertIn("Underhåll misslyckades", fel)
            self.assertIn("hex_underhall()", fel, "texten ska säga vad DBA kan köra manuellt")
            cur.execute("SELECT 1")
            self.assertEqual(cur.fetchone(), (1,), "anslutningen ska vara användbar efter rollback")
        finally:
            conn.close()

    def test_uppgradering_av_tom_databas_varnar_men_lyckas(self):
        """
        docs/09: en tom snapshot är normalt i en tom databas.

        Varningen finns för det andra fallet – en databas som redan kör Hex
        men vars konfiguration inte hittades. Då är det sista tillfället att
        säga till innan avinstallationen kastar den.
        """
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))
        self.assertIn("Inga inställningar hittades att spara", buf.getvalue())
        self.assertEqual(
            _fraga("SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"),
            [(10,)],
            "uppgradering av en tom databas ska ge en installerad databas",
        )

    def test_underhallsfel_faller_inte_installationen(self):
        """
        Underhållet körs efter commit just för att inte kunna fälla install().

        install() committar SQL-filerna först och kör hex_underhall() som ett
        eget steg. Ett fel där ska bli en varning på slutet, inte ett avbrott:
        databasen är installerad, och DBA kan köra underhållet för hand.
        """
        buf = io.StringIO()
        with patch.object(install_hex, "kor_underhall",
                          return_value="Underhåll misslyckades: uppdiktat fel"):
            with contextlib.redirect_stdout(buf):
                install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        utskrift = buf.getvalue()
        self.assertIn("Underhåll misslyckades", utskrift)
        self.assertIn("varning(ar) kvar att åtgärda", utskrift,
                      "varningen ska upprepas sist, inte drunkna i loggen")
        self.assertEqual(
            _fraga("SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'hex%'"),
            [(10,)],
            "installationen ska vara klar trots underhållsfelet",
        )

    def test_underhallsfel_faller_inte_uppgraderingen(self):
        """Samma sak för upgrade(): underhållet körs om efter återställningen."""
        self._installera()
        buf = io.StringIO()
        with patch.object(install_hex, "kor_underhall",
                          return_value="Underhåll misslyckades: uppdiktat fel"):
            with contextlib.redirect_stdout(buf):
                install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))
        self.assertIn("Underhåll misslyckades", buf.getvalue())
        self.assertIn("Uppgradering klar", buf.getvalue())

    def test_fel_i_aterstallningen_rullar_tillbaka_och_kastar_vidare(self):
        """
        Misslyckas återställningen ska den inte lämna halva konfigurationen.

        Felet måste dessutom nå anroparen: main() räknar en databas som
        lyckad om upgrade() returnerar utan undantag, och en tyst
        återställning hade rapporterats som OK.
        """
        self._installera()
        buf = io.StringIO()
        with patch.object(install_hex, "restore_settings",
                          side_effect=RuntimeError("återställningen sprack")):
            with self.assertRaises(RuntimeError):
                with contextlib.redirect_stdout(buf):
                    install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))
        self.assertIn("MISSLYCKADES vid återställning", buf.getvalue())


class _PausUppgraderingBas(unittest.TestCase):
    """
    Gemensam uppsättning: installera, skapa en Hex-tabell, pausa, uppgradera.

    Uppsättningen ligger i en basklass i stället för i en delad klass med flera
    testmetoder, eftersom unittest kör metoder i bokstavsordning. Ett test som
    kör hex_ateruppta() skulle då reparera tillståndet innan de test som ska
    läsa det hann köra. Två klasser med var sin setUpClass är ordningsoberoende.
    """

    SCHEMA = "sk0_kba_pausupg"

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute(f"CREATE SCHEMA {cls.SCHEMA}")
        cur.execute(
            f"CREATE TABLE {cls.SCHEMA}.hus_y"
            " (namn text, geom geometry(Polygon, 3007))"
        )
        cur.execute("SELECT count(*) FROM public.hex_pausa('livscykeltest')")
        conn.close()

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

        cls.conn = _koppla()
        cls.conn.autocommit = True
        cls.cur = cls.conn.cursor()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()
        _ta_bort_databas()

    def _avstangda_radtriggers(self):
        self.cur.execute(
            "SELECT tg.tgname FROM pg_trigger tg"
            " JOIN pg_class c ON c.oid = tg.tgrelid"
            " JOIN pg_namespace n ON n.oid = c.relnamespace"
            " WHERE NOT tg.tgisinternal AND n.nspname = %s"
            "   AND tg.tgenabled = 'D' ORDER BY tg.tgname",
            (self.SCHEMA,),
        )
        return [r[0] for r in self.cur.fetchall()]


class TestUppgraderingUnderPaus(_PausUppgraderingBas):
    """
    hex_paus måste överleva upgrade(), annars går avstängda radtriggers inte
    att reparera.

    upgrade() avinstallerar och installerar om. Avinstallationen droppar
    Hex-funktionerna i public med CASCADE, så de radtriggers vars
    triggerfunktion ligger där (hex_tvinga_gid, hex_kontrollera_geom,
    hex_ta_bort_dummy) försvinner och skapas om påslagna av hex_underhall().

    De vars funktion ligger i Hex-schemat överlever däremot avinstallationen:
    trg_<tabell>_qa och hex_tvinga_anvandarvarden. hex_underhall() skapar
    saknade triggers men slår inte på avstängda, så de rörs aldrig. Kastas
    hex_paus bort av uppgraderingen finns ingen kvar som vet att de var
    avstängda — historik och QA-kolumner slutar uppdateras tyst.

    Därför står hex_paus i PRESERVE_STATE. Raden påstår inte att pausen
    fortfarande gäller: event-triggarna är påslagna efter uppgraderingen, och
    hex_pausstatus() rapporterar just den motsägelsen.
    """

    def test_hex_paus_overlever_uppgraderingen(self):
        self.cur.execute("SELECT anledning FROM public.hex_paus")
        rad = self.cur.fetchone()
        self.assertIsNotNone(rad, "hex_paus-raden kastades bort av upgrade()")
        self.assertEqual(rad[0], "livscykeltest")

    def test_tidigare_lage_overlever_som_jsonb(self):
        """psycopg2 läser jsonb som dict och kan inte skriva tillbaka den utan
        Json-adaptern. Utan den sprack upgrade() med "can't adapt type 'dict'"."""
        self.cur.execute(
            "SELECT jsonb_array_length(tidigare_lage -> 'radtriggers'),"
            "       jsonb_array_length(tidigare_lage -> 'event_triggers')"
            " FROM public.hex_paus"
        )
        radtriggers, event_triggers = self.cur.fetchone()
        self.assertEqual(radtriggers, 5, "radtriggerlägena kom inte över")
        self.assertEqual(event_triggers, 10, "event-triggerlägena kom inte över")

    def test_event_triggers_ar_paslagna_efter_uppgradering(self):
        """Uppgraderingen skapar om dem, och en ny event-trigger är alltid på."""
        self.cur.execute(
            "SELECT count(*) FROM pg_event_trigger WHERE evtenabled <> 'D'"
        )
        self.assertEqual(self.cur.fetchone()[0], 10)

    def test_pausstatus_flaggar_motsagelsen(self):
        self.cur.execute("SELECT pausad, avvikelse FROM public.hex_pausstatus()")
        pausad, avvikelse = self.cur.fetchone()
        self.assertTrue(pausad)
        self.assertIsNotNone(avvikelse, "avvikelsen mellan hex_paus och katalogen missades")
        self.assertIn("påslagna trots att hex_paus säger pausat", avvikelse)

    def test_radtriggers_i_hex_schemat_ar_kvar_avstangda(self):
        """Utgångsläget som gör bevarandet nödvändigt."""
        self.assertEqual(
            self._avstangda_radtriggers(),
            ["hex_tvinga_anvandarvarden", "trg_hus_y_qa"],
        )

    def test_pausmarkoren_foljer_med_raden(self):
        """
        Invarianten är "rad i hex_paus <=> markör satt".

        Avinstallationen nollställer markören med flit – den ska inte lämnas
        kvar och påstå att en paus finns. Men upgrade() kör samma
        UNINSTALL_SQL, och där ska pausen överleva. Utan att markören sätts
        igen kom raden tillbaka utan sin markör, och hex_pausstatus() hade
        rapporterat en avvikelse för ett läge installatören själv skapat.
        """
        self.cur.execute("SELECT public.hex_pausmarkor()")
        self.assertIsNotNone(
            self.cur.fetchone()[0],
            "pausmarkören sattes inte tillbaka av upgrade()",
        )

        self.cur.execute("SELECT avvikelse FROM public.hex_pausstatus()")
        self.assertNotIn(
            "Ingen pausmarkör satt", self.cur.fetchone()[0] or "",
            "uppgraderingen lämnade ett läge som rapporteras som avvikelse",
        )


class TestAterupptaEfterUppgraderingUnderPaus(_PausUppgraderingBas):
    """
    hex_ateruppta() reparerar det uppgraderingen lämnade efter sig.

    En enda testmetod med flit. Klassen delar databas mellan sina metoder, och
    hex_ateruppta() ändrar just det tillstånd assertionen läser — två metoder
    hade blivit beroende av bokstavsordningen mellan sig.
    """

    def test_ateruppta_reparerar_och_historiken_lever_igen(self):
        # Utgångsläge: de två triggarna vars funktion ligger i Hex-schemat är
        # kvar avstängda efter uppgraderingen.
        self.assertEqual(
            self._avstangda_radtriggers(),
            ["hex_tvinga_anvandarvarden", "trg_hus_y_qa"],
            "utgångsläget stämmer inte – testet mäter inte det det tror",
        )

        self.cur.execute("SELECT count(*) FROM public.hex_ateruppta()")

        self.assertEqual(self._avstangda_radtriggers(), [])
        self.cur.execute("SELECT pausad, avvikelse FROM public.hex_pausstatus()")
        pausad, avvikelse = self.cur.fetchone()
        self.assertFalse(pausad)
        self.assertIsNone(avvikelse)

        # Det som faktiskt stod på spel: QA-triggern skriver historik igen.
        self.cur.execute(
            f"INSERT INTO {self.SCHEMA}.hus_y (namn, geom)"
            " VALUES ('hus1', ST_GeomFromText('POLYGON((0 0,0 1,1 1,1 0,0 0))', 3007))"
        )
        self.cur.execute(f"UPDATE {self.SCHEMA}.hus_y SET namn = 'hus1_andrad'")
        self.cur.execute(
            f"SELECT count(*) FROM {self.SCHEMA}.hus_y_h WHERE h_typ = 'U'"
        )
        self.assertEqual(
            self.cur.fetchone()[0], 1,
            "historiken skrevs inte – QA-triggern är fortfarande avstängd",
        )


class TestUnderhallsvarningVidPaus(unittest.TestCase):
    """
    hex_underhall() ska varna för en pausad databas – utom när hex_ateruppta()
    är den som kör.

    Varningen finns för att fånga en installatörskörning eller ett manuellt
    anrop mitt under en pg_restore: underhållet skapar triggar, delar ut
    rättigheter och notifierar GeoServer mot halvt inlästa tabeller.

    Men hex_ateruppta() kör hex_underhall() med flit medan pausen fortfarande
    gäller – det är så en återläsning repareras. Utan undantaget skrev alltså
    varenda korrekt återupptagning ut en uppmaning att avbryta, och en varning
    som alltid syns slutar betyda något.

    Varningar syns bara på klientsidan, därför ligger testet här och inte i
    test_pausa.sql: psycopg2 samlar dem i conn.notices.
    """

    SCHEMA = "sk0_kba_pausvarning"

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        cls.conn = _koppla()
        cls.conn.autocommit = True
        cls.cur = cls.conn.cursor()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()
        _ta_bort_databas()

    def _varningar(self, sql: str) -> list[str]:
        """Kör sql och returnerar de pausvarningar servern skickade."""
        del self.conn.notices[:]
        self.cur.execute(sql)
        return [n for n in self.conn.notices if "Hex är pausat" in n]

    def test_manuellt_anrop_under_paus_varnar(self):
        self.cur.execute("SELECT count(*) FROM public.hex_pausa('varningstest')")
        try:
            varningar = self._varningar("SELECT count(*) FROM public.hex_underhall()")
            self.assertEqual(
                len(varningar), 1,
                "hex_underhall() varnade inte trots att databasen var pausad",
            )
        finally:
            self.cur.execute("SELECT count(*) FROM public.hex_ateruppta(false)")

    def test_ateruppta_varnar_inte(self):
        self.cur.execute("SELECT count(*) FROM public.hex_pausa('varningstest')")
        varningar = self._varningar("SELECT count(*) FROM public.hex_ateruppta()")
        self.assertEqual(
            varningar, [],
            "hex_ateruppta() fick underhållets pausvarning – den korrekta vägen "
            "ska inte uppmana operatören att avbryta",
        )

    def test_flaggan_lacker_inte_till_nasta_anrop(self):
        """
        Undantaget är transaktionslokalt och nollställs dessutom explicit.
        Läckte det vore varningen borta även för det farliga anropet.
        """
        self.cur.execute("SELECT count(*) FROM public.hex_pausa('varningstest')")
        try:
            self.cur.execute("SELECT count(*) FROM public.hex_ateruppta(false)")
            self.cur.execute("SELECT count(*) FROM public.hex_pausa('varningstest igen')")
            varningar = self._varningar("SELECT count(*) FROM public.hex_underhall()")
            self.assertEqual(
                len(varningar), 1,
                "varningen uteblev – hex.ateruppta_pagar läckte till nästa anrop",
            )
        finally:
            self.cur.execute("SELECT count(*) FROM public.hex_ateruppta(false)")


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestUppgraderingGidPrimarnyckel(unittest.TestCase):
    """
    HEX-MIGRERING 2026-08: PRIMARY KEY (gid) tillkom efter att tabellerna
    skapats. Sviten bygger upp det gamla tillståndet — Hex-tabeller vars gid
    saknar unikt index, två av dem med dubbletter — kör upgrade() och
    kontrollerar att hex_underhall() lägger på nyckeln utan att röra data.
    Tas bort tillsammans med migreringen.
    """

    #: Tabeller som byggs upp i det gamla tillståndet. 'dubbel' kontrolleras
    #: orörd; 'dubbel_rep' är den enda som repareras, så testordningen spelar
    #: ingen roll.
    TABELLER = ("ren", "dubbel", "dubbel_rep")

    @classmethod
    def setUpClass(cls):
        _skapa_tom_databas()
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        conn = _koppla()
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("CREATE SCHEMA sk1_kba_gidmig")
        for tabell in cls.TABELLER:
            cur.execute(f"CREATE TABLE sk1_kba_gidmig.{tabell} (namn text)")

        # Återskapa läget före migreringen: ta bort nyckeln som steg 7.4 lade
        # på, och stäng av triggern så att klientvärden skrivs rakt igenom.
        for tabell in cls.TABELLER:
            cur.execute(
                f"ALTER TABLE sk1_kba_gidmig.{tabell}"
                f" DROP CONSTRAINT {tabell}_pkey"
            )
            cur.execute(
                f"ALTER TABLE sk1_kba_gidmig.{tabell}"
                f" DISABLE TRIGGER hex_tvinga_gid"
            )

        cur.execute(
            "INSERT INTO sk1_kba_gidmig.ren (gid, namn) OVERRIDING SYSTEM VALUE"
            " VALUES (1, 'a'), (2, 'b'), (5000, 'långt-fram')"
        )
        # Precis den tysta dubblett som avsaknaden av unikt index tillät.
        for tabell in ("dubbel", "dubbel_rep"):
            cur.execute(
                f"INSERT INTO sk1_kba_gidmig.{tabell} (gid, namn)"
                f" OVERRIDING SYSTEM VALUE VALUES (1, 'x'), (1, 'y'), (2, 'z')"
            )
        conn.close()

        install_hex.upgrade(_db_config(), base_path=str(PROJECT_ROOT))

    @classmethod
    def tearDownClass(cls):
        _ta_bort_databas()

    @staticmethod
    def _kor(sql):
        """Kör en sats i autocommit — _fraga() rullar tillbaka vid stängning."""
        conn = _koppla()
        conn.autocommit = True
        try:
            cur = conn.cursor()
            cur.execute(sql)
            return cur.fetchall() if cur.description else []
        finally:
            conn.close()

    @staticmethod
    def _unikt_index_pa_gid(tabell):
        rader = _fraga(
            "SELECT EXISTS ("
            "  SELECT 1 FROM pg_index i"
            "  JOIN pg_attribute a ON a.attrelid = i.indrelid"
            "                     AND a.attnum::text = i.indkey::text"
            "  WHERE i.indrelid = %s::regclass AND i.indisunique"
            "    AND a.attname = 'gid')",
            (f"sk1_kba_gidmig.{tabell}",),
        )
        return rader[0][0]

    def test_tabell_utan_dubbletter_far_nyckeln(self):
        """Uppgraderingen ska lägga tillbaka det unika indexet på gid."""
        self.assertTrue(self._unikt_index_pa_gid("ren"))

    def test_sekvensen_flyttades_forbi_hogsta_gid(self):
        """
        Data inläst med OVERRIDING SYSTEM VALUE kan ligga ovanför sekvensen.
        Flyttas den inte fram före nyckeln faller nästa INSERT på dubblett.
        """
        rader = self._kor(
            "INSERT INTO sk1_kba_gidmig.ren (namn) VALUES ('efter') RETURNING gid"
        )
        self.assertGreater(rader[0][0], 5000)

    def test_tabell_med_dubbletter_lamnas_orord(self):
        """Dubbletter ska rapporteras, inte tystas — och data ska stå kvar."""
        self.assertFalse(self._unikt_index_pa_gid("dubbel"))
        self.assertEqual(
            _fraga("SELECT count(*) FROM sk1_kba_gidmig.dubbel"), [(3,)]
        )

    def test_underhall_rapporterar_dubbletterna(self):
        """hex_underhall() ska namnge tabellen som behöver handpåläggning."""
        rader = _fraga(
            "SELECT atgard FROM public.hex_underhall()"
            " WHERE trigger_namn = 'gid_primarnyckel'"
            "   AND schema_namn = 'sk1_kba_gidmig' AND tabell_namn = 'dubbel'"
        )
        self.assertEqual(rader, [("dubbletter: 1",)])

    def test_reparation_foljd_av_nyckel(self):
        """hex_reparera_gid_dubbletter() ska göra tabellen nyckelbar."""
        self._kor(
            "SELECT * FROM public.hex_reparera_gid_dubbletter("
            "'sk1_kba_gidmig', 'dubbel_rep', true)"
        )
        self.assertEqual(
            self._kor(
                "SELECT public.hex_sakerstall_gid_primarnyckel("
                "'sk1_kba_gidmig', 'dubbel_rep')"
            ),
            [("skapad",)],
        )
        self.assertEqual(
            _fraga(
                "SELECT count(*), count(DISTINCT gid)"
                " FROM sk1_kba_gidmig.dubbel_rep"
            ),
            [(3, 3)],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
