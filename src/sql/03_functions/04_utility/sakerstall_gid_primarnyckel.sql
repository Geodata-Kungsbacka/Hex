CREATE OR REPLACE FUNCTION public.sakerstall_gid_primarnyckel(
    p_schema_namn text,
    p_tabell_namn text
)
    RETURNS text
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Säkerställer att gid-kolumnen har en unik nyckel (PRIMARY KEY) och att
 * sekvensen ligger före högsta befintliga gid.
 *
 * BAKGRUND
 * Hex har historiskt skapat gid som "integer NOT NULL GENERATED ALWAYS AS
 * IDENTITY" utan PRIMARY KEY – aterskapa_tabellregler() tar medvetet bort
 * inkommande PK-constraints, men ingen egen PK har lagts tillbaka. Utan unikt
 * index uppstår tre problem:
 *
 *   1. QGIS hittar inte sekvensen. QGIS letar upp nextval() för en
 *      IDENTITY-kolumn först när kolumnen är NOT NULL *och* har ett unikt
 *      index (qgspostgresprovider.cpp, loadFields). Utan index får QGIS inget
 *      defaultvärde, och gid presenteras i attributformuläret som ett tomt
 *      obligatoriskt fält – OK-knappen är blockerad tills användaren skriver
 *      in ett gid som sedan ändå kastas av hex_tvinga_gid.
 *
 *   2. Dubbletter kan uppstå tyst. tvinga_gid_fran_sekvens() jämför klientens
 *      gid med currval(); råkar värdena sammanfalla behålls klientens värde.
 *      Utan unikt index skrivs dubbletten utan fel.
 *
 *   3. Sekventiell scanning vid varje redigering. QGIS använder gid som
 *      objekt-id och kör "... WHERE gid = N" per ändrad rad.
 *
 * FUNKTIONEN
 * Idempotent. Kan köras om hur många gånger som helst.
 *   - Synkroniserar sekvensen till max(gid) om den ligger efter.
 *   - Lägger till PRIMARY KEY (gid) om tabellen saknar unikt index på gid.
 *   - Har tabellen redan en PK på andra kolumner läggs UNIQUE (gid) till
 *     istället (en tabell kan bara ha en primärnyckel).
 *   - Rör ALDRIG data. Finns dubbletter returneras 'dubbletter: N' och
 *     tabellen lämnas orörd – kör public.reparera_gid_dubbletter() manuellt.
 *
 * Returvärde: 'skapad', 'unik skapad', 'redan finns', 'saknar gid',
 *             'dubbletter: N' eller 'fel: <meddelande>'.
 *
 * LÅSNING
 * ALTER TABLE ... ADD PRIMARY KEY tar ACCESS EXCLUSIVE-lås och bygger index.
 * På en stor tabell blockerar det läsning och skrivning under bygget. Kostnaden
 * tas en gång per tabell – därefter returnerar funktionen 'redan finns' utan
 * att röra tabellen. Planera därför den första körningen av underhall_hex()
 * efter uppgraderingen till ett servicefönster om databasen har stora tabeller.
 ******************************************************************************/
DECLARE
    tabell_oid    oid;
    seq_namn      text;
    max_gid       bigint;
    seq_last      bigint;
    seq_called    boolean;
    antal_dubbl   bigint;
    har_unik_gid  boolean;
    har_pk        boolean;
