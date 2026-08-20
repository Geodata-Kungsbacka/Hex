#!/usr/bin/env python3
"""
Test: reparera_hex.py – återvinning ur en redan skadad databas.

Verktyget riktar sig mot databaser som uppgraderats med en installer utan
fullständigt inställningsbevarande. Sviten återskapar den skadan direkt (tömmer
tillståndstabellerna, tar bort den egna prefixraden och släpper dummy-triggarna)
i stället för att köra den gamla installern, eftersom det är reparationen som
provas – inte det ursprungliga felet.

Sviten skapar och droppar en egen engångsdatabas och rör aldrig den vanliga
testdatabasen. Kan den inte ansluta som superuser hoppas den över.

Kör med:
    PGHOST=localhost PGUSER=postgres PGPASSWORD=... python3 tests/test_reparera.py
"""

import os
import sys
import time
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

try:
    import psycopg2
except ImportError:  # pragma: no cover
    psycopg2 = None

import install_hex  # noqa: E402
import reparera_hex  # noqa: E402

TESTDB = "hex_test_reparera"
AGARROLL = "hex_reparera_agare"


def _admin_params():
    return {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": int(os.environ.get("PGPORT", 5432)),
        "user": os.environ.get("PGUSER", "postgres"),
        "dbname": "postgres",
        **({"password": os.environ["PGPASSWORD"]} if "PGPASSWORD" in os.environ else {}),
    }


def _db_config():
    cfg = _admin_params()
    cfg["dbname"] = TESTDB
    cfg["owner_role"] = AGARROLL
    return cfg


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


KAN_KORA = _kan_ansluta()


def _admin_exec(*satser):
    conn = psycopg2.connect(**_admin_params())
    conn.autocommit = True
    try:
        for sats in satser:
            conn.cursor().execute(sats)
    finally:
        conn.close()


def _koppla(auto=True):
    params = {k: v for k, v in _db_config().items() if k != "owner_role"}
    conn = psycopg2.connect(**params)
    conn.set_client_encoding("UTF8")
    conn.autocommit = auto
    return conn


def _kor(*satser):
    conn = _koppla()
    try:
        for sats in satser:
            conn.cursor().execute(sats)
    finally:
        conn.close()


def _fraga(sql, params=None):
    conn = _koppla()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        return cur.fetchall()
    finally:
        conn.close()


def _rep_config():
    """db-dict utan owner_role – reparera_hex ansluter som installern."""
    return {k: v for k, v in _db_config().items() if k != "owner_role"}


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestReparationEfterSkada(unittest.TestCase):
    """
    Skadan: konfigurationen återställd till standardvärden och
    drifttillståndet tömt. Spåren finns kvar i scheman, roller,
    triggerfunktioner och geometrikolumner – det är dem verktyget läser.
    """

    @classmethod
    def setUpClass(cls):
        _admin_exec(f'DROP DATABASE IF EXISTS "{TESTDB}" WITH (FORCE)',
                    f'CREATE DATABASE "{TESTDB}"')
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))

        # Kundens egna prefix, och scheman som ger verkligt drifttillstånd.
        _kor("INSERT INTO public.hex_standardiserade_skyddsnivaer"
             " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
             " VALUES ('sk9', 'Egen nivå', true, false)",
             "CREATE SCHEMA sk9_kba_egen",
             "CREATE SCHEMA sk0_kba_rep",
             "CREATE TABLE sk0_kba_rep.hus_p (namn text, geom geometry(Point, 3007))",
             "CREATE TABLE sk0_kba_rep.fel_srid_p (namn text, geom geometry(Point, 3006))")

        cls.fore_metadata = _fraga("SELECT count(*) FROM public.hex_metadata")[0][0]

        # --- Skadan -------------------------------------------------------
        # Prefixraden bort: schemat sk9_kba_egen faller ur hex_schema_regex()
        # och blir osynligt för allt underhåll.
        _kor("DELETE FROM public.hex_standardiserade_skyddsnivaer WHERE prefix = 'sk9'",
             "TRUNCATE public.hex_metadata",
             "TRUNCATE public.hex_avvikande_srid",
             "TRUNCATE public.hex_dummy_geometrier",
             # DROP FUNCTION ... CASCADE i avinstallationen tar radtriggarna med sig.
             "DROP TRIGGER IF EXISTS hex_ta_bort_dummy ON sk0_kba_rep.hus_p",
             "DROP TRIGGER IF EXISTS hex_ta_bort_dummy ON sk0_kba_rep.fel_srid_p")

    @classmethod
    def tearDownClass(cls):
        _admin_exec(f'DROP DATABASE IF EXISTS "{TESTDB}" WITH (FORCE)')

    # --- Diagnos ----------------------------------------------------------

    def test_diagnos_hittar_foraldralost_schema(self):
        """sk9_kba_egen finns kvar men prefixet är borta ur regexen."""
        self.assertNotIn("sk9", _fraga("SELECT public.hex_schema_regex()")[0][0])
        conn = _koppla()
        try:
            fynd = reparera_hex.foraldralosa_scheman(conn.cursor())
        finally:
            conn.close()
        self.assertEqual([(p, list(s)) for p, s in fynd], [("sk9", ["sk9_kba_egen"])])

    def test_diagnos_hittar_metadataluckor(self):
        conn = _koppla()
        try:
            fynd = reparera_hex.metadata_luckor(conn.cursor())
        finally:
            conn.close()
        self.assertEqual(len(fynd), self.fore_metadata)

    def test_diagnos_hittar_avvikande_srid(self):
        conn = _koppla()
        try:
            fynd = reparera_hex.srid_luckor(conn.cursor())
        finally:
            conn.close()
        self.assertEqual([(s, t, srid) for s, t, srid in fynd],
                         [("sk0_kba_rep", "fel_srid_p", 3006)])

    def test_diagnos_bortser_fran_historik_qa_kolumner(self):
        """
        historik_qa = true ger avsiktligt ingen DEFAULT – värdet sätts av
        QA-triggern. Sådana kolumner får inte rapporteras som avvikelser.
        """
        conn = _koppla()
        try:
            fynd = reparera_hex.standardvarde_drift(conn.cursor())
        finally:
            conn.close()
        historik_kolumner = {
            r[0] for r in _fraga(
                "SELECT kolumnnamn FROM public.hex_standardiserade_kolumner"
                " WHERE historik_qa = true"
            )
        }
        self.assertFalse({f[0] for f in fynd} & historik_kolumner)

    def test_diagnos_andrar_ingenting(self):
        """Utan --reparera ska databasen lämnas orörd."""
        fore = _fraga("SELECT count(*) FROM public.hex_metadata")[0][0]
        reparera_hex.granska(_rep_config(), reparera=False)
        self.assertEqual(_fraga("SELECT count(*) FROM public.hex_metadata")[0][0], fore)
        self.assertNotIn("sk9", _fraga("SELECT public.hex_schema_regex()")[0][0])


