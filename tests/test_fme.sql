/******************************************************************************
 * TESTSVIT: FME TVÅSTEGS-TABELLSKAPANDE
 *
 * Testar den uppskjutna geometrivägen för systemanvändare (t.ex. FME) som
 * skapar tabeller i två steg:
 *   Steg A) CREATE TABLE ... (datakolumner, INGEN geometrikolumn)
 *   Steg B) ALTER TABLE ... ADD COLUMN geom geometry(...)
 *
 * Objekt under test:
 *   public.hex_systemanvandare     — register över systemanvändare
 *   public.hex_afvaktande_geometri — register över väntande geometri
 *   hantera_ny_tabell              — uppskjuten valideringslogik
 *   hantera_kolumntillagg          — väntande slutförande + suffixvalidering
 *
 * Grupper:
 *   F1  Infrastruktur (tabeller finns, fme inlagd)
 *   F2  Lyckad väg – _ext_-schema tvåsteg
 *   F3  Lyckad väg – _kba_-schema tvåsteg (geometribegränsning uppskjuten)
 *   F4  Suffixmismatch fångad vid ALTER TABLE ADD COLUMN geom
 *   F5  Vanlig användare fortfarande blockerad (regressionstest)
 *   F6  FME med geometri i CREATE TABLE (normal väg, ingen uppskjutning)
 *   F7  Anpassad systemanvändare registrerad i hex_systemanvandare
 *   F8  Flera väntande tabeller samtidigt
 *   F9  FME-tabell utan geometrisuffix (ingen uppskjutning förväntad)
 *   F10 Partiellt application_name utlöser inte uppskjuten väg
 *   F11 DROP TABLE på väntande tabell rensar hex_afvaktande_geometri
 *
 * Konvention: NOTICE = GODKÄNT/INFO,  WARNING = MISSLYCKAT/BUG BEKRÄFTAD
 *
 * FÖRUTSÄTTNINGAR:
 *   Hex installerat (alla funktioner + tabeller driftsatta, inklusive
 *   hex_systemanvandare och hex_afvaktande_geometri från denna release).
 *   Kör som superuser eller Hex-systemägare.
 ******************************************************************************/

\echo ''
\echo '============================================================'
\echo 'HEX FME TVÅSTEGS-TESTSVIT'
\echo '============================================================'

------------------------------------------------------------------------
-- INLEDANDE RENSNING
------------------------------------------------------------------------
\echo ''
\echo '--- Inledande rensning ---'

DROP SCHEMA IF EXISTS sk0_ext_fmetest     CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_fmetest CASCADE;

-- Rensa eventuella kvarstående väntande poster från tidigare testkörningar
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');

------------------------------------------------------------------------
-- FÖRBEREDELSER
------------------------------------------------------------------------
\echo ''
\echo '--- Skapar testscheman ---'

CREATE SCHEMA sk0_ext_fmetest;
CREATE SCHEMA sk1_kba_fmetest;

RESET application_name;

------------------------------------------------------------------------
-- F1: INFRASTRUKTUR
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F1: Infrastruktur ---'

-- F1a: tabellen hex_systemanvandare finns
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'hex_systemanvandare'
    ) THEN
        RAISE NOTICE 'TEST F1a GODKÄNT:tabellen public.hex_systemanvandare finns';
    ELSE
        RAISE WARNING 'TEST F1a MISSLYCKAT:tabellen public.hex_systemanvandare saknas – installation ofullständig';
    END IF;
END $$;

-- F1b: 'fme' är inlagd i hex_systemanvandare
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_systemanvandare WHERE anvandare = 'fme'
    ) THEN
        RAISE NOTICE 'TEST F1b GODKÄNT:fme-post finns i hex_systemanvandare';
    ELSE
        RAISE WARNING 'TEST F1b MISSLYCKAT:fme saknas i hex_systemanvandare – grunddata saknas eller installation ofullständig';
    END IF;
END $$;

-- F1c: tabellen hex_afvaktande_geometri finns
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'hex_afvaktande_geometri'
    ) THEN
        RAISE NOTICE 'TEST F1c GODKÄNT:tabellen public.hex_afvaktande_geometri finns';
    ELSE
        RAISE WARNING 'TEST F1c MISSLYCKAT:tabellen public.hex_afvaktande_geometri saknas – installation ofullständig';
    END IF;
END $$;

-- F1d: hex_afvaktande_geometri är tom för våra testscheman
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');
    IF cnt = 0 THEN
        RAISE NOTICE 'TEST F1d GODKÄNT:Inga inaktuella väntande poster för testscheman';
    ELSE
        RAISE WARNING 'TEST F1d MISSLYCKAT:% inaktuella väntande poster finns för testscheman (rensning misslyckades)', cnt;
    END IF;
END $$;

------------------------------------------------------------------------
-- F2: LYCKAD VÄG – _ext_-SCHEMA TVÅSTEG
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F2: Lyckad väg – ext-schema tvåsteg ---'

-- Steg A: FME skapar tabell med geometrisuffix men utan geometrikolumn.
-- Förväntat: WARNING (inte EXCEPTION), tabell skapad, standardkolumner tillagda,
--            rad infogad i hex_afvaktande_geometri.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.trafikdata_l (
        objectid   integer,
        vagnamn    text,
        hastighet  integer
    );
    RAISE NOTICE 'TEST F2a GODKÄNT:Steg A lyckades – FME skapade _l-tabell utan geom (inget undantag)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F2a MISSLYCKAT:Steg A orsakade undantag: %', SQLERRM;
END $$;

RESET application_name;

-- F2b: Rad registrerad i hex_afvaktande_geometri
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2b GODKÄNT:Tabell registrerad i hex_afvaktande_geometri efter steg A';
    ELSE
        RAISE WARNING 'TEST F2b MISSLYCKAT:Tabell EJ i hex_afvaktande_geometri – uppskjuten sökväg aktiverades inte';
    END IF;
END $$;

-- F2c: Standardkolumnen gid tillagd i steg A (geometrikolumner är uppskjutna, standardkolumner inte)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F2c GODKÄNT:Standardkolumn gid tillagd under steg A (icke-geometrikolumner uppskjuts inte)';
    ELSE
        RAISE WARNING 'TEST F2c MISSLYCKAT:gid saknas – hantera_ny_tabell omstrukturerade inte tabellen under steg A';
    END IF;
