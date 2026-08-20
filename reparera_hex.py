#!/usr/bin/env python3
"""
Reparerar en Hex-databas som uppgraderats med en installer utan fullständigt
inställningsbevarande.

Bakgrunden: uppgraderingen droppade konfigurations- och tillståndstabellerna och
återställde dem ofullständigt. En del av det som gick förlorat kan härledas ur
databasen själv — spåren finns kvar i scheman, roller, triggerfunktioner och
geometrikolumner. Resten kräver en säkerhetskopia eller ett DBA-beslut.

Kör utan flaggor för en ren DIAGNOS (rör ingenting):

    python reparera_hex.py

Kör med --reparera för att utföra de åtgärder som är härledbara och säkra:

    python reparera_hex.py --reparera

Verktyget tar aldrig bort data. Kvarglömda dummy-rader och avvikelser i
standardkolumnernas defaultvärden rapporteras för manuell granskning.

Databaserna hämtas från DATABASES i install_hex.py, samma lista som installern.
"""

import argparse

import psycopg2
from psycopg2 import sql as pgsql

from install_hex import DATABASES, _conn_params, _label, kor_underhall, skriv_varning


# =============================================================================
# KONTROLLER
#
# Varje kontroll returnerar en lista med fynd. En kontroll som kan repareras
# har en motsvarande reparera_*-funktion som tar samma fynd som argument.
# =============================================================================


def foraldralosa_scheman(cur) -> list:
    """Scheman som ser ut som Hex-scheman men vars prefix inte är registrerat.

    Ett schema kan inte ha skapats utan att prefixet fanns i
    hex_standardiserade_skyddsnivaer — hex_validera_schemanamn() bygger sitt
    tillåtna mönster ur den tabellen. Finns schemat men inte prefixet är raden
    alltså borttagen i efterhand, och schemat har fallit ur hex_schema_regex().
    Då slutar allt underhåll gälla det: ägarskapsöverföring, triggerreparation,
    GeoServer-notifiering och rollstädning vid drop.
    """
    cur.execute(
        """
        SELECT substring(n.nspname FROM '^(sk[a-z0-9]+)_') AS prefix,
               array_agg(n.nspname ORDER BY n.nspname)      AS scheman
        FROM   pg_namespace n
        WHERE  n.nspname ~ '^sk[a-z0-9]+_'
          AND  NOT EXISTS (
                   SELECT 1 FROM public.hex_standardiserade_skyddsnivaer ssn
                   WHERE  ssn.prefix = substring(n.nspname FROM '^(sk[a-z0-9]+)_')
               )
        GROUP BY 1
        ORDER BY 1
        """
    )
    return cur.fetchall()


def saknade_rollmallar(cur) -> list:
    """Roller som finns för ett Hex-schema men som ingen rollmall längre skapar.

    Rollerna skapades av en mall i hex_standardiserade_roller. Finns rollen kvar
    men inte mallen är mallraden borttagen, och nya scheman får inte längre
    motsvarande roll. Rollnamnet bär mallen: app_r_sk2_kba_hemlig -> app_r_{schema}.
    """
    cur.execute(
        """
        WITH hex_scheman AS (
            SELECT nspname FROM pg_namespace WHERE nspname ~ '^sk[a-z0-9]+_'
        ),
        harledda AS (
            SELECT DISTINCT
                   replace(r.rolname, s.nspname, '{schema}') AS mall,
                   s.nspname                                 AS exempelschema,
                   r.rolname                                 AS exempelroll
            FROM   pg_roles    r
            JOIN   hex_scheman s ON r.rolname LIKE '%' || s.nspname
        )
        SELECT mall, exempelschema, exempelroll
        FROM   harledda
        WHERE  mall <> exempelroll
          AND  NOT EXISTS (
                   SELECT 1 FROM public.hex_standardiserade_roller sr
                   WHERE  sr.rollnamn = harledda.mall
               )
        ORDER BY mall
        """
    )
    return cur.fetchall()


def metadata_luckor(cur) -> list:
    """Tabeller med historik och QA-trigger men utan rad i hex_metadata.

    QA-triggerfunktionerna lever i användarschemana och överlever en
    avinstallation, så de är en pålitlig källa. Utan hex_metadata-raden slutar
    historiken följa med vid ALTER TABLE ... RENAME TO.
    """
    cur.execute(
        """
        SELECT n.nspname, p.relname, h.relname, f.proname
        FROM   pg_class     p
        JOIN   pg_namespace n ON n.oid = p.relnamespace
        JOIN   pg_proc      f ON f.pronamespace = n.oid
                             AND f.proname = 'trg_fn_' || p.relname || '_qa'
        JOIN   pg_class     h ON h.relnamespace = n.oid
                             AND h.relname = left(p.relname, 61) || '_h'
                             AND h.relkind = 'r'
        WHERE  p.relkind = 'r'
          AND  n.nspname ~ public.hex_schema_regex()
          AND  NOT EXISTS (
                   SELECT 1 FROM public.hex_metadata m WHERE m.parent_oid = p.oid
               )
        ORDER BY 1, 2
        """
    )
    return cur.fetchall()