@unittest.skipUnless(KAN_KORA, "kräver superuser-anslutning till PostgreSQL")
class TestReparationAtgardar(unittest.TestCase):
    """Samma skada, men nu körs reparationen skarpt."""

    @classmethod
    def setUpClass(cls):
        _admin_exec(f'DROP DATABASE IF EXISTS "{TESTDB}" WITH (FORCE)',
                    f'CREATE DATABASE "{TESTDB}"')
        install_hex.install(_db_config(), base_path=str(PROJECT_ROOT))
        _kor("INSERT INTO public.hex_standardiserade_skyddsnivaer"
             " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
             " VALUES ('sk9', 'Egen nivå', true, false)",
             "CREATE SCHEMA sk9_kba_egen",
             "CREATE SCHEMA sk0_kba_rep",
             "CREATE TABLE sk0_kba_rep.hus_p (namn text, geom geometry(Point, 3007))",
             "CREATE TABLE sk0_kba_rep.fel_srid_p (namn text, geom geometry(Point, 3006))")
        cls.antal_metadata = _fraga("SELECT count(*) FROM public.hex_metadata")[0][0]
        _kor("DELETE FROM public.hex_standardiserade_skyddsnivaer WHERE prefix = 'sk9'",
             "TRUNCATE public.hex_metadata",
             "TRUNCATE public.hex_avvikande_srid")

        reparera_hex.granska(_rep_config(), reparera=True)
        # Idempotens: en andra körning får inte skapa dubbletter.
        reparera_hex.granska(_rep_config(), reparera=True)

    @classmethod
    def tearDownClass(cls):
        _admin_exec(f'DROP DATABASE IF EXISTS "{TESTDB}" WITH (FORCE)')

    def test_prefixet_ar_ateregistrerat(self):
        self.assertIn("sk9", _fraga("SELECT public.hex_schema_regex()")[0][0])

    def test_ateregistrerat_prefix_publicerar_inte(self):
        """
        Publiceringsflaggan går inte att härleda. Den ska sättas till false så
        att ett schema aldrig av misstag publiceras till GeoServer.
        """
        rad = _fraga("SELECT publiceras_geoserver, anonym_las"
                     " FROM public.hex_standardiserade_skyddsnivaer WHERE prefix = 'sk9'")
        self.assertEqual(rad, [(False, False)])

    def test_metadata_ar_aterstalld(self):
        self.assertEqual(
            _fraga("SELECT count(*) FROM public.hex_metadata")[0][0],
            self.antal_metadata,
        )

    def test_avvikande_srid_ar_aterstalld(self):
        self.assertEqual(
            _fraga("SELECT schema_namn, tabell_namn, srid FROM public.hex_avvikande_srid"),
            [("sk0_kba_rep", "fel_srid_p", 3006)],
        )

    def test_historiken_foljer_med_vid_namnbyte_igen(self):
        """Beviset på att hex_metadata verkligen fungerar, inte bara har rader."""
        _kor("ALTER TABLE sk0_kba_rep.hus_p RENAME TO byggnad_p")
        tabeller = [r[0] for r in _fraga(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'sk0_kba_rep' ORDER BY 1"
        )]
        self.assertIn("byggnad_p_h", tabeller)
        self.assertNotIn("hus_p_h", tabeller)

    def test_geoserver_notifieras_nar_dba_slar_pa_publicering(self):
        """
        Det återförda schemat ska nå GeoServer så snart DBA satt flaggan –
        utan att någon behöver köra om hela uppgraderingen.
        """
        lyssnare = _koppla()
        try:
            lyssnare.cursor().execute("LISTEN geoserver_schema")
            _kor("UPDATE public.hex_standardiserade_skyddsnivaer"
                 " SET publiceras_geoserver = true WHERE prefix = 'sk9'",
                 "SELECT * FROM public.hex_underhall()")
            time.sleep(1)
            lyssnare.poll()
            nyttor = set()
            while lyssnare.notifies:
                nyttor.add(lyssnare.notifies.pop(0).payload)
        finally:
            lyssnare.close()
        self.assertIn("sk9_kba_egen", nyttor)


if __name__ == "__main__":
    unittest.main(verbosity=2)