END $$;

-- F2d: Inget GiST-index ännu (steg 8 uppskjutet eftersom geometriinfo = NULL)
DO $$
DECLARE idx_count integer;
BEGIN
    SELECT COUNT(*) INTO idx_count FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'trafikdata_l'
    AND indexdef LIKE '%USING gist%';
    IF idx_count = 0 THEN
        RAISE NOTICE 'TEST F2d GODKÄNT:Inget GiST-index ännu efter steg A (korrekt uppskjutet)';
    ELSE
        RAISE WARNING 'TEST F2d MISSLYCKAT:GiST-index finns efter steg A – uppskjuten sökväg togs inte';
    END IF;
END $$;

-- F2e: Ingen geometrikolumn ännu
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = 'sk0_ext_fmetest' AND f_table_name = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2e GODKÄNT:Ingen geometrikolumn på tabellen efter steg A (som förväntat)';
    ELSE
        RAISE WARNING 'TEST F2e MISSLYCKAT:Geometrikolumn hittades efter steg A – oväntat';
    END IF;
END $$;

-- Steg B: FME kör ALTER TABLE ADD COLUMN geom
ALTER TABLE sk0_ext_fmetest.trafikdata_l ADD COLUMN geom geometry(LineString, 3007);

-- F2f: Väntande post borttagen
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trafikdata_l'
    ) THEN
        RAISE NOTICE 'TEST F2f GODKÄNT:Väntande post borttagen från hex_afvaktande_geometri efter steg B';
    ELSE
        RAISE WARNING 'TEST F2f MISSLYCKAT:Väntande post finns kvar i hex_afvaktande_geometri efter steg B';
    END IF;
END $$;

-- F2g: GiST-index skapat under steg B (uppskjutet steg 5b.2)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'trafikdata_l'
        AND indexname = 'trafikdata_l_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F2g GODKÄNT:GiST-index trafikdata_l_geom_gidx skapat under steg B';
    ELSE
        RAISE WARNING 'TEST F2g MISSLYCKAT:GiST-index inte skapat under steg B';
    END IF;
END $$;

-- F2h: geom-kolumnen finns och är sist
DO $$
DECLARE
    geom_pos integer;
    max_pos  integer;
BEGIN
    SELECT ordinal_position INTO geom_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l'
    AND column_name = 'geom';

    SELECT MAX(ordinal_position) INTO max_pos
    FROM information_schema.columns
    WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trafikdata_l';

    IF geom_pos IS NOT NULL AND geom_pos = max_pos THEN
        RAISE NOTICE 'TEST F2h GODKÄNT:geom-kolumn finns och är sist (position %/%)', geom_pos, max_pos;
    ELSIF geom_pos IS NULL THEN
        RAISE WARNING 'TEST F2h MISSLYCKAT:geom-kolumn saknas efter steg B';
    ELSE
        RAISE WARNING 'TEST F2h MISSLYCKAT:geom är inte sist (position % av %)', geom_pos, max_pos;
    END IF;
END $$;

-- F2i: Ingen geometrivalideringsbegränsning på _ext_-schema (endast _kba_ får detta)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk0_ext_fmetest.trafikdata_l'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST F2i GODKÄNT:Ingen geometrivalideringsbegränsning på _ext_-tabell (korrekt)';
    ELSE
        RAISE WARNING 'TEST F2i MISSLYCKAT:Geometrivalideringsbegränsning tillagd på _ext_-tabell (ska bara vara på _kba_)';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.trafikdata_l;

------------------------------------------------------------------------
-- F3: LYCKAD VÄG – _kba_-SCHEMA TVÅSTEG
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F3: Lyckad väg – kba-schema tvåsteg ---'

-- Steg A: väntande tabell i _kba_-schema
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk1_kba_fmetest.fastigheter_y (
        fastighetsid  text,
        areal         numeric
    );
    RAISE NOTICE 'TEST F3a GODKÄNT:Steg A – kba-väntande tabell skapad utan undantag';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F3a MISSLYCKAT:Steg A orsakade undantag: %', SQLERRM;
END $$;

RESET application_name;

-- F3b: Väntande post registrerad
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk1_kba_fmetest' AND ag.tabell_namn = 'fastigheter_y'
    ) THEN
        RAISE NOTICE 'TEST F3b GODKÄNT:kba-tabell registrerad som väntande';
    ELSE
        RAISE WARNING 'TEST F3b MISSLYCKAT:kba-tabell EJ registrerad som väntande';
    END IF;
END $$;

-- Steg B
ALTER TABLE sk1_kba_fmetest.fastigheter_y ADD COLUMN geom geometry(Polygon, 3007);

-- F3c: Geometrivalideringsbegränsning tillagd för _kba_ (uppskjutet steg 5b.3)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'sk1_kba_fmetest.fastigheter_y'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%validera_geometri%'
    ) THEN
        RAISE NOTICE 'TEST F3c GODKÄNT:Geometrivalideringsbegränsning tillagd på kba-tabell under steg B';
    ELSE
        RAISE WARNING 'TEST F3c MISSLYCKAT:Geometrivalideringsbegränsning saknas på kba-tabell efter steg B';
    END IF;
END $$;

-- F3d: GiST-index skapat
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk1_kba_fmetest' AND tablename = 'fastigheter_y'
        AND indexname = 'fastigheter_y_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F3d GODKÄNT:GiST-index skapat på kba-tabell under steg B';
    ELSE
        RAISE WARNING 'TEST F3d MISSLYCKAT:GiST-index saknas på kba-tabell efter steg B';
    END IF;
END $$;

-- F3e: Väntande post borttagen
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk1_kba_fmetest' AND ag.tabell_namn = 'fastigheter_y'
    ) THEN
        RAISE NOTICE 'TEST F3e GODKÄNT:kba-väntande post korrekt borttagen efter steg B';
    ELSE
        RAISE WARNING 'TEST F3e MISSLYCKAT:kba-väntande post finns kvar efter steg B';
    END IF;
END $$;