def srid_luckor(cur) -> list:
    """Geometritabeller med SRID <> 3007 som saknas i granskningslistan.

    hex_avvikande_srid är en ren härledning ur tabellernas faktiska SRID, så den
    går att bygga om exakt. Bara registrerad/registrerad_av går förlorade.
    """
    cur.execute(
        """
        SELECT n.nspname, c.relname, a.srid
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        JOIN   LATERAL (
                   SELECT DISTINCT postgis_typmod_srid(at.atttypmod) AS srid
                   FROM   pg_attribute at
                   JOIN   pg_type      t ON t.oid = at.atttypid
                   WHERE  at.attrelid = c.oid AND at.attnum > 0
                     AND  NOT at.attisdropped AND t.typname = 'geometry'
                     AND  postgis_typmod_srid(at.atttypmod) > 0
               ) a ON true
        WHERE  c.relkind = 'r'
          AND  n.nspname ~ public.hex_schema_regex()
          AND  c.relname NOT LIKE '%\\_h'
          AND  a.srid <> 3007
          AND  NOT EXISTS (
                   SELECT 1 FROM public.hex_avvikande_srid s
                   WHERE  s.schema_namn = n.nspname AND s.tabell_namn = c.relname
               )
        ORDER BY 1, 2
        """
    )
    return cur.fetchall()


def afvaktande_luckor(cur) -> list:
    """Tabeller med geometrireserverat suffix men utan geometrikolumn.

    Motsvarar FME:s tvåstegsmönster: tabellen skapas först, geometrikolumnen
    läggs till efteråt. Utan kön i hex_afvaktande_geometri slutför
    hex_hantera_ny_kolumn() aldrig uppsättningen när kolumnen anländer.
    """
    cur.execute(
        """
        SELECT n.nspname, c.relname
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind = 'r'
          AND  n.nspname ~ public.hex_schema_regex()
          AND  c.relname ~ '_(p|l|y|g)$'
          AND  NOT EXISTS (
                   SELECT 1 FROM pg_attribute at
                   JOIN   pg_type t ON t.oid = at.atttypid
                   WHERE  at.attrelid = c.oid AND at.attnum > 0
                     AND  NOT at.attisdropped AND t.typname = 'geometry'
               )
          AND  NOT EXISTS (
                   SELECT 1 FROM public.hex_afvaktande_geometri v
                   WHERE  v.schema_namn = n.nspname AND v.tabell_namn = c.relname
               )
        ORDER BY 1, 2
        """
    )
    return cur.fetchall()


def kvarglomda_dummies(cur) -> list:
    """Tabeller som kan bära en dummy-rad ingen trigger längre städar bort.

    Registret var det enda som visste vilken gid som var dummyn, så raderna går
    inte att peka ut exakt. Alla dummies ligger däremot i samma ruta
    (160000-160100 / 6395000-6395100), vilket ger en granskningslista.
    """
    cur.execute(
        """
        WITH kandidater AS (
            SELECT n.nspname AS schema_namn, c.relname AS tabell_namn
            FROM   pg_class     c
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  c.relkind = 'r'
              AND  n.nspname ~ public.hex_schema_regex()
              AND  c.relname NOT LIKE '%\\_h'
              AND  EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
                           WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                             AND a.attname = 'geom' AND t.typname = 'geometry')
              AND  NOT EXISTS (SELECT 1 FROM pg_trigger tg
                               WHERE tg.tgrelid = c.oid AND tg.tgname = 'hex_ta_bort_dummy')
              AND  NOT EXISTS (SELECT 1 FROM public.hex_dummy_geometrier d
                               WHERE d.schema_namn = n.nspname AND d.tabell_namn = c.relname)
        )
        SELECT k.schema_namn, k.tabell_namn, m.antal_rader, m.antal_dummy
        FROM   kandidater k
        CROSS JOIN LATERAL (
            SELECT (xpath('/row/a/text()', x))[1]::text::bigint AS antal_rader,
                   (xpath('/row/d/text()', x))[1]::text::bigint AS antal_dummy
            FROM query_to_xml(format(
                'SELECT count(*) AS a,'
                ' count(*) FILTER (WHERE geom && ST_SetSRID('
                '   ST_MakeEnvelope(159999, 6394999, 160101, 6395101), ST_SRID(geom))) AS d'
                ' FROM %I.%I', k.schema_namn, k.tabell_namn), false, true, '') AS x
        ) m
        WHERE  m.antal_dummy > 0
        ORDER BY 1, 2
        """
    )
    return cur.fetchall()


