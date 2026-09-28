#!/usr/bin/env python3
"""
Test: install_hex.py – installationsordning och ägarskapskonventioner.

Sviten kräver ingen databas. Den testar konsistensen i INSTALL_ORDER mot
filerna på disk, och att SQL-filerna följer repots ägarskapskonvention.

Bakgrund: installern kör SQL-filerna precis som de står. Ägarskapet sätts
därför i SQL:en, dynamiskt mot hex_systemagare(), så att manuell installation
och install_hex.py ger samma ägare. Undantaget är superuser-beroende filer
(event-triggers och deras triggerfunktioner) som måste ägas av postgres och
sätter det statiskt. Bryts den uppdelningen hamnar ägarskapet fel utan att
installationen klagar.

Kör med:
    python3 tests/test_installer.py
"""

import io
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import DEFAULT, patch

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

import install_hex  # noqa: E402

# Ett statiskt rollnamn i en ägarskapssats: OWNER TO gis_admin.
# Dynamiska satser skriver OWNER TO %I och matchas alltså inte.
OWNER_TO = re.compile(r"OWNER\s+TO\s+(\w+)", re.IGNORECASE)

# Toppnivåobjekt vars ägarskap måste sättas explicit.
SKAPAR_OBJEKT = re.compile(
    r"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|TABLE|TYPE|VIEW)\b",
    re.IGNORECASE | re.MULTILINE,
)

# En dynamisk ägarskapssats, dvs. OWNER TO följt av en format()-specifierare.
DYNAMISK_AGARE = re.compile(r"OWNER\s+TO\s+%(\w)", re.IGNORECASE)


def _strip_sql_comments(sql: str) -> str:
    """Returnerar SQL:en med blockkommentarer (/* */) och radkommentarer (--) borttagna.

    Används enbart för klassificering – aldrig för SQL som faktiskt körs.
    """
    utan_block = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", " ", utan_block)


def kraver_superuser_agande(sql: str) -> bool:
    """Anger om filens objekt måste ägas av postgres i stället för ägarrollen.

    Undantaget gäller event-triggers och de SECURITY DEFINER-funktioner som ÄR
    triggerfunktioner (RETURNS event_trigger). De skapar roller och flyttar
    ägarskap och behöver därför superuser.

    SECURITY DEFINER ensamt räcker inte som kriterium. En vanlig SECURITY
    DEFINER-funktion ska köra som ägarrollen, inte som postgres: den ska ha
    exakt de rättigheter ägarrollen har (t.ex. ADMIN OPTION på schemarollerna)
    och inte mer.
    """
    # Klassificeringen görs på SQL:en utan kommentarer – annars räcker det att
    # frasen nämns i en kommentar för att filen felaktigt ska klassas som
    # superuser-beroende.
    kod = _strip_sql_comments(sql).upper()
    ar_triggerfunktion = re.search(r"RETURNS\s+EVENT_TRIGGER", kod) is not None
    return ("CREATE EVENT TRIGGER" in kod
            or ("SECURITY DEFINER" in kod and ar_triggerfunktion))


# ---------------------------------------------------------------------------
# 1. INSTALL_ORDER mot filerna på disk
# ---------------------------------------------------------------------------
class TestInstallOrder(unittest.TestCase):

    def test_alla_filer_finns(self):
        """Varje post i INSTALL_ORDER ska peka på en fil som finns."""
        saknade = [
            f for f in install_hex.INSTALL_ORDER
            if not (PROJECT_ROOT / f).exists()
        ]
        self.assertEqual(saknade, [], f"Saknade SQL-filer: {saknade}")

    def test_inga_dubbletter(self):
        """Samma fil ska inte installeras två gånger."""
        dubbletter = {
            f for f in install_hex.INSTALL_ORDER
            if install_hex.INSTALL_ORDER.count(f) > 1
        }
        self.assertEqual(dubbletter, set(), f"Dubbletter: {dubbletter}")

    def test_alla_sql_filer_installeras(self):
        """
        Varje .sql-fil under src/sql/ ska installeras.

        Undantag: hex_systemagare.sql genereras dynamiskt av installern
        från owner_role och ingår därför inte i INSTALL_ORDER.
        """
        undantag = {"src/sql/00_config/hex_systemagare.sql"}
        pa_disk = {
            str(p.relative_to(PROJECT_ROOT))
            for p in (PROJECT_ROOT / "src" / "sql").rglob("*.sql")
        }
        oinstallerade = pa_disk - set(install_hex.INSTALL_ORDER) - undantag
        self.assertEqual(
            oinstallerade, set(),
            f"SQL-filer som aldrig installeras: {sorted(oinstallerade)}"
        )