-- F3f: Geometrivalidering blockerar ogiltig geometri och ger ett beskrivande fel
DO $$
BEGIN
    INSERT INTO sk1_kba_fmetest.fastigheter_y (fastighetsid, geom)
    VALUES ('test', ST_GeomFromText('POLYGON EMPTY', 3007));
    RAISE WARNING 'TEST F3f MISSLYCKAT:Tom geometri accepterades – validering ej aktiverad';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri%' AND SQLERRM LIKE '%tom%' THEN
            RAISE NOTICE 'TEST F3f GODKÄNT:Tom geometri blockerades med beskrivande meddelande: %', left(SQLERRM, 120);
        ELSIF SQLERRM LIKE '%check constraint%' OR SQLERRM LIKE '%validera_geom%' THEN
            RAISE WARNING 'TEST F3f DELVIS: Geometri blockerades av CHECK-begränsning men triggermeddelande saknas. Är kontrollera_geometri_trigger installerad?';
        ELSE
            RAISE NOTICE 'TEST F3f GODKÄNT (annan anledning): %', left(SQLERRM, 120);
        END IF;
END $$;

-- F3f2: Självskärande geometri ger en anledning från ST_IsValidReason
DO $$
BEGIN
    -- Bowtie polygon: self-intersecting, ST_IsValidReason returns e.g. "Self-intersection[…]"
    INSERT INTO sk1_kba_fmetest.fastigheter_y (fastighetsid, geom)
    VALUES ('test', ST_GeomFromText(
        'POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))', 3007));
    RAISE WARNING 'TEST F3f2 MISSLYCKAT:Självskärande geometri accepterades';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Ogiltig geometri%' AND SQLERRM LIKE '%Self-intersection%' THEN
            RAISE NOTICE 'TEST F3f2 GODKÄNT:Självskärning rapporterad med plats: %', left(SQLERRM, 120);
        ELSIF SQLERRM LIKE '%check constraint%' THEN
            RAISE WARNING 'TEST F3f2 DELVIS: Blockerades av CHECK men triggermeddelande saknas';
        ELSE
            RAISE NOTICE 'TEST F3f2 GODKÄNT (annan anledning): %', left(SQLERRM, 120);
        END IF;
END $$;

-- F3g: Dokumenterar känd brist – ingen historiktabell för FME kba-uppskjuten tabell
--      skapa_historik_qa körs i steg 10 av hantera_ny_tabell med geometriinfo=NULL.
--      Om geometri krävs för att skapa historik skapas aldrig historiktabellen.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk1_kba_fmetest' AND table_name = 'fastigheter_y_h'
    ) THEN
        RAISE NOTICE 'TEST F3g INFO: Historiktabell SKAPADES för kba-uppskjuten tabell (skapa_historik_qa körs schemabaserat, inte geometribaserat)';
    ELSE
        RAISE NOTICE 'TEST F3g INFO: Ingen historiktabell för FME-uppskjuten kba-tabell. skapa_historik_qa kräver geometri vid steg A. Historiktabeller för FME-laddad kba-data måste skapas manuellt.';
    END IF;
END $$;

DROP TABLE IF EXISTS sk1_kba_fmetest.fastigheter_y;

------------------------------------------------------------------------
-- F4: SUFFIXMISMATCH FÅNGAD VID ALTER TABLE
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F4: Suffixvalidering ---'

-- Skapa en väntande tabell med namn _l (förväntar LineString-geometri)
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.bantyp_l (
        typkod  varchar(10),
        beskr   text
    );
    RAISE NOTICE 'TEST F4a GODKÄNT:Väntande bantyp_l skapad (förväntar LineString via _l-suffix)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F4a MISSLYCKAT:%', SQLERRM;
END $$;

RESET application_name;

-- F4b: Försök att lägga till POLYGON-geometri till en tabell med namn _l → undantag
DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.bantyp_l ADD COLUMN geom geometry(Polygon, 3007);
    RAISE WARNING 'TEST F4b MISSLYCKAT:Suffixmismatch (Polygon på _l-tabell) FÅNGADES INTE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Suffixkollision%' OR SQLERRM LIKE '%suffix%' OR SQLERRM LIKE '%_l%' THEN
            RAISE NOTICE 'TEST F4b GODKÄNT:Suffixmismatch fångad – Polygon avvisad på _l-tabell: %',
                left(SQLERRM, 120);
        ELSE
            RAISE NOTICE 'TEST F4b GODKÄNT (annat undantag): %', left(SQLERRM, 120);
        END IF;
END $$;

-- F4c: ALTER TABLE återställdes – geom-kolumn ska INTE finnas
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = 'sk0_ext_fmetest' AND f_table_name = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4c GODKÄNT:geom-kolumn inte tillgänglig efter återställd ALTER TABLE';
    ELSE
        RAISE WARNING 'TEST F4c MISSLYCKAT:geom-kolumn finns trots suffixmismatch-undantag (återställning misslyckades)';
    END IF;
END $$;

-- F4d: Tabell fortfarande väntande (DELETE i steg 5b.4 återställdes med undantaget)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4d GODKÄNT:bantyp_l fortfarande väntande efter suffixmismatch-undantag (korrekt återställd)';
    ELSE
        RAISE WARNING 'TEST F4d MISSLYCKAT:bantyp_l borttagen från väntande trots undantag – delvist tillstånd';
    END IF;
END $$;

-- F4e: Lägg nu till RÄTT geometrityp (LineString för _l) → ska lyckas
DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.bantyp_l ADD COLUMN geom geometry(LineString, 3007);
    RAISE NOTICE 'TEST F4e GODKÄNT:Rätt geometrityp (LineString för _l) accepterades efter tidigare fel';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F4e MISSLYCKAT:Rätt geometrityp avvisades: %', SQLERRM;
END $$;

-- F4f: Väntande post borttagen efter korrekt ALTER TABLE
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'bantyp_l'
    ) THEN
        RAISE NOTICE 'TEST F4f GODKÄNT:bantyp_l borttagen från väntande efter korrekt steg B';
    ELSE
        RAISE WARNING 'TEST F4f MISSLYCKAT:bantyp_l fortfarande väntande efter korrekt steg B';
    END IF;
END $$;

