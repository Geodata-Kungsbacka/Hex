#!/usr/bin/env python3
"""Regressionstester för #176–#179 mot en engångsdatabas med Hex installerat."""
import os
import sys
import unittest
from pathlib import Path

import psycopg2
from psycopg2 import sql

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import install_hex

SCHEMA = 'sk1_kba_livscykeltest'


def anslut():
    """Anslut endast till den uttryckligen konfigurerade testdatabasen."""
    return psycopg2.connect(dbname=os.environ.get('PGDATABASE', 'hex_test'),
                            user=os.environ.get('PGUSER', 'postgres'),
                            host=os.environ.get('PGHOST', 'localhost'),
                            port=os.environ.get('PGPORT', '5432'),
                            password=os.environ.get('PGPASSWORD', ''))


class TestObjektlivscykel(unittest.TestCase):
    def setUp(self):
        self.conn = anslut()
        self.conn.set_client_encoding('UTF8')
        self.cur = self.conn.cursor()
        self.cur.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(SCHEMA)))

    def tearDown(self):
        # Även rollskapandet rullas tillbaka; inget tillstånd delas av testerna.
        self.conn.rollback()
        self.conn.close()

    def kor(self, sats, *namn):
        self.cur.execute(sql.SQL(sats).format(*(sql.Identifier(n) for n in namn)))

    def skapa(self, namn, definition='namn text'):
        self.kor('CREATE TABLE {}.{} (' + definition + ')', SCHEMA, namn)

    def ett(self, sats, parametrar=()):
        self.cur.execute(sats, parametrar)
        return self.cur.fetchone()[0]

    def fn(self, namn, typ):
        return self.ett('SELECT public.hex_objektnamn(%s, %s)', (namn, typ))

    def test_namnbyte_frigor_gammalt_namn_och_bevarar_separat_historik(self):
        self.skapa('alfa')
        self.kor("INSERT INTO {}.{} (namn) VALUES ('före')", SCHEMA, 'alfa')
        fore = self.ett('SELECT trigger_funktion FROM hex_metadata WHERE parent_schema=%s AND parent_table=%s', (SCHEMA, 'alfa'))
        self.kor('ALTER TABLE {}.{} RENAME TO {}', SCHEMA, 'alfa', 'beta')
        self.skapa('alfa', 'annan integer')
        self.kor('INSERT INTO {}.{} (annan) VALUES (42)', SCHEMA, 'alfa')
        self.kor("UPDATE {}.{} SET namn='efter'", SCHEMA, 'beta')
        self.kor('UPDATE {}.{} SET annan=43', SCHEMA, 'alfa')
        for tabell, kolumn, gammalt in [('beta', 'namn', 'före'), ('alfa', 'annan', 42)]:
            self.kor("SELECT {} FROM {}.{} WHERE h_typ='U'", kolumn, SCHEMA, tabell+'_h')
            self.assertEqual(self.cur.fetchone()[0], gammalt)
            self.kor('DELETE FROM {}.{}', SCHEMA, tabell)
            self.kor("SELECT count(*) FROM {}.{} WHERE h_typ='D'", SCHEMA, tabell+'_h')
            self.assertEqual(self.cur.fetchone()[0], 1)
        self.assertEqual(fore, 'trg_fn_alfa_qa')
        self.assertEqual(self.ett('SELECT trigger_funktion FROM hex_metadata WHERE parent_schema=%s AND parent_table=%s', (SCHEMA,'beta')), self.fn('beta','qa'))
        self.kor('DROP TABLE {}.{}, {}.{}', SCHEMA, 'alfa', SCHEMA, 'beta')
        self.assertEqual(self.ett('SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=%s', (SCHEMA,)), 0)
        self.kor('DROP SCHEMA {}', SCHEMA)

    def test_texten_rename_to_ar_inte_ett_namnbyte(self):
        self.skapa('eta')
        self.kor("ALTER TABLE {}.{} ADD COLUMN kommentar text DEFAULT 'rename to'", SCHEMA, 'eta')
        self.kor("INSERT INTO {}.{} (namn) VALUES ('ok') RETURNING kommentar", SCHEMA, 'eta')
        self.assertEqual(self.cur.fetchone()[0], 'rename to')

    def test_do_block_namnbyte_foljt_av_kolumntillagg(self):
        self.skapa('eta')
        self.cur.execute(f"""DO $$ BEGIN
            EXECUTE 'ALTER TABLE {SCHEMA}.eta RENAME TO eta3';
            EXECUTE 'ALTER TABLE {SCHEMA}.eta3 ADD COLUMN y integer';
        END $$""")
        self.assertTrue(self.ett("SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema=%s AND table_name='eta3_h' AND column_name='y')", (SCHEMA,)))
        self.kor("INSERT INTO {}.{} (namn,y) VALUES ('ok',7)", SCHEMA, 'eta3')
        self.kor('UPDATE {}.{} SET y=8', SCHEMA, 'eta3')
        self.kor('SELECT y FROM {}.{}', SCHEMA, 'eta3_h')
        self.assertEqual(self.cur.fetchone()[0], 7)

    def test_multisats_namnbyte_foljt_av_kolumntillagg(self):
        self.skapa('eta')
        self.cur.execute(f'ALTER TABLE {SCHEMA}.eta RENAME TO eta3; ALTER TABLE {SCHEMA}.eta3 ADD COLUMN y integer;')
        self.assertTrue(self.ett("SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema=%s AND table_name='eta3_h' AND column_name='y')", (SCHEMA,)))

    def test_langa_namn_och_reparation_av_bada_triggers(self):
        for langd in (43, 44, 46, 54):
            with self.subTest(langd=langd):
                namn = 'a' * (langd-2) + str(langd)
                self.skapa(namn)
                qa = self.fn(namn,'qa'); audit = self.fn(namn,'insert_audit')
                self.assertLessEqual(len(qa.encode()),63)
                self.assertLessEqual(len(audit.encode()),63)
                self.assertTrue(audit.endswith('_insert_audit'))
                self.assertEqual(self.ett('SELECT trigger_funktion FROM hex_metadata WHERE parent_schema=%s AND parent_table=%s', (SCHEMA,namn)),qa)
                self.kor('DROP TRIGGER {} ON {}.{}', self.fn(namn,'qa_trigger'), SCHEMA, namn)
                self.kor('DROP TRIGGER hex_tvinga_anvandarvarden ON {}.{}', SCHEMA, namn)
                self.cur.execute('SELECT * FROM hex_underhall()')
                self.kor("INSERT INTO {}.{} (namn,skapad_av) VALUES ('före','förfalskad') RETURNING skapad_av", SCHEMA, namn)
                self.assertEqual(self.cur.fetchone()[0], self.ett('SELECT session_user'))
                self.kor("UPDATE {}.{} SET namn='efter'", SCHEMA, namn)
                self.kor('SELECT namn FROM {}.{}', SCHEMA, namn+'_h')
                self.assertEqual(self.cur.fetchone()[0], 'före')
                self.kor('DROP TABLE {}.{}', SCHEMA, namn)
                self.assertEqual(self.ett('SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=%s AND p.proname IN (%s,%s)', (SCHEMA,qa,audit)),0)

    def test_langa_namn_med_samma_prefix_kolliderar_inte(self):
        for namn in ['a'*53+'b', 'a'*53+'c']:
            self.skapa(namn)
        self.assertNotEqual(self.fn('a'*53+'b','insert_audit'), self.fn('a'*53+'c','insert_audit'))

    def test_multibyte_namn_ryms_och_bevarar_suffix(self):
        namn = 'å'*25+'abc'
        self.skapa(namn)
        self.assertLessEqual(len(self.fn(namn,'insert_audit').encode()),63)
        self.kor('ALTER TABLE {}.{} RENAME TO {}', SCHEMA, namn, 'ö'*25+'def')
        self.skapa(namn)

    def test_namnbyte_med_for_langt_namn_rullas_tillbaka(self):
        self.skapa('kort')
        self.cur.execute('SAVEPOINT namnbyte')
        with self.assertRaises(psycopg2.Error):
            self.kor('ALTER TABLE {}.{} RENAME TO {}', SCHEMA, 'kort', 'a'*55)
        self.cur.execute('ROLLBACK TO SAVEPOINT namnbyte')
        self.assertIsNotNone(self.ett('SELECT to_regclass(%s)', (SCHEMA+'.kort',)))
        self.kor("INSERT INTO {}.{} (namn) VALUES ('ok')", SCHEMA, 'kort')
        self.kor("UPDATE {}.{} SET namn='ny'", SCHEMA, 'kort')

    def test_namnbyte_utan_historik_flyttar_gid_sekvens(self):
        self.cur.execute('UPDATE hex_standardiserade_kolumner SET historik_qa=false')
        self.skapa('alfa')
        self.kor('ALTER TABLE {}.{} RENAME TO {}', SCHEMA, 'alfa', 'beta')
        self.skapa('alfa')
        self.assertIsNotNone(self.ett('SELECT to_regclass(%s)', (SCHEMA+'.beta_gid_seq',)))