# ---------------------------------------------------------------------------
# 2. Klassificering av superuser-beroende filer
# ---------------------------------------------------------------------------
class TestKraverSuperuserAgande(unittest.TestCase):
    """
    Klassificeringen avgör vilka filer som får äga statiskt till postgres.

    Klassas en fil fel åt ena hållet hamnar en vanlig funktion på postgres i
    stället för ägarrollen; åt andra hållet får en event-triggerfunktion en
    ägare utan de rättigheter den behöver.
    """

    def test_event_trigger_kraver_superuser(self):
        sql = (
            "CREATE EVENT TRIGGER hex_exempel_trigger ON ddl_command_end\n"
            "    EXECUTE FUNCTION public.hex_exempel();\n"
        )
        self.assertTrue(kraver_superuser_agande(sql))

    def test_security_definer_triggerfunktion_kraver_superuser(self):
        sql = (
            "CREATE OR REPLACE FUNCTION public.hex_sd_trigger()\n"
            "    RETURNS event_trigger\n"
            "    LANGUAGE 'plpgsql'\n"
            "    SECURITY DEFINER\n"
            "    SET search_path = public, pg_temp\n"
            "AS $BODY$ BEGIN END; $BODY$;\n"
        )
        self.assertTrue(kraver_superuser_agande(sql))

    def test_security_definer_nyttofunktion_kraver_inte_superuser(self):
        """
        En vanlig SECURITY DEFINER-funktion ska köra som ägarrollen.

        Den ska ha exakt ägarrollens rättigheter – inte superuserns.
        """
        sql = (
            "CREATE OR REPLACE FUNCTION public.hex_sd()\n"
            "    RETURNS void\n"
            "    LANGUAGE 'plpgsql'\n"
            "    SECURITY DEFINER\n"
            "    SET search_path = public, pg_temp\n"
            "AS $BODY$ BEGIN END; $BODY$;\n"
        )
        self.assertFalse(kraver_superuser_agande(sql))

    def test_fras_i_kommentar_utloser_inte_undantag(self):
        """'SECURITY DEFINER' i en kommentar ska inte klassa om filen."""
        sql = (
            "-- Den här funktionen är medvetet INTE SECURITY DEFINER.\n"
            "/* CREATE EVENT TRIGGER nämns bara här. */\n"
            "CREATE OR REPLACE FUNCTION public.hex_x() RETURNS void\n"
            "    LANGUAGE 'plpgsql'\nAS $BODY$ BEGIN END; $BODY$;\n"
        )
        self.assertFalse(kraver_superuser_agande(sql))