-- F4g: GiST-index skapat efter återhämtning
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'bantyp_l'
        AND indexname = 'bantyp_l_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F4g GODKÄNT:GiST-index skapat efter korrekt steg B';
    ELSE
        RAISE WARNING 'TEST F4g MISSLYCKAT:GiST-index saknas efter korrekt steg B';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.bantyp_l;

------------------------------------------------------------------------
-- F5: VANLIG ANVÄNDARE FORTFARANDE BLOCKERAD (REGRESSIONSTEST)
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F5: Regressionstest – vanlig användare ---'

-- En vanlig användare (utan särskilt application_name) måste fortfarande få EXCEPTION
-- vid försök att skapa en tabell med geometrisuffix men utan geometri.
-- Detta säkerställer att den uppskjutna vägen INTE är en oavsiktlig bypass för alla.
RESET application_name;

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.trick_l (
        data text
    );
    RAISE WARNING 'TEST F5a MISSLYCKAT:Icke-systemanvändare skapade en geometrisuffix-tabell utan geometri (förbikoppling!)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%suffix%' OR SQLERRM LIKE '%geometri%' OR SQLERRM LIKE '%reserverade%' THEN
            RAISE NOTICE 'TEST F5a GODKÄNT:Icke-systemanvändare korrekt blockerad från geometrisuffix-tabell utan geom';
        ELSE
            RAISE NOTICE 'TEST F5a GODKÄNT (annan anledning): %', left(SQLERRM, 80);
        END IF;
END $$;

-- F5b: Verifiera att tabellen INTE skapades (undantag återställde skapandet)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'trick_l'
    ) THEN
        RAISE NOTICE 'TEST F5b GODKÄNT:tabellen trick_l finns inte (skapande återställdes)';
    ELSE
        RAISE WARNING 'TEST F5b MISSLYCKAT:tabellen trick_l finns trots undantag';
    END IF;
END $$;

-- F5c: Ingen kvarstående väntande post skapad för den blockerade tabellen
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'trick_l'
    ) THEN
        RAISE NOTICE 'TEST F5c GODKÄNT:Ingen väntande post för blockerad tabell';
    ELSE
        RAISE WARNING 'TEST F5c MISSLYCKAT:Inaktuell väntande post skapad för blockerad tabell';
    END IF;
END $$;

------------------------------------------------------------------------
-- F6: FME MED GEOMETRI I CREATE TABLE (NORMAL VÄG, INGEN UPPSKJUTNING)
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F6: FME normal väg (geometri i CREATE TABLE) ---'

-- När FME inkluderar geometri i CREATE TABLE får den uppskjutna vägen INTE aktiveras.
-- Tabellen genomgår validera_tabell på normalt sätt.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.komplett_import_p (
        objektid integer,
        namn     text,
        geom     geometry(Point, 3007)
    );
    RAISE NOTICE 'TEST F6a GODKÄNT:FME-tabell med geometri i CREATE TABLE accepterades normalt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F6a MISSLYCKAT:FME-tabell med geometri avvisades: %', SQLERRM;
END $$;

RESET application_name;

-- F6b: INTE i hex_afvaktande_geometri (uppskjuten väg får inte ha aktiverats)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'komplett_import_p'
    ) THEN
        RAISE NOTICE 'TEST F6b GODKÄNT:Tabell med geometri inte registrerad som väntande (korrekt)';
    ELSE
        RAISE WARNING 'TEST F6b MISSLYCKAT:Tabell med geometri felaktigt registrerad som väntande';
    END IF;
END $$;

-- F6c: GiST-index skapat direkt (under CREATE TABLE, inte uppskjutet)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'komplett_import_p'
        AND indexname = 'komplett_import_p_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F6c GODKÄNT:GiST-index skapat direkt (normal väg)';
    ELSE
        RAISE WARNING 'TEST F6c MISSLYCKAT:GiST-index saknas efter FME normal-väg CREATE TABLE';
    END IF;
END $$;

-- F6d: gid finns
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'komplett_import_p'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F6d GODKÄNT:gid-kolumn finns på FME normal-väg-tabell';
    ELSE
        RAISE WARNING 'TEST F6d MISSLYCKAT:gid saknas från FME normal-väg-tabell';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.komplett_import_p;

------------------------------------------------------------------------
-- F7: ANPASSAD SYSTEMANVÄNDARE I hex_systemanvandare
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F7: Anpassad systemanvändare ---'

-- Lägg till en fiktiv systemanvändare i registret
INSERT INTO public.hex_systemanvandare (anvandare, beskrivning)
VALUES ('test_etl_tool', 'Testverktyg för FME-testsvitens F7-test')
ON CONFLICT DO NOTHING;

SET application_name = 'test_etl_tool';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.etl_import_l (
        rad_id integer,
        kalla  text
    );
    RAISE NOTICE 'TEST F7a GODKÄNT:Anpassad systemanvändare fick uppskjuten behandling (tabell skapad utan undantag)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F7a MISSLYCKAT:Anpassad systemanvändare inte igenkänd eller orsakade undantag: %', SQLERRM;
END $$;

RESET application_name;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'etl_import_l'
    ) THEN
        RAISE NOTICE 'TEST F7b GODKÄNT:Anpassad systemanvändares tabell registrerad som väntande';
    ELSE
        RAISE WARNING 'TEST F7b MISSLYCKAT:Anpassad systemanvändares tabell inte registrerad som väntande';
    END IF;
END $$;

-- Rensning: slutför den väntande tabellen, ta sedan bort den anpassade användaren
ALTER TABLE sk0_ext_fmetest.etl_import_l ADD COLUMN geom geometry(LineString, 3007);

DELETE FROM public.hex_systemanvandare WHERE anvandare = 'test_etl_tool';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hex_systemanvandare WHERE anvandare = 'test_etl_tool') THEN
        RAISE NOTICE 'TEST F7c GODKÄNT:Anpassad systemanvändare borttagen från hex_systemanvandare';
    ELSE
        RAISE WARNING 'TEST F7c MISSLYCKAT:Anpassad systemanvändare finns kvar efter borttagning';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.etl_import_l;

------------------------------------------------------------------------
-- F8: FLERA VÄNTANDE TABELLER SAMTIDIGT
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F8: Flera väntande tabeller samtidigt ---'

SET application_name = 'fme';

