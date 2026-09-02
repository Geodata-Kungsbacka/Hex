#!/usr/bin/env python3
"""
Test: pg_dump och pg_restore mot en Hex-databas.

Sviten kör riktiga pg_dump/pg_restore-anrop och kontrollerar att datat kommer
fram. Den finns för att felvägarna här är tysta: en återläsning kan ge
avslutskod 1 – eller 0 – och lämna en tabell som har rätt kolumner, rätt index,
rätt triggers och noll rader.

Fem saker bevakas:

1. `search_path` är låst på geometrikedjan. Utan låsningen slås ST_IsValid upp
   via anroparens search_path, och pg_restore kör med search_path = ''. Då
   faller CHECK-villkoret validera_geom_<tabell> på varje rad och COPY avbryts
   för hela tabellen. Test 2 är det som faktiskt fångar regressionen; test 1
   pekar bara ut orsaken snabbare när test 2 går sönder.
2. Full återläsning till en tom databas ger noll fel och komplett data. Det är
   fallet docs/12 markerar som riskfritt, och påståendet håller bara så länge
   punkt 1 gör det.
3. Delvis återläsning (`-n <schema>`) mot en levande Hex-databas ger noll fel
   när målschemat droppas inuti pausen.
4. Samma återläsning UTAN att målschemat droppats lägger inte till dumpens
   rader ovanpå de befintliga. PRIMARY KEY (gid) ska stoppa det. Före
   gid-nyckeln gick en tabell tyst från 20 till 40 rader.
5. Historiktabellerna (`_h`) saknar den nyckeln och dubbleras alltså ändå.
   Det är en känd lucka, och test 5 spikar fast den så att den är mätt i
   stället för upptäckt i drift.
6. En full återläsning med `--no-owner` lämnar public.hex_* ägda av postgres,
   och varken hex_ateruppta() eller hex_underhall() lägger tillbaka det.
   Reparationen är install_hex.py --upgrade. Test 6 mäter båda halvorna.

Sviten skapar och droppar egna engångsdatabaser och rör aldrig den vanliga
testdatabasen. Saknas pg_dump/pg_restore, eller går det inte att ansluta som
superuser, hoppas hela sviten över.

Anslutning styrs med libpq:s standardvariabler (PGHOST, PGUSER, PGPASSWORD,
PGPORT). PGDATABASE används INTE.

Kör med:
    PGHOST=localhost PGUSER=postgres PGPASSWORD=... python3 tests/test_dump_restore.py
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

try:
    import psycopg2
except ImportError:  # pragma: no cover
    psycopg2 = None

import install_hex  # noqa: E402

KALLDB = "hex_test_dump_kalla"
MALDB = "hex_test_dump_mal"
AGARROLL = "hex_dump_agare"
SCHEMA = "sk1_kba_dumprestore"

#: Radantal per tabell i källschemat. punkter_p får en riktig rad så att Hex
#: dummy-geometri hinner städas bort av hex_ta_bort_dummy – annars vore det
#: dummy-raden testet räknade.
FORVANTAT = {
    "vagar_l": 50,
    "punkter_p": 3,
    "referens": 20,
}

#: Rollerna Hex skapar för schemat. De är kluster-globala och måste städas
#: bort i tearDownModule; de försvinner inte med databasen.
ROLLER = (
    f"r_{SCHEMA}",
    f"w_{SCHEMA}",
    f"gs_r_{SCHEMA}",
    f"gs_w_{SCHEMA}",
)


def _admin_params():
    """Anslutningsparametrar mot underhållsdatabasen postgres."""
    return {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": int(os.environ.get("PGPORT", 5432)),
        "user": os.environ.get("PGUSER", "postgres"),
        "dbname": "postgres",
        **({"password": os.environ["PGPASSWORD"]} if "PGPASSWORD" in os.environ else {}),
    }


def _db_config(dbname):
    cfg = _admin_params()
    cfg["dbname"] = dbname
    cfg["owner_role"] = AGARROLL
    return cfg


def _har_verktygen():
    return shutil.which("pg_dump") is not None and shutil.which("pg_restore") is not None


def _kan_ansluta():
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


KAN_KORA = _kan_ansluta() and _har_verktygen()


def _admin_exec(*satser):
    conn = psycopg2.connect(**_admin_params())
    conn.autocommit = True
    try:
        cur = conn.cursor()
        for sats in satser:
            cur.execute(sats)
    finally:
        conn.close()


def _skapa_tom_databas(dbname):
    _ta_bort_databas(dbname)
    _admin_exec(f'CREATE DATABASE "{dbname}"')


def _ta_bort_databas(dbname):
    _admin_exec(f'DROP DATABASE IF EXISTS "{dbname}" WITH (FORCE)')


def _koppla(dbname):
    params = {k: v for k, v in _db_config(dbname).items() if k != "owner_role"}
    conn = psycopg2.connect(**params)
    conn.set_client_encoding("UTF8")
    conn.autocommit = True
    return conn


def _kor(dbname, *satser):
    conn = _koppla(dbname)
    try:
        cur = conn.cursor()
        for sats in satser:
            cur.execute(sats)
    finally:
        conn.close()


def _fraga(dbname, sql):
    conn = _koppla(dbname)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        return cur.fetchall()
    finally:
        conn.close()


def _radantal(dbname):
    """
    Exakt radantal per tabell i SCHEMA.

    n_live_tup i pg_stat_user_tables duger inte: den är en uppskattning som
    inte uppdateras förrän ANALYZE körts, och skulle göra testet flackt.
    """
    rader = _fraga(
        dbname,
        "SELECT table_name,"
        " (xpath('/row/c/text()', query_to_xml("
        "     format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),"
        "     false, true, '')))[1]::text::bigint"
        " FROM information_schema.tables"
        f" WHERE table_schema = '{SCHEMA}' AND table_type = 'BASE TABLE'",
    )
    return {namn: antal for namn, antal in rader}


def _agarfordelning(dbname):
    """Antal public.hex_*-funktioner per ägare."""
    rader = _fraga(
        dbname,
        "SELECT pg_get_userbyid(proowner), count(*)"
        " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
        " WHERE n.nspname = 'public' AND proname LIKE 'hex\\_%'"
        " GROUP BY 1",
    )
    return {agare: antal for agare, antal in rader}


def _verktygsmiljo():
    """Miljö för pg_dump/pg_restore, byggd ur samma variabler som psycopg2."""
    env = dict(os.environ)
    p = _admin_params()
    env["PGHOST"] = str(p["host"])
    env["PGPORT"] = str(p["port"])
    env["PGUSER"] = str(p["user"])
    if "password" in p:
        env["PGPASSWORD"] = p["password"]
    return env


def _pg_dump(dbname, malfil, *extra):
    subprocess.run(
        ["pg_dump", "-Fc", "-f", str(malfil), *extra, dbname],
        env=_verktygsmiljo(), check=True, capture_output=True, text=True,
    )


def _pg_restore(dbname, dumpfil, *extra):
    """Kör pg_restore och returnerar (avslutskod, antal fel, stderr)."""
    r = subprocess.run(
        ["pg_restore", "-d", dbname, "--no-owner", "--no-privileges",
         *extra, str(dumpfil)],
        env=_verktygsmiljo(), capture_output=True, text=True,
    )
    antal_fel = sum(1 for rad in r.stderr.splitlines()
                    if rad.startswith("pg_restore: error"))
    return r.returncode, antal_fel, r.stderr


def _felrader(stderr, maxrader=8):
    """
    Bara felraderna ur pg_restore:s stderr.

    pg_restore ekar hela den misslyckade satsen efter varje fel, så rå stderr
    blir tiotusentals tecken och gör ett misslyckat test oläsbart.
    """
    rader = [r for r in stderr.splitlines() if r.startswith("pg_restore: error")]
    if len(rader) > maxrader:
        rader = rader[:maxrader] + [f"... ({len(rader) - maxrader} fel till)"]
    return "\n".join(rader)


def _pausa(dbname, anledning):
    _kor(dbname, f"SELECT count(*) FROM public.hex_pausa({anledning!r}, 1)")


def _ateruppta(dbname):
    _kor(dbname, "SELECT count(*) FROM public.hex_ateruppta()")


def tearDownModule():
    if not KAN_KORA:
        return
    try:
        _ta_bort_databas(KALLDB)
        _ta_bort_databas(MALDB)
        for roll in ROLLER + (AGARROLL,):
            # DROP OWNED krävs för default-rättigheter och databasbehörigheter
            # som annars håller kvar rollen. Databaserna är redan borta, så
            # ägandet som återstår är kluster-globalt.
            _admin_exec(f'DROP ROLE IF EXISTS "{roll}"')
    except Exception as e:  # pragma: no cover
        print(f"VARNING: kunde inte städa: {e}", file=sys.stderr)


@unittest.skipUnless(KAN_KORA, "kräver superuser samt pg_dump/pg_restore i PATH")
class TestDumpOchAterlasning(unittest.TestCase):
    """
    En källdatabas med Hex och ett schema med både geometri och ren tabelldata.
    Två dumpar tas en gång: hela databasen och bara schemat.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.full_dump = Path(cls.tmp.name) / "full.dump"
        cls.schema_dump = Path(cls.tmp.name) / "schema.dump"

        _skapa_tom_databas(KALLDB)
        with contextlib.redirect_stdout(io.StringIO()):
            install_hex.install(_db_config(KALLDB), base_path=str(PROJECT_ROOT))
        cls._bygg_schema(KALLDB)

        _pg_dump(KALLDB, cls.full_dump)
        _pg_dump(KALLDB, cls.schema_dump, "-n", SCHEMA)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @staticmethod
    def _bygg_schema(dbname):
        """Skapar schemat och fyller det. Hex strukturerar om tabellerna."""
        _kor(
            dbname,
            f"CREATE SCHEMA {SCHEMA}",
            f"CREATE TABLE {SCHEMA}.vagar_l ("
            " namn text, klass integer, geom geometry(MultiLineString, 3007))",
            f"CREATE TABLE {SCHEMA}.punkter_p ("
            " etikett text, geom geometry(Point, 3007))",
            f"CREATE TABLE {SCHEMA}.referens (kod text, text_varde text)",
            f"INSERT INTO {SCHEMA}.vagar_l (namn, klass, geom)"
            " SELECT 'vag_' || i, i,"
            " ST_Multi(ST_SetSRID(ST_MakeLine(ST_MakePoint(i, i),"
            "                                 ST_MakePoint(i + 1, i + 1)), 3007))"
            "     ::geometry(MultiLineString, 3007)"
            f" FROM generate_series(1, {FORVANTAT['vagar_l']}) i",
            f"INSERT INTO {SCHEMA}.punkter_p (etikett, geom)"
            " SELECT 'p' || i, ST_SetSRID(ST_MakePoint(i, i), 3007)"
            f" FROM generate_series(1, {FORVANTAT['punkter_p']}) i",
            f"INSERT INTO {SCHEMA}.referens (kod, text_varde)"
            " SELECT 'k' || i, 'v' || i"
            f" FROM generate_series(1, {FORVANTAT['referens']}) i",
        )

    def _kontrollera_radantal(self, dbname, meddelande):
        faktiskt = _radantal(dbname)
        for tabell, antal in FORVANTAT.items():
            self.assertIn(tabell, faktiskt, f"{meddelande}: {tabell} saknas helt")
            self.assertEqual(
                antal, faktiskt[tabell],
                f"{meddelande}: {tabell} har {faktiskt[tabell]} rader,"
                f" förväntat {antal}",
            )

    # ------------------------------------------------------------------
    # 1. search_path-låsningen
    # ------------------------------------------------------------------

    def test_1_geometrikedjan_har_last_search_path(self):
        """
        Utan låsningen slås ST_IsValid upp via anroparens search_path.
        pg_restore kör med search_path = '', och då tömmer varje återläsning
        alla _kba_-tabeller med geometri. Se docs/12.
        """
        rader = _fraga(
            KALLDB,
            "SELECT proname, proconfig FROM pg_proc p"
            " JOIN pg_namespace n ON n.oid = p.pronamespace"
            " WHERE n.nspname = 'public' AND proname IN ("
            "   'hex_validera_geometri',"
            "   'hex_forklara_geometrifel',"
            "   'hex_kontrollera_geometri_trigger')",
        )
        self.assertEqual(3, len(rader), "en av geometrifunktionerna saknas")
        for proname, proconfig in rader:
            self.assertIsNotNone(
                proconfig, f"{proname} saknar SET search_path")
            self.assertIn(
                "search_path=public, pg_temp", proconfig,
                f"{proname} har oväntad search_path: {proconfig}")

    # ------------------------------------------------------------------
    # 2. Full återläsning till en tom databas
    # ------------------------------------------------------------------

    def test_2_full_aterlasning_till_tom_databas(self):
        """
        Hex är inte igång under körningen – event-triggarna ligger sist i
        dumpen – så ingen paus behövs. Men COPY går ändå genom
        CHECK-villkoret validera_geom_<tabell>, och det är där en saknad
        search_path-låsning slår till.
        """
        _skapa_tom_databas(MALDB)
        kod, fel, stderr = _pg_restore(MALDB, self.full_dump)

        self.assertEqual(
            0, fel,
            "full återläsning till tom databas ska ge noll fel.\n"
            + _felrader(stderr),
        )
        self.assertEqual(0, kod, "pg_restore ska avsluta med 0")
        self._kontrollera_radantal(MALDB, "full återläsning")

    # ------------------------------------------------------------------
    # 3. Delvis återläsning, målschemat droppat inuti pausen
    # ------------------------------------------------------------------

    def test_3_delvis_aterlasning_med_drop_inuti_pausen(self):
        """
        Rätt ordning enligt docs/12: pausa, droppa målschemat, läs in,
        återuppta. DROP SCHEMA inuti pausen lämnar rollerna i fred – utanför
        pausen hade hex_ta_bort_schemaroller() tagit dem.
        """
        _pausa(KALLDB, "test_3")
        try:
            _kor(KALLDB, f"DROP SCHEMA {SCHEMA} CASCADE")
            kod, fel, stderr = _pg_restore(
                KALLDB, self.schema_dump, "--exit-on-error")
        finally:
            _ateruppta(KALLDB)

        self.assertEqual(
            0, fel,
            "delvis återläsning med droppat målschema ska ge noll fel.\n"
            + _felrader(stderr),
        )
        self.assertEqual(0, kod)
        self._kontrollera_radantal(KALLDB, "delvis återläsning")

        kvar = {r[0] for r in _fraga(
            KALLDB,
            "SELECT rolname FROM pg_roles WHERE rolname IN "
            "(" + ", ".join(repr(r) for r in ROLLER) + ")",
        )}
        self.assertEqual(
            set(ROLLER), kvar,
            "DROP SCHEMA inuti pausen ska lämna rollerna orörda")

    # ------------------------------------------------------------------
    # 4. Delvis återläsning ovanpå ett schema som står kvar
    # ------------------------------------------------------------------

    def test_4_aterlasning_ovanpa_befintligt_schema_dubblerar_inte(self):
        """
        Fel arbetsgång, med flit: pausa men låt målschemat stå kvar.
        Återläsningen ska bråka, inte lyckas tyst. Det är PRIMARY KEY (gid)
        som gör skillnaden – utan den lades dumpens rader till ovanpå de
        befintliga och referens gick från 20 till 40 rader utan ett enda
        felmeddelande.
        """
        fore = _radantal(KALLDB)

        _pausa(KALLDB, "test_4")
        try:
            kod, fel, stderr = _pg_restore(KALLDB, self.schema_dump)
        finally:
            _ateruppta(KALLDB)

        self.assertGreater(
            fel, 0,
            "återläsning ovanpå ett befintligt schema ska ge fel, inte tystnad")
        self.assertEqual(1, kod, "pg_restore ska avsluta med 1 när fel ignorerats")
        # Sök i hela stderr, men skriv bara ut felraderna vid miss.
        self.assertIn(
            "duplicate key value", stderr,
            "PRIMARY KEY (gid) ska stoppa dumpens rader från att läggas till"
            " ovanpå de befintliga.\n" + _felrader(stderr))

        efter = _radantal(KALLDB)
        for tabell in FORVANTAT:
            self.assertEqual(
                fore[tabell], efter[tabell],
                f"{tabell} växte från {fore[tabell]} till {efter[tabell]}:"
                " dumpens rader lades till ovanpå de befintliga")

    def test_5_historiktabeller_dubbleras_utan_att_klaga(self):
        """
        Känd lucka, avsiktligt fastspikad här.

        `_h`-tabellerna har ingen primärnyckel – samma gid förekommer med flit
        i flera versioner, och (gid, h_tidpunkt) duger inte som nyckel eftersom
        två ändringar i samma transaktion delar h_tidpunkt. Skyddet som räddar
        modertabellerna i test 4 finns alltså inte här: en återläsning ovanpå
        ett befintligt schema LÄGGER TILL historikrader utan att någonting
        klagar.

        Testet finns för att luckan ska vara mätt och synlig i stället för
        upptäckt i drift. Går det sönder därför att historiken plötsligt ÄR
        skyddad, är det en förbättring – ta då bort testet och stryk
        motsvarande punkt i docs/12.
        """
        historiktabeller = [t for t in _radantal(KALLDB) if t.endswith("_h")]
        self.assertTrue(historiktabeller, "inga historiktabeller att mäta")

        fore = _radantal(KALLDB)

        _pausa(KALLDB, "test_5")
        try:
            _pg_restore(KALLDB, self.schema_dump)
        finally:
            _ateruppta(KALLDB)

        efter = _radantal(KALLDB)

        # Minst en historiktabell med rader i ska ha vuxit. Tomma _h-tabeller
        # kan inte visa något, så de räknas bort.
        hade_rader = [t for t in historiktabeller if fore[t] > 0]
        self.assertTrue(
            hade_rader,
            "ingen historiktabell hade rader – testet mäter ingenting")
        self.assertTrue(
            any(efter[t] > fore[t] for t in hade_rader),
            "historiken förväntas dubbleras här. Är den nu skyddad?"
            f" före={ {t: fore[t] for t in hade_rader} }"
            f" efter={ {t: efter[t] for t in hade_rader} }")


    # ------------------------------------------------------------------
    # 6. Ägarskapet på Hex egna funktioner
    # ------------------------------------------------------------------

    def test_6_no_owner_tar_agarskapet_och_upgrade_lagger_tillbaka_det(self):
        """
        `--no-owner` skapar om alla public.hex_* med postgres som ägare.
        hex_underhall() rör dem inte – det sätter ägarskap på objekten i
        Hex-schemana, inte på funktionskatalogen i public. Följden är att
        hex_tillampa_grupprattigheter inte längre kan GRANT:a Hex-rollerna.

        Testet mäter båda halvorna: att skadan uppstår, och att
        install_hex.py --upgrade är det som reparerar den. Se docs/12.
        """
        _skapa_tom_databas(MALDB)
        _pg_restore(MALDB, self.full_dump)

        agare_efter_restore = _agarfordelning(MALDB)
        self.assertEqual(
            0, agare_efter_restore.get(AGARROLL, 0),
            "--no-owner förväntas ta ägarskapet på samtliga public.hex_*."
            f" Fördelning: {agare_efter_restore}")

        # hex_underhall() är uttryckligen INTE reparationen här.
        _kor(MALDB, "SELECT count(*) FROM public.hex_underhall()")
        self.assertEqual(
            0, _agarfordelning(MALDB).get(AGARROLL, 0),
            "hex_underhall() ska inte påstå sig reparera ägarskapet i public."
            " Gör den det nu är det en förbättring – uppdatera docs/12.")

        with contextlib.redirect_stdout(io.StringIO()):
            install_hex.upgrade(_db_config(MALDB), base_path=str(PROJECT_ROOT))

        efter_upgrade = _agarfordelning(MALDB)
        self.assertGreater(
            efter_upgrade.get(AGARROLL, 0), 0,
            f"--upgrade ska lägga tillbaka ägarskapet. Fördelning: {efter_upgrade}")
        self.assertEqual(
            _agarfordelning(KALLDB), efter_upgrade,
            "efter --upgrade ska fördelningen matcha en normalt installerad databas")


if __name__ == "__main__":
    unittest.main(verbosity=2)