# ---------------------------------------------------------------------------
# 3. Ägarskapskonventionen i SQL-filerna
# ---------------------------------------------------------------------------
class TestAgarskapskonvention(unittest.TestCase):
    """
    Installern kör filerna precis som de står, så ägarskapet måste vara rätt
    redan i SQL:en. Ett hårdkodat rollnamn ger fel ägare — eller avbryter
    installationen om rollen inte finns i klustret.
    """

    def test_agarskap_satts_via_hex_systemagare(self):
        """
        Ingen installerad fil får hårdkoda ett rollnamn i sitt ägarskap.

        Undantaget är de superuser-beroende filerna: de måste ägas av postgres
        och sätter det statiskt.
        """
        avvikande = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            kod = _strip_sql_comments(sql)
            statiska = OWNER_TO.findall(kod)

            if kraver_superuser_agande(sql):
                for agare in statiska:
                    if agare.lower() != "postgres":
                        avvikande.append(
                            f"{f}: superuser-beroende fil äger till {agare}, "
                            "ska vara postgres"
                        )
                continue

            for agare in statiska:
                avvikande.append(
                    f"{f}: hårdkodat OWNER TO {agare}, ska sättas via "
                    "public.hex_systemagare()"
                )
            # En fil som skapar ett objekt utan att sätta ägarskap alls får
            # ägaren av den som råkar köra filen. Det ger fel ägare i båda
            # installationsvägarna, utan att någon OWNER TO-sats avslöjar det.
            if SKAPAR_OBJEKT.search(kod) and not re.search(
                r"OWNER\s+TO", kod, re.IGNORECASE
            ):
                avvikande.append(
                    f"{f}: skapar objekt utan ägarskapssats – objektet hamnar "
                    "på den anslutande användaren i stället för ägarrollen"
                )

        self.assertEqual(
            avvikande, [],
            "Ägarskap som inte följer ägarrollen vid installation:\n  "
            + "\n  ".join(avvikande),
        )

    def test_dynamiskt_agarskap_citerar_rollnamnet(self):
        """
        Dynamiska ägarskapssatser ska använda %I, aldrig %s.

        %s klistrar in rollnamnet ociterat. Ett namn som kräver citattecken
        ger då syntaxfel, och innehållet i hex_systemagare() körs som SQL i
        stället för att behandlas som en identifierare.
        """
        avvikande = []
        for f in install_hex.INSTALL_ORDER:
            kod = _strip_sql_comments(
                (PROJECT_ROOT / f).read_text(encoding="utf-8")
            )
            for spec in DYNAMISK_AGARE.findall(kod):
                if spec != "I":
                    avvikande.append(f"{f}: OWNER TO %{spec}, ska vara %I")

        self.assertEqual(
            avvikande, [],
            "Dynamiska ägarskapssatser med fel format()-specifierare:\n  "
            + "\n  ".join(avvikande),
        )

    def test_dynamiskt_agarskap_gar_via_hex_systemagare(self):
        """
        Varje icke-superuser-fil som sätter ägarskap ska hämta rollen från
        hex_systemagare(), inte från något annat uttryck (t.ex. current_user).

        hex_systemagare() är den enda platsen ägarrollen konfigureras. Går en
        fil förbi den hamnar objektet på en annan roll än resten av Hex.
        """
        avvikande = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            if kraver_superuser_agande(sql):
                continue
            kod = _strip_sql_comments(sql)
            if not DYNAMISK_AGARE.search(kod):
                continue
            if "hex_systemagare()" not in kod:
                avvikande.append(
                    f"{f}: dynamiskt ägarskap utan public.hex_systemagare()"
                )

        self.assertEqual(
            avvikande, [],
            "Filer som sätter ägarskap utan hex_systemagare():\n  "
            + "\n  ".join(avvikande),
        )


# ---------------------------------------------------------------------------
# 4. Hjälpfunktionen bakom klassificeringen
# ---------------------------------------------------------------------------
class TestStripSqlComments(unittest.TestCase):
    """
    Kommentarstrippningen är det som gör klassificeringen ovan tillförlitlig.
    Slutar den fungera slutar också ägarskapskontrollerna att fånga något.
    """

    def test_tar_bort_radkommentar(self):
        self.assertNotIn(
            "SECURITY", _strip_sql_comments("-- SECURITY DEFINER\nSELECT 1;")
        )

    def test_tar_bort_blockkommentar(self):
        self.assertNotIn(
            "SECURITY", _strip_sql_comments("/* SECURITY DEFINER */\nSELECT 1;")
        )

    def test_behaller_kod(self):
        self.assertIn("SELECT 1", _strip_sql_comments("-- x\nSELECT 1;"))


# ---------------------------------------------------------------------------
# 5. Dokumentationen mot installerns egna listor
# ---------------------------------------------------------------------------
def _sql_block(md_fil: str, efter_rubrik: str) -> str:
    """Plockar ut det första ```sql-blocket efter en rubrik i en markdown-fil."""
    text = (PROJECT_ROOT / md_fil).read_text(encoding="utf-8")
    start = text.index(efter_rubrik)
    traff = re.search(r"```sql\n(.*?)```", text[start:], re.DOTALL)
    if traff is None:
        raise AssertionError(f"Hittade inget sql-block efter {efter_rubrik!r} i {md_fil}")
    return traff.group(1)


def _drop_satser(sql: str) -> list:
    """Returnerar DROP-satserna i sql, normaliserade till en rad var.

    Kommentarer strippas först, och whitespace normaliseras, så att jämförelsen
    gäller satserna och inte formateringen.
    """
    kod = _strip_sql_comments(sql)
    return [
        " ".join(sats.split())
        for sats in re.findall(r"DROP\s+.*?;", kod, re.DOTALL | re.IGNORECASE)
    ]