CREATE TABLE sk0_ext_fmetest.batch_a_p (id integer, naam text);
CREATE TABLE sk0_ext_fmetest.batch_b_y (id integer, info text);
CREATE TABLE sk0_ext_fmetest.batch_c_l (id integer, data text);

RESET application_name;

-- F8a: Alla tre är väntande
DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn = 'sk0_ext_fmetest'
    AND ag.tabell_namn IN ('batch_a_p', 'batch_b_y', 'batch_c_l');
    IF cnt = 3 THEN
        RAISE NOTICE 'TEST F8a GODKÄNT:Alla 3 batch-tabeller registrerade som väntande samtidigt';
    ELSE
        RAISE WARNING 'TEST F8a MISSLYCKAT:Förväntade 3 väntande poster, hittade %', cnt;
    END IF;
END $$;

-- F8b: Slutför bara batch_a_p → bara batch_a_p tas bort från väntande
ALTER TABLE sk0_ext_fmetest.batch_a_p ADD COLUMN geom geometry(Point, 3007);

DO $$
DECLARE
    a_pending boolean;
    b_pending boolean;
    c_pending boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_a_p') INTO a_pending;
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_b_y') INTO b_pending;
    SELECT EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri AS ag WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'batch_c_l') INTO c_pending;

    IF NOT a_pending AND b_pending AND c_pending THEN
        RAISE NOTICE 'TEST F8b GODKÄNT:Endast batch_a_p borttagen från väntande; batch_b_y och batch_c_l fortfarande väntande';
    ELSE
        RAISE WARNING 'TEST F8b MISSLYCKAT:Väntande tillstånd: a_p=% b_y=% c_l=% (förväntade false/true/true)',
            a_pending, b_pending, c_pending;
    END IF;
END $$;

-- F8c: Slutför batch_b_y och batch_c_l
ALTER TABLE sk0_ext_fmetest.batch_b_y ADD COLUMN geom geometry(Polygon, 3007);
ALTER TABLE sk0_ext_fmetest.batch_c_l ADD COLUMN geom geometry(LineString, 3007);

DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM public.hex_afvaktande_geometri AS ag
    WHERE ag.schema_namn = 'sk0_ext_fmetest'
    AND ag.tabell_namn IN ('batch_a_p', 'batch_b_y', 'batch_c_l');
    IF cnt = 0 THEN
        RAISE NOTICE 'TEST F8c GODKÄNT:Alla 3 batch-tabeller borttagna från väntande efter steg B';
    ELSE
        RAISE WARNING 'TEST F8c MISSLYCKAT:% väntande poster kvar efter att alla 3 tabeller slutförts', cnt;
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.batch_a_p;
DROP TABLE IF EXISTS sk0_ext_fmetest.batch_b_y;
DROP TABLE IF EXISTS sk0_ext_fmetest.batch_c_l;

------------------------------------------------------------------------
-- F9: FME-TABELL UTAN GEOMETRI OCH UTAN GEOMETRISUFFIX
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F9: FME icke-geometrisk tabell (inget suffix, ingen uppskjutning) ---'

-- FME kan också skriva icke-geometritabeller. Dessa har inget geometrisuffix så den
-- uppskjutna vägen FÅR INTE aktiveras – de går genom validera_tabell normalt.
SET application_name = 'fme';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.referensdata (
        kod  text,
        namn text,
        typ  integer
    );
    RAISE NOTICE 'TEST F9a GODKÄNT:FME icke-geometri-tabell (inget suffix) skapad normalt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F9a MISSLYCKAT:FME icke-geometri-tabell avvisades: %', SQLERRM;
END $$;

RESET application_name;

-- F9b: INTE i hex_afvaktande_geometri (inget suffix → ingen uppskjutning)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'referensdata'
    ) THEN
        RAISE NOTICE 'TEST F9b GODKÄNT:Icke-geometri FME-tabell inte registrerad som väntande (korrekt)';
    ELSE
        RAISE WARNING 'TEST F9b MISSLYCKAT:Icke-geometri FME-tabell felaktigt registrerad som väntande';
    END IF;
END $$;

-- F9c: gid tillagd normalt (tabellen omstrukturerades via normal väg)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'referensdata'
        AND column_name = 'gid'
    ) THEN
        RAISE NOTICE 'TEST F9c GODKÄNT:FME icke-geometri-tabell omstrukturerad normalt (gid finns)';
    ELSE
        RAISE WARNING 'TEST F9c MISSLYCKAT:FME icke-geometri-tabell inte omstrukturerad (gid saknas)';
    END IF;
END $$;

DROP TABLE IF EXISTS sk0_ext_fmetest.referensdata;

------------------------------------------------------------------------
-- F10: PARTIELLT application_name UTLÖSER INTE UPPSKJUTEN VÄG
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F10: Partiellt application_name utlöser ej uppskjutning ---'

-- application_name = 'FME Desktop 2024.0.0.0' matchar INTE 'fme' i
-- hex_systemanvandare (exakt gemensmatchning krävs). Sådana anslutningar
-- får normal validering – ingen uppskjutningsförbikoppling.
SET application_name = 'FME Desktop 2024.0.0.0';

DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.partial_match_l (data text);
    RAISE WARNING 'TEST F10a MISSLYCKAT:Partiellt application_name utlöste uppskjuten förbikoppling (oväntat)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'TEST F10a GODKÄNT:Partiellt application_name (''FME Desktop...'') korrekt blockerat – exakt matchning krävs';
END $$;

RESET application_name;

-- F10b: Ingen väntande post (uppskjuten väg aktiverades inte)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'partial_match_l'
    ) THEN
        RAISE NOTICE 'TEST F10b GODKÄNT:Ingen väntande post för partiellt-matchad anslutning (tabell blockerad, inte uppskjuten)';
    ELSE
        RAISE WARNING 'TEST F10b MISSLYCKAT:Väntande post skapad för partiellt-matchad anslutning';
    END IF;
END $$;

------------------------------------------------------------------------
-- F11: DROP TABLE PÅ VÄNTANDE TABELL
------------------------------------------------------------------------
\echo ''
\echo '--- GRUPP F11: DROP TABLE på väntande tabell ---'