BEGIN
    SELECT c.oid
    INTO   tabell_oid
    FROM   pg_class     c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = p_schema_namn
      AND  c.relname = p_tabell_namn
      AND  c.relkind = 'r';

    IF tabell_oid IS NULL THEN
        RETURN 'saknar gid';
    END IF;

    -- Endast tabeller med en riktig gid IDENTITY-kolumn omfattas.
    IF NOT EXISTS (
        SELECT 1
        FROM   pg_attribute a
        WHERE  a.attrelid    = tabell_oid
          AND  a.attname     = 'gid'
          AND  a.attidentity != ''
          AND  NOT a.attisdropped
    ) THEN
        RETURN 'saknar gid';
    END IF;

    -- -------------------------------------------------------------------------
    -- Steg 1: Synkronisera sekvensen mot högsta befintliga gid.
    --
    -- Data som lästs in med OVERRIDING SYSTEM VALUE (FME, pg_restore) kan ha
    -- gid-värden ovanför sekvensen. Så länge inget unikt index finns märks det
    -- inte – men i samma sekund vi lägger på en PK skulle nästa INSERT falla på
    -- en dubblettnyckel. Därför måste sekvensen flyttas fram FÖRE constrainten.
    -- -------------------------------------------------------------------------
    seq_namn := pg_get_serial_sequence(
        format('%I.%I', p_schema_namn, p_tabell_namn), 'gid'
    );

    IF seq_namn IS NOT NULL THEN
        EXECUTE format('SELECT max(gid) FROM %I.%I', p_schema_namn, p_tabell_namn)
        INTO max_gid;

        IF max_gid IS NOT NULL THEN
            EXECUTE format('SELECT last_value, is_called FROM %s', seq_namn)
            INTO seq_last, seq_called;

            IF max_gid > seq_last OR (max_gid = seq_last AND NOT seq_called) THEN
                PERFORM setval(seq_namn, max_gid);
                RAISE NOTICE '[sakerstall_gid_primarnyckel] Sekvens % framflyttad till %',
                    seq_namn, max_gid;
            END IF;
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- Steg 2: Finns redan ett enkolumns unikt index på gid?
    --
    -- Jämförelsen indkey::text = attnum::text är samma test som QGIS själv gör
    -- (en int2vector med ett element textas som just det talet). Genom att
    -- använda exakt samma villkor garanterar vi att QGIS ser det index vi
    -- skapar.
    -- -------------------------------------------------------------------------
    SELECT EXISTS (
        SELECT 1
        FROM   pg_index     i
        JOIN   pg_attribute a ON a.attrelid = i.indrelid
                             AND a.attnum::text = i.indkey::text
        WHERE  i.indrelid = tabell_oid
          AND  i.indisunique
          AND  a.attname  = 'gid'
    ) INTO har_unik_gid;

    IF har_unik_gid THEN
        RETURN 'redan finns';
    END IF;

    -- -------------------------------------------------------------------------
    -- Steg 3: Blockera på dubbletter istället för att ändra användarens data.
    -- -------------------------------------------------------------------------
    EXECUTE format(
        'SELECT count(*) FROM (SELECT gid FROM %I.%I GROUP BY gid HAVING count(*) > 1) d',
        p_schema_namn, p_tabell_namn
    ) INTO antal_dubbl;

    IF antal_dubbl > 0 THEN
        -- RAISE känner bara till platshållaren %, inte format():s %L, så
        -- literalerna citeras explicit för att hinten ska bli körbar SQL.
        RAISE WARNING '[sakerstall_gid_primarnyckel] %.% har % gid-värden med dubbletter. '
            'Ingen nyckel lagd. Kör: SELECT * FROM public.reparera_gid_dubbletter(%, %, true);',
            p_schema_namn, p_tabell_namn, antal_dubbl,
            quote_literal(p_schema_namn), quote_literal(p_tabell_namn);
        RETURN format('dubbletter: %s', antal_dubbl);
    END IF;

    -- -------------------------------------------------------------------------
    -- Steg 4: Lägg på nyckeln. Constraintnamnet lämnas åt PostgreSQL, som
    -- trunkerar och unikgör (<tabell>_pkey / <tabell>_gid_key) på egen hand –
    -- viktigt eftersom tabellnamn kan ligga nära 63-teckengränsen.
    -- -------------------------------------------------------------------------
    SELECT EXISTS (
        SELECT 1 FROM pg_index WHERE indrelid = tabell_oid AND indisprimary
    ) INTO har_pk;

    BEGIN
        IF har_pk THEN
            -- Tabellen har redan en primärnyckel på andra kolumner (t.ex. en
            -- UNIQUE/PK som återskapats av aterskapa_tabellregler). Ett unikt
            -- index räcker för både QGIS och dubblettskyddet.
            EXECUTE format('ALTER TABLE %I.%I ADD UNIQUE (gid)',
                p_schema_namn, p_tabell_namn);
            RAISE NOTICE '[sakerstall_gid_primarnyckel]   ✓ UNIQUE (gid) skapad på %.%',
                p_schema_namn, p_tabell_namn;
            RETURN 'unik skapad';
        ELSE
            EXECUTE format('ALTER TABLE %I.%I ADD PRIMARY KEY (gid)',
                p_schema_namn, p_tabell_namn);
            RAISE NOTICE '[sakerstall_gid_primarnyckel]   ✓ PRIMARY KEY (gid) skapad på %.%',
                p_schema_namn, p_tabell_namn;
            RETURN 'skapad';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Nyckeln är en förbättring, inte ett krav för att tabellen ska fungera.
        -- Ett fel här får aldrig fälla hela CREATE TABLE eller hela underhållet.
        RAISE WARNING '[sakerstall_gid_primarnyckel] Kunde inte skapa nyckel på %.%: %',
            p_schema_namn, p_tabell_namn, SQLERRM;
        RETURN format('fel: %s', SQLERRM);
    END;
END;
$BODY$;

ALTER FUNCTION public.sakerstall_gid_primarnyckel(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.sakerstall_gid_primarnyckel(text, text)
    IS 'Lägger till PRIMARY KEY (gid) på en Hex-tabell och synkroniserar
gid-sekvensen mot max(gid). Utan unikt index hittar QGIS inte kolumnens
nextval()-default och kräver då att användaren fyller i gid manuellt, samtidigt
som dubbletter kan skrivas tyst. Idempotent; ändrar aldrig data. Finns
dubbletter returneras "dubbletter: N" och nyckeln hoppas över – använd
reparera_gid_dubbletter() först.';