class TestDokumenteradAvinstallation(unittest.TestCase):
    """
    docs/10 dokumenterar samma DROP-block som UNINSTALL_SQL kör.

    Blocket är en handkopia, och en kopia driver isär: en ny tabell eller
    funktion läggs till i UNINSTALL_SQL men glöms i dokumentationen. Följden är
    tyst — en DBA som följer dokumentationen tror att Hex är borta, men
    event-triggern som blev kvar fortsätter blockera DDL. Det här testet är
    vakten mot det.
    """

    RUBRIK = "## Metod 2"

    def setUp(self):
        self.dokumenterade = _drop_satser(_sql_block("docs/10_avinstallera-hex.md", self.RUBRIK))
        self.faktiska = _drop_satser(install_hex.UNINSTALL_SQL)

    def test_dokumentationen_saknar_inget(self):
        saknas = [s for s in self.faktiska if s not in self.dokumenterade]
        self.assertEqual(
            saknas, [],
            "DROP-satser i UNINSTALL_SQL som saknas i docs/10: " + repr(saknas),
        )

    def test_dokumentationen_har_inget_extra(self):
        extra = [s for s in self.dokumenterade if s not in self.faktiska]
        self.assertEqual(
            extra, [],
            "DROP-satser i docs/10 som inte finns i UNINSTALL_SQL: " + repr(extra),
        )

    def test_samma_ordning(self):
        """Ordningen är en beroendeordning – event-triggers före funktioner, typer sist."""
        self.assertEqual(self.dokumenterade, self.faktiska)

    def test_readme_duplicerar_inte_blocket(self):
        """
        README ska hänvisa till docs/10, inte upprepa blocket.

        En andra kopia är precis det som en gång lämnade README:s block bakom
        med en aktiv event-trigger och tio funktioner kvar i databasen.
        """
        readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")
        avsnitt = readme[readme.index("### Manuell avinstallation"):]
        avsnitt = avsnitt[:avsnitt.index("## Licens")]
        self.assertNotIn(
            "DROP EVENT TRIGGER", avsnitt,
            "README upprepar avinstallationsblocket – hänvisa till docs/10 i stället.",
        )


class TestDokumenteradInstallationsordning(unittest.TestCase):
    """
    README:s "Detaljerad installationsordning" ska spegla INSTALL_ORDER.

    README säger själv att de två måste ändras likadant. Utan ett test är det
    en uppmaning, inte en garanti — och en manuell installation som följer en
    inaktuell ordning faller på en beroende som inte finns än.
    """

    UNDANTAG = ["src/sql/00_config/hex_systemagare.sql"]

    def _dokumenterad_ordning(self):
        block = _sql_block("README.md", "### Detaljerad installationsordning")
        return [
            rad.strip() for rad in block.splitlines()
            if rad.strip().endswith(".sql")
        ]

    def test_samma_filer_i_samma_ordning(self):
        dokumenterad = self._dokumenterad_ordning()
        forvantad = self.UNDANTAG + list(install_hex.INSTALL_ORDER)
        self.assertEqual(
            dokumenterad, forvantad,
            "README:s installationsordning stämmer inte med INSTALL_ORDER.",
        )

    def test_hex_systemagare_star_forst(self):
        """Filen installern inte kör måste stå först – allt annat sätter ägarskap mot den."""
        self.assertEqual(self._dokumenterad_ordning()[0], self.UNDANTAG[0])