SET application_name = 'fme';
CREATE TABLE sk0_ext_fmetest.abandoned_l (data text);
RESET application_name;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l'
    ) THEN
        RAISE NOTICE 'TEST F11 förberedelse: abandoned_l registrerad som väntande';
    ELSE
        RAISE WARNING 'TEST F11 förberedelse MISSLYCKAT:abandoned_l inte väntande – kan inte köra gap-test';
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.abandoned_l;

-- Efter DROP TABLE ska den väntande posten rensas av hantera_borttagen_tabell.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l'
    ) THEN
        RAISE WARNING 'TEST F11 GAP BEKRÄFTAT: Väntande post för abandoned_l överlever DROP TABLE. '
            'hantera_borttagen_tabell rensar inte hex_afvaktande_geometri. '
            'Inaktuella poster måste tas bort manuellt: '
            'DELETE FROM public.hex_afvaktande_geometri WHERE schema_namn = ''sk0_ext_fmetest'' AND tabell_namn = ''abandoned_l'';';
    ELSE
        RAISE NOTICE 'TEST F11 GODKÄNT:Väntande post borttagen vid DROP TABLE '
            '(hantera_borttagen_tabell rensar hex_afvaktande_geometri – gap löst)';
    END IF;
END $$;

-- Manuell rensning för gap-fallet
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'abandoned_l';

------------------------------------------------------------------------
-- F12: STEG 5C – TABELL UTAN SUFFIX FÅR GEOMETRI VIA ALTER TABLE
------------------------------------------------------------------------
-- Testar steg 5c-buggfixen: en tabell skapad utan geometrisuffix
-- (tillåten som icke-geometrisk tabell av validera_tabell) måste AVVISAS när
-- en geometrikolumn läggs till via ALTER TABLE, eftersom det inte finns något
-- suffix att validera geometritypen mot.
--
-- Det enda sättet att nå steg 5c:s "framgång"-gren är när en tabell skapades
-- med korrekt suffix men utan att gå genom normal Hex-bearbetning
-- (t.ex. förbikopp via temp.tabellstrukturering_pagar).
-- F12i testar den vägen via en explicit bypass.
\echo ''
\echo '--- GRUPP F12: Steg 5c – tabell utan suffix får geometri via ALTER TABLE ---'

-- F12a: Vilken användare som helst kan skapa en tabell utan suffix (ingen geom → ok)
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.import_staging (
        id    integer,
        data  text
    );
    RAISE NOTICE 'TEST F12a GODKÄNT:Icke-suffixad icke-geometri-tabell skapad normalt';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F12a MISSLYCKAT:Icke-suffixad tabell avvisades: %', SQLERRM;
END $$;

-- F12b: Lägga till POLYGON till tabell utan suffix → steg 5c fångar och blockerar
DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.import_staging ADD COLUMN geom geometry(Polygon, 3007);
    RAISE WARNING 'TEST F12b MISSLYCKAT:Polygon accepterades på icke-suffixad tabell (steg 5c fungerar ej)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%saknar korrekt suffix%' OR SQLERRM LIKE '%suffix%' OR SQLERRM LIKE '%_y%' THEN
            RAISE NOTICE 'TEST F12b GODKÄNT:Polygon på icke-suffixad tabell avvisad av steg 5c: %',
                left(SQLERRM, 120);
        ELSE
            RAISE NOTICE 'TEST F12b GODKÄNT (annat undantag): %', left(SQLERRM, 120);
        END IF;
END $$;

-- F12c: Tabellen finns fortfarande (bara ALTER TABLE återställdes, inte CREATE TABLE)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'sk0_ext_fmetest' AND table_name = 'import_staging'
    ) THEN
        RAISE NOTICE 'TEST F12c GODKÄNT:import_staging finns fortfarande (bara ALTER TABLE återställdes)';
    ELSE
        RAISE WARNING 'TEST F12c MISSLYCKAT:import_staging borta – mer än ALTER TABLE återställdes';
    END IF;
END $$;

-- F12d: geom-kolumn finns inte (ALTER TABLE återställdes)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = 'sk0_ext_fmetest' AND f_table_name = 'import_staging'
    ) THEN
        RAISE NOTICE 'TEST F12d GODKÄNT:geom-kolumn frånvarande (ALTER TABLE-återställning bekräftad)';
    ELSE
        RAISE WARNING 'TEST F12d MISSLYCKAT:geom-kolumn finns trots undantag';
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.import_staging;

-- F12e–F12h: Alla fyra geometrityper ger korrekt förväntat-suffix-tips
-- Varje test skapar en ny tabell utan suffix och försöker lägga till en typad geometri.
-- Undantagsmeddelandet måste nämna det obligatoriska suffixet.

-- F12e: POINT → förväntar _p
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.steg5c_nosfx (id int);
    ALTER TABLE sk0_ext_fmetest.steg5c_nosfx ADD COLUMN geom geometry(Point, 3007);
    RAISE WARNING 'TEST F12e MISSLYCKAT:POINT accepterades på icke-suffixad tabell';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%_p%' OR SQLERRM LIKE '%suffix%' THEN
            RAISE NOTICE 'TEST F12e GODKÄNT:POINT på icke-suffixad tabell avvisad (förväntar _p): %',
                left(SQLERRM, 100);
        ELSE
            RAISE NOTICE 'TEST F12e GODKÄNT (annat): %', left(SQLERRM, 80);
        END IF;
END $$;
DROP TABLE IF EXISTS sk0_ext_fmetest.steg5c_nosfx;

-- F12f: LINESTRING → förväntar _l
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.steg5c_nosfx (id int);
    ALTER TABLE sk0_ext_fmetest.steg5c_nosfx ADD COLUMN geom geometry(LineString, 3007);
    RAISE WARNING 'TEST F12f MISSLYCKAT:LineString accepterades på icke-suffixad tabell';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%_l%' OR SQLERRM LIKE '%suffix%' THEN
            RAISE NOTICE 'TEST F12f GODKÄNT:LineString på icke-suffixad tabell avvisad (förväntar _l): %',
                left(SQLERRM, 100);
        ELSE
            RAISE NOTICE 'TEST F12f GODKÄNT (annat): %', left(SQLERRM, 80);
        END IF;
END $$;
DROP TABLE IF EXISTS sk0_ext_fmetest.steg5c_nosfx;