def standardvarde_drift(cur) -> list:
    """Standardkolumner vars faktiska default i befintliga tabeller avviker.

    Tabellerna skapades med den konfiguration som gällde då. Avviker deras
    faktiska default från hex_standardiserade_kolumner är antingen konfigurationen
    återställd till standardvärdet, eller så har den ändrats avsiktligt sedan
    tabellerna skapades. Bara DBA kan avgöra vilket — därför rapport, inte åtgärd.
    """
    cur.execute(
        """
        SELECT sk.kolumnnamn,
               sk.default_varde                                   AS konfigurerat,
               col.column_default                                 AS faktiskt,
               count(*)                                           AS antal_tabeller
        FROM   public.hex_standardiserade_kolumner sk
        JOIN   information_schema.columns col
               ON col.column_name = sk.kolumnnamn
              AND col.table_schema ~ public.hex_schema_regex()
        WHERE  col.table_name NOT LIKE '%\\_h'
          -- historik_qa = true ger avsiktligt ingen DEFAULT: värdet sätts av
          -- QA-triggern vid UPDATE/DELETE, och en DEFAULT skulle skriva över
          -- triggerns arbete (se hex_hamta_kolumnstandard.sql). Att kolumnen
          -- saknar default i tabellen är alltså rätt, inte en avvikelse.
          AND  sk.historik_qa = false
          AND  coalesce(col.column_default, '') IS DISTINCT FROM coalesce(sk.default_varde, '')
          AND  lower(replace(coalesce(col.column_default, ''), '::text', ''))
               IS DISTINCT FROM lower(coalesce(sk.default_varde, ''))
        GROUP BY 1, 2, 3
        ORDER BY 1, 3
        """
    )
    return cur.fetchall()


# =============================================================================
# REPARATIONER
# =============================================================================


def reparera_prefix(cur, fynd) -> int:
    """Registrerar saknade prefix igen, med publicering AVSTÄNGD.

    Att återregistrera prefixet återför schemat under Hex förvaltning. Om det
    ska publiceras till GeoServer eller läsas anonymt går inte att härleda —
    de sätts därför till false, och DBA får slå på dem medvetet.
    """
    for prefix, scheman in fynd:
        cur.execute(
            "INSERT INTO public.hex_standardiserade_skyddsnivaer"
            " (prefix, beskrivning, publiceras_geoserver, anonym_las)"
            " VALUES (%s, %s, false, false) ON CONFLICT (prefix) DO NOTHING",
            (prefix, f"Återregistrerad av reparera_hex.py (scheman: {', '.join(scheman)})"),
        )
    return len(fynd)


def reparera_metadata(cur, fynd) -> int:
    for schema, tabell, historik, funktion in fynd:
        cur.execute(
            "INSERT INTO public.hex_metadata"
            " (parent_oid, parent_schema, parent_table, history_schema,"
            "  history_table, trigger_funktion)"
            " SELECT c.oid, %s, %s, %s, %s, %s FROM pg_class c"
            " JOIN pg_namespace n ON n.oid = c.relnamespace"
            " WHERE n.nspname = %s AND c.relname = %s"
            " ON CONFLICT (parent_oid) DO NOTHING",
            (schema, tabell, schema, historik, funktion, schema, tabell),
        )
    return len(fynd)


def reparera_srid(cur, fynd) -> int:
    for schema, tabell, srid in fynd:
        cur.execute(
            "INSERT INTO public.hex_avvikande_srid (schema_namn, tabell_namn, srid)"
            " VALUES (%s, %s, %s)"
            " ON CONFLICT (schema_namn, tabell_namn) DO UPDATE SET srid = EXCLUDED.srid",
            (schema, tabell, srid),
        )
    return len(fynd)


def reparera_afvaktande(cur, fynd) -> int:
    for schema, tabell in fynd:
        cur.execute(
            "INSERT INTO public.hex_afvaktande_geometri (schema_namn, tabell_namn)"
            " VALUES (%s, %s) ON CONFLICT (schema_namn, tabell_namn) DO NOTHING",
            (schema, tabell),
        )
    return len(fynd)


# =============================================================================
# KÖRNING
# =============================================================================


def _rubrik(text: str):
    print()
    print(text)
    print("-" * len(text))


