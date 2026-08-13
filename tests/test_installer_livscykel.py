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
import sys
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
    process_sql() tog bort raden med OWNER TO i stället för hela satsen, och
    eftersom de flesta filer skriver satsen över två rader blev det kvar ett
    dinglande ALTER utan avslutning. Installationen dog på första typfilen
    med "syntax error at end of input".
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