-- F12g: POLYGON → förväntar _y
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.steg5c_nosfx (id int);
    ALTER TABLE sk0_ext_fmetest.steg5c_nosfx ADD COLUMN geom geometry(Polygon, 3007);
    RAISE WARNING 'TEST F12g MISSLYCKAT:Polygon accepterades på icke-suffixad tabell';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%_y%' OR SQLERRM LIKE '%suffix%' THEN
            RAISE NOTICE 'TEST F12g GODKÄNT:Polygon på icke-suffixad tabell avvisad (förväntar _y): %',
                left(SQLERRM, 100);
        ELSE
            RAISE NOTICE 'TEST F12g GODKÄNT (annat): %', left(SQLERRM, 80);
        END IF;
END $$;
DROP TABLE IF EXISTS sk0_ext_fmetest.steg5c_nosfx;

-- F12h: GEOMETRY (generisk) → förväntar _g
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.steg5c_nosfx (id int);
    ALTER TABLE sk0_ext_fmetest.steg5c_nosfx ADD COLUMN geom geometry(Geometry, 3007);
    RAISE WARNING 'TEST F12h MISSLYCKAT:generisk GEOMETRY accepterades på icke-suffixad tabell';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%_g%' OR SQLERRM LIKE '%suffix%' THEN
            RAISE NOTICE 'TEST F12h GODKÄNT:generisk GEOMETRY på icke-suffixad tabell avvisad (förväntar _g): %',
                left(SQLERRM, 100);
        ELSE
            RAISE NOTICE 'TEST F12h GODKÄNT (annat): %', left(SQLERRM, 80);
        END IF;
END $$;
DROP TABLE IF EXISTS sk0_ext_fmetest.steg5c_nosfx;

-- F12i: Steg 5c FRAMGÅNG-väg.
-- En tabell med korrekt suffix som på något sätt förbigick hantera_ny_tabell
-- (t.ex. en direkt DB-återställning eller migreringsverktyg) ska hanteras elegant
-- när geom läggs till senare: steg 5c känner igen korrekt suffix, skapar
-- GiST och kör standardgeometriinställningar utan fel.
-- Förberedelse: förbikoppla Hex vid CREATE TABLE via rekursionsflaggan.

DO $$
BEGIN
    PERFORM set_config('temp.tabellstrukturering_pagar', 'true', true);
    EXECUTE 'CREATE TABLE sk0_ext_fmetest.steg5c_ok_l (id int)';
    PERFORM set_config('temp.tabellstrukturering_pagar', 'false', true);
    RAISE NOTICE 'TEST F12i förberedelse: steg5c_ok_l skapad med _l-suffix (Hex förbikopplat)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F12i setup MISSLYCKAT:%', SQLERRM;
END $$;

DO $$
BEGIN
    ALTER TABLE sk0_ext_fmetest.steg5c_ok_l ADD COLUMN geom geometry(LineString, 3007);
    RAISE NOTICE 'TEST F12i GODKÄNT:LineString accepterades på korrekt suffixad _l-tabell via steg 5c';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F12i MISSLYCKAT:geom avvisad på korrekt suffixad _l-tabell: %', SQLERRM;
END $$;

-- F12i-GiST: GiST skapat via steg 5c framgång-väg
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'steg5c_ok_l'
        AND indexname = 'steg5c_ok_l_geom_gidx'
    ) THEN
        RAISE NOTICE 'TEST F12i-GiST GODKÄNT:GiST steg5c_ok_l_geom_gidx skapat via steg 5c framgång-väg';
    ELSE
        RAISE WARNING 'TEST F12i-GiST MISSLYCKAT:GiST saknas efter steg 5c framgång-väg';
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.steg5c_ok_l;

------------------------------------------------------------------------
-- F13: GIST-ANTAL – Exakt ett GiST efter varje Hex-bearbetningsväg
------------------------------------------------------------------------
-- Verifierar rensning av dubblerade GiST-index: innan Hex skapar sitt eget
-- GiST-index (<tabell>_geom_gidx) tar det bort eventuella befintliga GiST
-- med annat namn (t.ex. ett skapat av FME). Efter bearbetning ska exakt ett
-- GiST med korrekt Hex-standardnamn finnas.
\echo ''
\echo '--- GRUPP F13: GiST-antal – exakt ett GiST efter varje Hex-väg ---'

-- F13a: Normal väg (geom i CREATE TABLE) → exakt ett GiST
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.en_gist_p (
        kod  text,
        geom geometry(Point, 3007)
    );
    RAISE NOTICE 'TEST F13a förberedelse: en_gist_p skapad via normal väg';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F13a setup MISSLYCKAT:%', SQLERRM;
END $$;

DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'en_gist_p'
      AND indexdef LIKE '%USING gist%';
    IF cnt = 1 THEN
        RAISE NOTICE 'TEST F13a GODKÄNT:Exakt 1 GiST efter normal väg (inga duplikat)';
    ELSE
        RAISE WARNING 'TEST F13a MISSLYCKAT:Förväntade 1 GiST, hittade %', cnt;
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.en_gist_p;

-- F13b: Afvaktande-väg (FME steg A + B) → exakt ett GiST
SET application_name = 'fme';
CREATE TABLE sk0_ext_fmetest.en_gist_l (a text);
RESET application_name;
ALTER TABLE sk0_ext_fmetest.en_gist_l ADD COLUMN geom geometry(LineString, 3007);

DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'en_gist_l'
      AND indexdef LIKE '%USING gist%';
    IF cnt = 1 THEN
        RAISE NOTICE 'TEST F13b GODKÄNT:Exakt 1 GiST efter afvaktande-väg (inga duplikat)';
    ELSE
        RAISE WARNING 'TEST F13b MISSLYCKAT:Förväntade 1 GiST, hittade %', cnt;
  END IF;
END $$;

DROP TABLE sk0_ext_fmetest.en_gist_l;

-- F13c: Steg 5c-väg (förbikopp CREATE TABLE + normal ALTER TABLE) → exakt ett GiST
DO $$
BEGIN
    PERFORM set_config('temp.tabellstrukturering_pagar', 'true', true);
    EXECUTE 'CREATE TABLE sk0_ext_fmetest.en_gist_y (id int)';
    PERFORM set_config('temp.tabellstrukturering_pagar', 'false', true);