def granska(db: dict, reparera: bool = False):
    """Kör alla kontroller mot en databas, och åtgärdar om reparera=True."""
    print("=" * 60)
    print(f"Hex Reparation - {_label(db)}"
          f"{'  (DIAGNOS - ingenting ändras)' if not reparera else ''}")
    print("=" * 60)

    conn = psycopg2.connect(**_conn_params(db))
    conn.set_client_encoding("UTF8")
    try:
        cur = conn.cursor()

        prefix_fynd     = foraldralosa_scheman(cur)
        rollmall_fynd   = saknade_rollmallar(cur)
        metadata_fynd   = metadata_luckor(cur)
        srid_fynd       = srid_luckor(cur)
        afvaktande_fynd = afvaktande_luckor(cur)
        dummy_fynd      = kvarglomda_dummies(cur)
        drift_fynd      = standardvarde_drift(cur)

        _rubrik("Härledbart ur databasen")
        print(f"  Oregistrerade prefix (scheman utanför Hex)  {len(prefix_fynd)}")
        for prefix, scheman in prefix_fynd:
            print(f"      {prefix}: {', '.join(scheman)}")
        print(f"  Saknade rader i hex_metadata                {len(metadata_fynd)}")
        print(f"  Saknade rader i hex_avvikande_srid          {len(srid_fynd)}")
        print(f"  Saknade rader i hex_afvaktande_geometri     {len(afvaktande_fynd)}")

        _rubrik("Kräver granskning - rapporteras, åtgärdas inte")
        print(f"  Rollmallar som inte längre finns            {len(rollmall_fynd)}")
        for mall, schema, roll in rollmall_fynd:
            print(f"      {mall}  (rollen {roll} finns i {schema})")
        print(f"  Möjliga kvarglömda dummy-rader             {len(dummy_fynd)}")
        for schema, tabell, rader, dummies in dummy_fynd:
            print(f"      {schema}.{tabell}: {rader} rad(er), varav {dummies} i dummy-rutan")
        print(f"  Standardkolumner med avvikande default     {len(drift_fynd)}")
        for kolumn, konf, faktisk, antal in drift_fynd:
            print(f"      {kolumn}: konfig={konf!r} men {antal} tabell(er) har {faktisk!r}")

        _rubrik("Går inte att härleda - kräver säkerhetskopia eller DBA-beslut")
        print("  publiceras_geoserver och anonym_las per prefix")
        cur.execute(
            "SELECT prefix, publiceras_geoserver, anonym_las"
            " FROM public.hex_standardiserade_skyddsnivaer ORDER BY prefix"
        )
        for prefix, publ, anon in cur.fetchall():
            print(f"      {prefix:6} publiceras_geoserver={publ!s:5} anonym_las={anon}")
        print("  Kontrollera mot GeoServer: ett workspace som finns för ett prefix")
        print("  med publiceras_geoserver=false är ett tecken på att värdet tappats.")

        if not reparera:
            atgardbart = (len(prefix_fynd) + len(metadata_fynd)
                          + len(srid_fynd) + len(afvaktande_fynd))
            print()
            print("=" * 60)
            print(f"{atgardbart} åtgärdbara fynd. Kör med --reparera för att utföra dem.")
            print("=" * 60)
            return

        _rubrik("Reparerar")
        antal = 0
        antal += reparera_prefix(cur, prefix_fynd)
        antal += reparera_metadata(cur, metadata_fynd)
        antal += reparera_srid(cur, srid_fynd)
        antal += reparera_afvaktande(cur, afvaktande_fynd)
        conn.commit()
        print(f"  {antal} rad(er) återställda.")

        # Underhållet måste köras EFTER att prefixen registrerats om: steg 10
        # läser hex_standardiserade_skyddsnivaer live, och det är först nu de
        # återförda schemana syns för GeoServer-notifieringen.
        print()
        fel = kor_underhall(cur, conn)
        if fel:
            skriv_varning(fel)

        print()
        print("=" * 60)
        print("Reparation klar.")
        if prefix_fynd:
            skriv_varning(
                "Återregistrerade prefix har publiceras_geoserver = false.\n"
                "Ska de publiceras till GeoServer: sätt värdet och kör\n"
                "SELECT * FROM public.hex_underhall(); så skickas notifieringen."
            )
        print("=" * 60)
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Diagnostiserar och reparerar en Hex-databas efter en"
                    " uppgradering som tappade inställningar och drifttillstånd."
    )
    parser.add_argument(
        "--reparera", action="store_true",
        help="Utför de härledbara åtgärderna (utan flaggan görs bara en diagnos)",
    )
    args = parser.parse_args()

    misslyckade = []
    for db in DATABASES:
        try:
            granska(db, reparera=args.reparera)
        except Exception as e:
            print(f"MISSLYCKADES: {_label(db)}: {e}")
            misslyckade.append(_label(db))

    if misslyckade:
        raise SystemExit(1)
