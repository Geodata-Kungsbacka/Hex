#!/usr/bin/env python3
"""
Test: install_hex.py – ägarskapsomskrivning och installationsordning.

Sviten kräver ingen databas. Den testar installerns rena funktioner
(process_sql, _strip_sql_comments) och konsistensen i INSTALL_ORDER mot
filerna på disk.

Bakgrund: ägarskapet sätts i SQL-filerna via hex_systemagare(), så att
manuell installation och install_hex.py ger samma ägare. Undantaget är
superuser-beroende filer (event-triggers och deras triggerfunktioner) som
måste ägas av postgres och sätter det statiskt. Bryts den uppdelningen
hamnar ägarskapet fel utan att installationen klagar.

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

OWNER_TO = re.compile(r"OWNER\s+TO\s+(\w+)", re.IGNORECASE)

# Toppnivåobjekt vars ägarskap måste sättas explicit.
SKAPAR_OBJEKT = re.compile(
    r"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|TABLE|TYPE|VIEW)\b",
    re.IGNORECASE | re.MULTILINE,
)


# ---------------------------------------------------------------------------
# 1. process_sql – ägarskapsomskrivning
# ---------------------------------------------------------------------------
class TestProcessSqlAgarskap(unittest.TestCase):
    """process_sql ska skriva om OWNER TO till konfigurerad ägarroll."""

    VANLIG_SQL = (
        "CREATE OR REPLACE FUNCTION public.hex_exempel() RETURNS void\n"
        "    LANGUAGE 'plpgsql'\nAS $BODY$ BEGIN END; $BODY$;\n\n"
        "ALTER FUNCTION public.hex_exempel() OWNER TO gis_admin;\n"
    )

    def test_skriver_om_owner_to(self):
        """En vanlig fil ska få OWNER TO satt till owner_role."""
        ut = install_hex.process_sql(self.VANLIG_SQL, "min_agare")
        self.assertIn("OWNER TO min_agare", ut)
        self.assertNotIn("OWNER TO gis_admin", ut)

    def test_tar_bort_owner_to_utan_agarroll(self):
        """owner_role=None ska ta bort ägarskapssatsen helt."""
        ut = install_hex.process_sql(self.VANLIG_SQL, None)
        self.assertNotIn("OWNER TO", ut.upper())

    def test_tar_bort_flerradig_agarskapssats(self):
        """
        En ägarskapssats skriven över flera rader ska tas bort i sin helhet.

        REGRESSION: 49 av filerna skriver satsen som

            ALTER TYPE public.hex_geom_info
                OWNER TO gis_admin;

        En radbaserad filtrering tar bara bort andra raden och lämnar kvar
        ett dinglande 'ALTER TYPE public.hex_geom_info' utan avslutning,
        vilket ger 'syntax error at end of input'.
        """
        sql = (
            "CREATE TYPE public.hex_exempel AS (a int);\n\n"
            "ALTER TYPE public.hex_exempel\n"
            "    OWNER TO gis_admin;\n\n"
            "COMMENT ON TYPE public.hex_exempel IS 'kvar';\n"
        )
        ut = install_hex.process_sql(sql, None)
        self.assertNotIn("OWNER TO", ut.upper())
        self.assertNotIn("ALTER TYPE", ut.upper())
        self.assertIn("CREATE TYPE public.hex_exempel", ut)
        self.assertIn("COMMENT ON TYPE", ut)

    def test_dynamisk_sql_i_funktionskropp_rors_inte(self):
        """
        format('... OWNER TO %I', ...) i en funktionskropp ska lämnas i fred.

        Borttagningen får bara träffa verkliga ägarskapssatser, inte SQL som
        funktionen bygger upp vid körning.
        """
        sql = (
            "CREATE FUNCTION public.hex_x() RETURNS void AS $$\n"
            "BEGIN\n"
            "    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', s, t, r);\n"
            "END $$ LANGUAGE plpgsql;\n"
            "ALTER FUNCTION public.hex_x()\n"
            "    OWNER TO gis_admin;\n"
        )
        ut = install_hex.process_sql(sql, None)
        self.assertIn("format('ALTER TABLE %I.%I OWNER TO %I', s, t, r)", ut)
        self.assertNotIn("ALTER FUNCTION public.hex_x()", ut)

    def test_event_trigger_behaller_postgres(self):
        """Filer med CREATE EVENT TRIGGER ska lämnas orörda."""
        sql = (
            "CREATE EVENT TRIGGER hex_exempel_trigger ON ddl_command_end\n"
            "    EXECUTE PROCEDURE public.hex_exempel();\n"
            "ALTER EVENT TRIGGER hex_exempel_trigger OWNER TO postgres;\n"
        )
        self.assertEqual(install_hex.process_sql(sql, "min_agare"), sql)

    def test_security_definer_triggerfunktion_behaller_postgres(self):
        """
        SECURITY DEFINER-funktioner som ÄR triggerfunktioner lämnas orörda.

        De skapar roller och flyttar ägarskap och kräver därför superuser.
        """
        sql = (
            "CREATE FUNCTION public.hex_sd_trigger() RETURNS event_trigger\n"
            "    LANGUAGE 'plpgsql'\n    SECURITY DEFINER\n"
            "    SET search_path = public, pg_temp\n"
            "AS $BODY$ BEGIN END; $BODY$;\n"
            "ALTER FUNCTION public.hex_sd_trigger() OWNER TO postgres;\n"
        )
        self.assertEqual(install_hex.process_sql(sql, "min_agare"), sql)

    def test_security_definer_nyttofunktion_far_agarroll(self):
        """
        En vanlig SECURITY DEFINER-funktion ska köra som owner_role.

        Den ska ha exakt ägarrollens rättigheter – inte superuser – och
        ägarskapet måste därför följa owner_role i stället för det som
        råkar stå i filen.
        """
        sql = (
            "CREATE FUNCTION public.hex_sd() RETURNS void\n"
            "    LANGUAGE 'plpgsql'\n    SECURITY DEFINER\n"
            "    SET search_path = public, pg_temp\n"
            "AS $BODY$ BEGIN END; $BODY$;\n"
            "ALTER FUNCTION public.hex_sd() OWNER TO gis_admin;\n"
        )
        ut = install_hex.process_sql(sql, "min_agare")
        self.assertIn("OWNER TO min_agare", ut)
        self.assertNotIn("OWNER TO gis_admin", ut)

    def test_fras_i_kommentar_utloser_inte_undantag(self):
        """
        'SECURITY DEFINER' i en kommentar ska inte hindra omskrivningen.

        Klassificeringen görs på SQL utan kommentarer (_strip_sql_comments).
        """
        sql = (
            "-- Den här funktionen är avsiktligt inte SECURITY DEFINER\n"
            "CREATE FUNCTION public.hex_x() RETURNS void AS $$ BEGIN END; $$ LANGUAGE plpgsql;\n"
            "ALTER FUNCTION public.hex_x() OWNER TO gis_admin;\n"
        )
        ut = install_hex.process_sql(sql, "min_agare")
        self.assertIn("OWNER TO min_agare", ut)


# ---------------------------------------------------------------------------
# 2. _strip_sql_comments
# ---------------------------------------------------------------------------
class TestStripSqlComments(unittest.TestCase):

    def test_tar_bort_radkommentar(self):
        self.assertNotIn(
            "SECURITY DEFINER",
            install_hex._strip_sql_comments("-- SECURITY DEFINER\nSELECT 1;"),
        )

    def test_tar_bort_blockkommentar(self):
        self.assertNotIn(
            "SECURITY DEFINER",
            install_hex._strip_sql_comments("/* SECURITY DEFINER */\nSELECT 1;"),
        )

    def test_behaller_kod(self):
        self.assertIn("SELECT 1", install_hex._strip_sql_comments("-- x\nSELECT 1;"))


# ---------------------------------------------------------------------------
# 3. INSTALL_ORDER mot filerna på disk
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
# 4. Ägarskapsantagandet i process_sql
# ---------------------------------------------------------------------------
class TestAgarskapsantagande(unittest.TestCase):
    """
    process_sql lämnar event-trigger- och SECURITY DEFINER-filer orörda
    med motiveringen att de kräver superuser-ägande. Det antagandet håller
    bara om de filerna faktiskt säger 'OWNER TO postgres'.

    Säger en sådan fil 'OWNER TO <något annat>' installeras objektet med
    hårdkodat ägarskap oavsett vilket owner_role som konfigurerats. Två
    konsekvenser:

      1. På ett kluster där den hårdkodade rollen inte finns avbryts hela
         installationen (allt körs i en transaktion och rullas tillbaka).
      2. Finns rollen ändå av en slump hamnar ägarskapet fel, och en
         SECURITY DEFINER-funktion kör då som fel roll – utan rättigheter
         på Hex egna tabeller.
    """

    def _filer_som_lamnas_orörda(self):
        """
        Filer som process_sql returnerar oförändrade.

        Klassificeringen läses av från installerns faktiska beteende i stället
        för att upprepas här – annars kan testet och koden glida isär.
        """
        for path in sorted((PROJECT_ROOT / "src" / "sql").rglob("*.sql")):
            sql = path.read_text(encoding="utf-8")
            if install_hex.process_sql(sql, "hex_sentinel_agare") == sql:
                yield path, install_hex._strip_sql_comments(sql)

    def test_orörda_filer_äger_till_postgres(self):
        avvikande = []
        for path, kod in self._filer_som_lamnas_orörda():
            for agare in OWNER_TO.findall(kod):
                if agare.lower() != "postgres":
                    avvikande.append(
                        f"{path.relative_to(PROJECT_ROOT)} -> OWNER TO {agare}"
                    )

        self.assertEqual(
            avvikande, [],
            "Filer som process_sql lämnar orörda men som inte äger till "
            "postgres. Ägarskapet blir hårdkodat i stället för att följa "
            "owner_role:\n  " + "\n  ".join(avvikande),
        )

    def test_utan_agarroll_lamnar_inga_agarskapssatser(self):
        """
        Med owner_role=None ska ingen installerad fil ha kvar en
        ägarskapssats — utom de superuser-beroende filer som returneras
        oförändrade och behåller sitt postgres-ägande.
        """
        kvar = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            ut = install_hex.process_sql(sql, None)
            if ut == sql:
                continue  # superuser-beroende fil, avsiktligt orörd
            kod = install_hex._strip_sql_comments(ut)
            if re.search(r"\bOWNER\s+TO\s+\w+\s*;", kod, re.IGNORECASE):
                kvar.append(f)

        self.assertEqual(
            kvar, [],
            "Ägarskapssatser kvar trots owner_role=None:\n  " + "\n  ".join(kvar),
        )

    def test_utan_agarroll_lamnar_inga_dinglande_satser(self):
        """
        Borttagningen får inte klippa mitt i en sats.

        Varje ALTER som inleder en sats ska antingen vara helt borta eller
        fortfarande avslutas med semikolon.
        """
        trasiga = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            ut = install_hex.process_sql(sql, None)
            if ut == sql:
                continue
            kod = install_hex._strip_sql_comments(ut)
            # Varje ALTER-sats på toppnivå måste ha ett semikolon efter sig
            for match in re.finditer(r"^[ \t]*ALTER\b", kod, re.MULTILINE):
                if ";" not in kod[match.start():]:
                    trasiga.append(f"{f}: {kod[match.start():][:60]!r}")

        self.assertEqual(
            trasiga, [],
            "Dinglande ALTER-satser efter borttagning:\n  " + "\n  ".join(trasiga),
        )

    def test_agarskap_sätts_via_hex_systemagare(self):
        """
        Ingen installerad fil får hårdkoda ett rollnamn i sitt ägarskap.

        Ägarskapet ska sättas dynamiskt mot hex_systemagare(). Ett hårdkodat
        namn skrivs bara om av install_hex.py; manuell installation kör filerna
        precis som de står. Då hamnar objektet antingen på fel roll — eller
        avbryter hela installationen om rollen inte finns i klustret.

        Undantaget är de superuser-beroende filerna: de måste ägas av postgres
        och sätter det statiskt. Klassificeringen läses av från installerns egen
        funktion i stället för att upprepas här, så att testet och koden inte
        kan glida isär.
        """
        avvikande = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            statiska = OWNER_TO.findall(install_hex._strip_sql_comments(sql))
            if install_hex.kraver_superuser_agande(sql):
                for agare in statiska:
                    if agare.lower() != "postgres":
                        avvikande.append(
                            f"{f}: superuser-beroende fil äger till {agare}, "
                            "ska vara postgres"
                        )
            else:
                for agare in statiska:
                    avvikande.append(
                        f"{f}: hårdkodat OWNER TO {agare}, ska sättas via "
                        "public.hex_systemagare()"
                    )
                # En fil som skapar ett objekt utan att sätta ägarskap alls får
                # ägaren av den som råkar köra filen. Det ger fel ägare i båda
                # installationsvägarna, utan att någon OWNER TO-sats avslöjar det.
                kod = install_hex._strip_sql_comments(sql)
                if SKAPAR_OBJEKT.search(kod) and not re.search(
                    r"OWNER\s+TO", kod, re.IGNORECASE
                ):
                    avvikande.append(
                        f"{f}: skapar objekt utan ägarskapssats – objektet hamnar "
                        "på den anslutande användaren i stället för ägarrollen"
                    )

        self.assertEqual(
            avvikande, [],
            "Ägarskap som inte följer ägarrollen vid manuell installation:\n  "
            + "\n  ".join(avvikande),
        )

    def test_process_sql_lamnar_inga_frammande_agare(self):
        """
        Efter process_sql med ett eget owner_role ska ingen fil innehålla
        någon annan ägare än owner_role eller postgres.
        """
        owner_role = "hex_test_agare"
        avvikande = []
        for f in install_hex.INSTALL_ORDER:
            sql = (PROJECT_ROOT / f).read_text(encoding="utf-8")
            ut = install_hex._strip_sql_comments(
                install_hex.process_sql(sql, owner_role)
            )
            for agare in OWNER_TO.findall(ut):
                if agare.lower() not in (owner_role, "postgres"):
                    avvikande.append(f"{f} -> OWNER TO {agare}")

        self.assertEqual(
            avvikande, [],
            f"Filer med ägare som varken är owner_role ({owner_role}) eller "
            "postgres efter process_sql:\n  " + "\n  ".join(avvikande),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