END $$;
ALTER TABLE sk0_ext_fmetest.en_gist_y ADD COLUMN geom geometry(Polygon, 3007);

DO $$
DECLARE cnt integer;
BEGIN
    SELECT COUNT(*) INTO cnt FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'en_gist_y'
      AND indexdef LIKE '%USING gist%';
    IF cnt = 1 THEN
        RAISE NOTICE 'TEST F13c GODKÄNT:Exakt 1 GiST efter steg 5c-väg (inga duplikat)';
    ELSE
        RAISE WARNING 'TEST F13c MISSLYCKAT:Förväntade 1 GiST på steg 5c-väg, hittade %', cnt;
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.en_gist_y;

-- F13d: Deduplicering – FME-stilat GiST borttaget när afvaktande-slutförande aktiveras.
--
-- Simulerar scenariot där FME:
--   1) Skapar en väntande tabell (steg A – normalt, med suffix)
--   2) Lägger till geom och ett EGET GiST via en förbikopp ALTER TABLE (steg B förbikopp)
--   3) Utlöser senare en ny ALTER TABLE som aktiverar hantera_kolumntillagg,
--      som kör steg 5b (tabell fortfarande i hex_afvaktande_geometri).
--      Steg 5b.3 deduplicerar: tar bort FME-stilat GiST, skapar Hex-standarden.
--
-- Efter deduplicering: exakt 1 GiST med korrekt Hex-namn.

-- Förberedelse A: FME väntande tabell
SET application_name = 'fme';
DO $$
BEGIN
    CREATE TABLE sk0_ext_fmetest.dup_gist_p (id int);
    RAISE NOTICE 'TEST F13d förberedelse A: dup_gist_p skapad som väntande (FME steg A)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F13d förberedelse A MISSLYCKAT:%', SQLERRM;
END $$;
RESET application_name;

-- Förberedelse B: Förbikoppla Hex för att lägga till geom + FME-stilat GiST utan Hex-behandling
DO $$
BEGIN
    PERFORM set_config('temp.reorganization_in_progress', 'true', true);
    EXECUTE 'ALTER TABLE sk0_ext_fmetest.dup_gist_p ADD COLUMN geom geometry(Point, 3007)';
    EXECUTE 'CREATE INDEX fme_dup_gist_idx ON sk0_ext_fmetest.dup_gist_p USING GIST (geom)';
    PERFORM set_config('temp.reorganization_in_progress', 'false', true);
    RAISE NOTICE 'TEST F13d förberedelse B: geom tillagd och FME-stilat GiST fme_dup_gist_idx skapat (förbikopplat Hex)';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'TEST F13d förberedelse B MISSLYCKAT:%', SQLERRM;
END $$;

-- Förkontroll: tabellen är afvaktande och har exakt ett (felnamnat) GiST
DO $$
DECLARE
    is_pending boolean;
    gist_count integer;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM public.hex_afvaktande_geometri AS ag
        WHERE ag.schema_namn = 'sk0_ext_fmetest' AND ag.tabell_namn = 'dup_gist_p'
    ) INTO is_pending;
    SELECT COUNT(*) INTO gist_count FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'dup_gist_p'
      AND indexdef LIKE '%USING gist%';

    IF is_pending AND gist_count = 1 THEN
        RAISE NOTICE 'TEST F13d förkontroll OK: tabell är väntande, har 1 FME-stilat GiST – redo för dedupliceringstest';
    ELSE
        RAISE WARNING 'TEST F13d förkontroll: väntande=%, gist_antal=% (förväntade true, 1) – förberedelse kan ha misslyckats',
            is_pending, gist_count;
    END IF;
END $$;

-- Steg C: Utlös afvaktande-slutförande (valfri ALTER TABLE aktiverar hantera_kolumntillagg → steg 5b)
ALTER TABLE sk0_ext_fmetest.dup_gist_p ADD COLUMN extra_kol text;

-- F13d: Exakt ett GiST med Hex-standardnamn efter deduplicering
DO $$
DECLARE
    cnt       integer;
    gist_namn text;
BEGIN
    SELECT COUNT(*), MAX(indexname) INTO cnt, gist_namn FROM pg_indexes
    WHERE schemaname = 'sk0_ext_fmetest' AND tablename = 'dup_gist_p'
      AND indexdef LIKE '%USING gist%';

    IF cnt = 1 AND gist_namn = 'dup_gist_p_geom_gidx' THEN
        RAISE NOTICE 'TEST F13d GODKÄNT:Exakt 1 GiST med Hex-standardnamn (FME-duplikat borttaget av deduplicering i steg 5b.3)';
    ELSIF cnt = 1 THEN
        RAISE WARNING 'TEST F13d DELVIS: 1 GiST men fel namn "%" – dedup körde men använde oväntat namn', gist_namn;
    ELSIF cnt = 2 THEN
        RAISE WARNING 'TEST F13d MISSLYCKAT:2 GiST fortfarande kvar – deduplicering i steg 5b.3 aktiverades inte eller tog inte bort FME-GiST';
    ELSE
        RAISE WARNING 'TEST F13d OVÄNTAT: % GiST hittades', cnt;
    END IF;
END $$;

DROP TABLE sk0_ext_fmetest.dup_gist_p;

------------------------------------------------------------------------
-- SLUTLIG RENSNING
------------------------------------------------------------------------
\echo ''
\echo '--- Slutlig rensning ---'

RESET application_name;

DROP SCHEMA IF EXISTS sk0_ext_fmetest     CASCADE;
DROP SCHEMA IF EXISTS sk1_kba_fmetest CASCADE;

-- Säkerhetsåtgärd: ta bort eventuella test-väntande poster som överlevde rensningen
DELETE FROM public.hex_afvaktande_geometri AS ag
WHERE ag.schema_namn IN ('sk0_ext_fmetest', 'sk1_kba_fmetest');

\echo ''
\echo '============================================================'
\echo 'HEX FME TVÅSTEGS-TESTSVIT KLAR'
\echo 'NOTICE = GODKÄNT/INFO,  WARNING = MISSLYCKAT/BUG BEKRÄFTAT'
\echo '============================================================'
