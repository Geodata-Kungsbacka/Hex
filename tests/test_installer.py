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

import re
import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