# ---------------------------------------------------------------------------
# 6. Kommandoraden
# ---------------------------------------------------------------------------
class TestKommandorad(unittest.TestCase):
    """
    install_hex.main() – flaggor, loopen över databaser, sammanfattning, exitkod.

    All dokumentation säger åt användaren att köra `python install_hex.py`
    med flaggor, men testerna anropar install()/upgrade()/uninstall() som
    funktioner. Skalet runt dem — det som avgör vilken åtgärd som körs, att en
    databas som misslyckas inte stoppar de övriga, och att skriptet avslutar
    med felkod 1 — var därför otestat trots att det är det dokumenterade
    gränssnittet.
    """

    EN_DB = [{"host": "h1", "dbname": "db1", "owner_role": None}]
    TVA_DB = [
        {"host": "h1", "dbname": "db1", "owner_role": None},
        {"host": "h2", "dbname": "db2", "owner_role": None},
    ]

    def _kor(self, argv, databases, **biverkningar):
        """Kör main() med install/upgrade/uninstall mockade.

        biverkningar: side_effect per åtgärdsnamn, för att simulera fel.
        Returnerar (exitkod, utskrift, mockar).
        """
        mockar = {}
        with patch.multiple(
            install_hex,
            install=DEFAULT,
            upgrade=DEFAULT,
            uninstall=DEFAULT,
        ) as m:
            mockar = m
            for namn, effekt in biverkningar.items():
                mockar[namn].side_effect = effekt
            buf = io.StringIO()
            with redirect_stdout(buf):
                kod = install_hex.main(argv, databases=databases)
        return kod, buf.getvalue(), mockar

    # -- Val av åtgärd -------------------------------------------------------

    def test_utan_flaggor_installeras(self):
        kod, _, m = self._kor([], self.EN_DB)
        self.assertEqual(kod, 0)
        m["install"].assert_called_once_with(self.EN_DB[0])
        m["upgrade"].assert_not_called()
        m["uninstall"].assert_not_called()

    def test_upgrade_flaggan_uppgraderar(self):
        _, _, m = self._kor(["--upgrade"], self.EN_DB)
        m["upgrade"].assert_called_once_with(self.EN_DB[0])
        m["install"].assert_not_called()

    def test_uninstall_flaggan_avinstallerar(self):
        _, _, m = self._kor(["--uninstall"], self.EN_DB)
        m["uninstall"].assert_called_once_with(self.EN_DB[0])
        m["install"].assert_not_called()

    def test_upgrade_och_uninstall_tillsammans_avvisas(self):
        """
        Regression: --uninstall prövades först och vann tyst över --upgrade,
        så kombinationen avinstallerade utan att uppgradera – och utan att
        säga det. Nu är flaggorna ömsesidigt uteslutande.
        """
        with self.assertRaises(SystemExit) as cm, redirect_stdout(io.StringIO()):
            with patch.object(sys, "stderr", io.StringIO()):
                install_hex.main(["--upgrade", "--uninstall"], databases=self.EN_DB)
        self.assertEqual(cm.exception.code, 2)

    # -- Flera databaser -----------------------------------------------------

    def test_alla_databaser_bearbetas(self):
        _, _, m = self._kor([], self.TVA_DB)
        self.assertEqual(m["install"].call_count, 2)

    def test_en_misslyckad_databas_stoppar_inte_de_ovriga(self):
        """docs/09: 'En databas som misslyckas stoppar inte de övriga.'"""
        fel = [RuntimeError("connect nekad"), None]
        kod, utskrift, m = self._kor([], self.TVA_DB, install=fel)
        self.assertEqual(m["install"].call_count, 2)
        self.assertEqual(kod, 1, "felkod 1 när en databas misslyckades")
        self.assertIn("connect nekad", utskrift,
                      "felet måste skrivas ut – annars avslutas installern tyst")

    def test_sammanfattning_redovisar_bada_utfallen(self):
        _, utskrift, _ = self._kor([], self.TVA_DB, install=[RuntimeError("bom"), None])
        self.assertIn("Sammanfattning - Installation", utskrift)
        self.assertIn("OK:       db2@h2", utskrift)
        self.assertIn("MISSLYCKADES: db1@h1", utskrift)
        self.assertIn("1/2 databaser lyckades.", utskrift)

    def test_sammanfattningen_namner_atgarden(self):
        for argv, rubrik in (
            (["--upgrade"], "Sammanfattning - Uppgradering"),
            (["--uninstall"], "Sammanfattning - Avinstallation"),
        ):
            with self.subTest(argv=argv):
                _, utskrift, _ = self._kor(argv, self.TVA_DB)
                self.assertIn(rubrik, utskrift)

    def test_ingen_sammanfattning_for_en_databas(self):
        """Sammanfattningen är till för att skilja databaser åt – med en är den brus."""
        _, utskrift, _ = self._kor([], self.EN_DB)
        self.assertNotIn("Sammanfattning", utskrift)

    def test_exitkod_noll_nar_allt_lyckas(self):
        kod, _, _ = self._kor([], self.TVA_DB)
        self.assertEqual(kod, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