class TestUppgraderingObjektnamn(unittest.TestCase):
    """HEX-MIGRERING 2026-10: tas bort med normaliseringen av äldre namn.

    Skapar en egen databas och återställer äldre trunkerade funktioner före
    upgrade(); verifierar bevarade data, metadata och triggerkopplingar.
    """
    def test_upgrade_reparerar_aldre_trunkering_utan_dataforlust(self):
        admin = anslut(); admin.autocommit = True
        dbnamn = 'hex_test_objektnamn_upgrade'
        cur = admin.cursor()
        cur.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(dbnamn)))
        cfg = dict(host=os.environ.get('PGHOST','localhost'), port=os.environ.get('PGPORT','5432'),
                   user=os.environ.get('PGUSER','postgres'), password=os.environ.get('PGPASSWORD',''),
                   dbname=dbnamn, owner_role='gis_admin')
        conn = None
        try:
            install_hex.install(cfg, base_path=ROOT)
            conn = psycopg2.connect(**{k:v for k,v in cfg.items() if k!='owner_role'})
            conn.set_client_encoding('UTF8'); c = conn.cursor()
            s = 'sk1_kba_migreringstest'; namn = 'm'*54
            c.execute(sql.SQL('CREATE SCHEMA {}; CREATE TABLE {}.{} (namn text)').format(sql.Identifier(s),sql.Identifier(s),sql.Identifier(namn)))
            c.execute(sql.SQL("INSERT INTO {}.{} (namn) VALUES ('bevarad')").format(sql.Identifier(s),sql.Identifier(namn)))
            for typ in ('qa','insert_audit'):
                c.execute('SELECT hex_objektnamn(%s,%s), (%s)::name::text', (namn,typ,'trg_fn_'+namn+'_'+typ))
                nytt, gammalt = c.fetchone()
                c.execute(sql.SQL('ALTER FUNCTION {}.{}() RENAME TO {}').format(sql.Identifier(s),sql.Identifier(nytt),sql.Identifier(gammalt)))
            c.execute('UPDATE hex_metadata SET trigger_funktion=NULL WHERE parent_schema=%s',(s,))
            c.execute(sql.SQL('DROP TRIGGER {} ON {}.{}').format(sql.Identifier('trg_'+namn+'_qa'),sql.Identifier(s),sql.Identifier(namn)))
            c.execute(sql.SQL('DROP TRIGGER hex_tvinga_anvandarvarden ON {}.{}').format(sql.Identifier(s),sql.Identifier(namn)))
            # Återskapa det äldre namnbytesfelet: tabell och historik fick
            # nytt namn men sekvens, index och funktioner behöll det gamla.
            c.execute(sql.SQL('CREATE TABLE {}.alfa (namn text)').format(sql.Identifier(s)))
            c.execute(sql.SQL("INSERT INTO {}.alfa (namn) VALUES ('äldre namnbyte')").format(sql.Identifier(s)))
            c.execute('ALTER EVENT TRIGGER hex_hantera_ny_kolumn_trigger DISABLE')
            c.execute(sql.SQL('ALTER TABLE {}.alfa RENAME TO beta; ALTER TABLE {}.alfa_h RENAME TO beta_h').format(sql.Identifier(s),sql.Identifier(s)))
            c.execute('ALTER EVENT TRIGGER hex_hantera_ny_kolumn_trigger ENABLE')
            c.execute("UPDATE hex_metadata SET parent_table='beta', history_table='beta_h' WHERE parent_schema=%s AND parent_table='alfa'", (s,))
            conn.commit(); conn.close(); conn=None
            install_hex.upgrade(cfg, base_path=ROOT)
            conn=psycopg2.connect(**{k:v for k,v in cfg.items() if k!='owner_role'}); c=conn.cursor()
            c.execute(sql.SQL("UPDATE {}.{} SET namn='efter'").format(sql.Identifier(s),sql.Identifier(namn)))
            c.execute(sql.SQL('SELECT namn FROM {}.{}').format(sql.Identifier(s),sql.Identifier(namn+'_h')))
            self.assertEqual(c.fetchone()[0], 'bevarad')
            c.execute('SELECT trigger_funktion=hex_objektnamn(parent_table,\'qa\') FROM hex_metadata WHERE parent_schema=%s',(s,))
            self.assertTrue(c.fetchone()[0])
            c.execute(sql.SQL('CREATE TABLE {}.alfa (annan integer)').format(sql.Identifier(s)))
            c.execute(sql.SQL("UPDATE {}.beta SET namn='efter upgrade'").format(sql.Identifier(s)))
            c.execute(sql.SQL('SELECT namn FROM {}.beta_h').format(sql.Identifier(s)))
            self.assertEqual(c.fetchone()[0], 'äldre namnbyte')
            c.execute(sql.SQL('DROP TABLE {}.{}, {}.alfa, {}.beta; DROP SCHEMA {}').format(sql.Identifier(s),sql.Identifier(namn),sql.Identifier(s),sql.Identifier(s),sql.Identifier(s)))
            conn.commit()
        finally:
            if conn is not None: conn.close()
            cur.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(dbnamn)))
            admin.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
