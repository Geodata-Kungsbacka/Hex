-- FUNCTION: public.validera_schemanamn()

CREATE OR REPLACE FUNCTION public.validera_schemanamn()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Validerar att nya scheman följer Hex namngivningskonvention.
 *
 * MÖNSTER: <skyddsnivå>_<datakategori>_<namn>
 *
 * Giltiga skyddsnivåer och datakategorier hämtas dynamiskt från:
 *   public.standardiserade_skyddsnivaer
 *   public.standardiserade_datakategorier
 *
 * Lägg till rader i dessa tabeller för att utöka giltiga kombinationer
 * utan att behöva ändra den här funktionen.
 *
 * EXEMPEL PÅ GILTIGA NAMN (med standardkonfiguration):
 *   sk0_ext_sgu
 *   sk1_kba_bygg
 *   sk2_sys_admin
 *   skx_kba_testprojekt
 *
 * UNDANTAG:
 *   - public
 *   - information_schema
 *   - pg_* (PostgreSQL-systemscheman)
 *
 * TRIGGER: Körs vid CREATE SCHEMA, innan rollskapande
 ******************************************************************************/
DECLARE
    kommando record;
    schema_namn text;
    schema_pattern text;
    skyddsniva_del text;
    datakategori_del text;
    antal_scheman integer := 0;
    valideringssteg text;
BEGIN
    RAISE NOTICE E'[validera_schemanamn] ======== START ========';
    RAISE NOTICE '[validera_schemanamn] Kontrollerar schemanamn mot Hex namngivningskonvention';

    -- Bygg regex-mönstret dynamiskt från konfigurationstabellerna
    valideringssteg := 'hämtar skyddsnivåer från standardiserade_skyddsnivaer';
    SELECT string_agg(prefix, '|' ORDER BY prefix) INTO skyddsniva_del
    FROM public.standardiserade_skyddsnivaer;

    valideringssteg := 'hämtar datakategorier från standardiserade_datakategorier';
    SELECT string_agg(prefix, '|' ORDER BY prefix) INTO datakategori_del
    FROM public.standardiserade_datakategorier;

    schema_pattern := '^(' || skyddsniva_del || ')_(' || datakategori_del || ')_.+$';

    RAISE NOTICE '[validera_schemanamn] Tillåtet mönster: %', schema_pattern;

    -- Steg 1: Hämta CREATE SCHEMA-kommandon
    valideringssteg := 'hämtar schema-kommandon';
    RAISE NOTICE E'[validera_schemanamn] --------------------------------------------------';
    RAISE NOTICE '[validera_schemanamn] Steg 1: Identifierar nya scheman från DDL-händelse';

    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        antal_scheman := antal_scheman + 1;
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

        RAISE NOTICE E'[validera_schemanamn] --------------------------------------------------';
        RAISE NOTICE '[validera_schemanamn] Bearbetar schema #%: %', antal_scheman, schema_namn;

        -- Steg 2: Kontrollera systemscheman
        valideringssteg := 'kontrollerar systemschema';
        RAISE NOTICE '[validera_schemanamn] Steg 2: Kontrollerar om systemschema';

        IF schema_namn = 'public' THEN
            RAISE NOTICE '[validera_schemanamn]   » Schema "public" är undantaget - hoppar över';
            CONTINUE;
        END IF;

        IF schema_namn = 'information_schema' THEN
            RAISE NOTICE '[validera_schemanamn]   » Schema "information_schema" är undantaget - hoppar över';
            CONTINUE;
        END IF;

        IF schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[validera_schemanamn]   » Schema "%" är PostgreSQL-systemschema - hoppar över', schema_namn;
            CONTINUE;
        END IF;

        RAISE NOTICE '[validera_schemanamn]   » Inte ett systemschema - fortsätter validering';

        -- Steg 3: Validera mot namnmönster
        valideringssteg := 'validerar namnmönster';
        RAISE NOTICE '[validera_schemanamn] Steg 3: Validerar mot namnmönster';
        RAISE NOTICE '[validera_schemanamn]   » Testar: "%" mot mönster "%"', schema_namn, schema_pattern;

        IF NOT schema_namn ~ schema_pattern THEN
            RAISE NOTICE '[validera_schemanamn]   ✗ Schema "%" matchar INTE mönstret', schema_namn;
            RAISE NOTICE '[validera_schemanamn] !!! VALIDERING MISSLYCKADES !!!';
            RAISE NOTICE '[validera_schemanamn] Transaktion kommer att rullas tillbaka';

            RAISE EXCEPTION
                E'[validera_schemanamn] Ogiltigt schemanamn: "%"\n'
                'Schemanamn måste följa mönstret: <skyddsnivå>_<datakategori>_<namn>\n\n'
                'Giltiga skyddsnivåer: %\n'
                'Giltiga datakategorier: %\n\n'
                'OBS: Undvik svenska tecken (åäö) i schemanamn.\n'
                'Använd istället ASCII-alternativ (a, a, o).\n\n'
                'Exempel:\n'
                '  sk0_ext_sgu\n'
                '  sk1_kba_bygg\n'
                '  sk2_sys_admin\n'
                '  skx_kba_testprojekt',
                schema_namn,
                skyddsniva_del,
                datakategori_del;
        END IF;

        RAISE NOTICE '[validera_schemanamn]   ✓ Schema "%" matchar mönstret', schema_namn;

        -- Steg 4: Sammanfattning för detta schema
        RAISE NOTICE '[validera_schemanamn] Steg 4: Validering slutförd för schema "%"', schema_namn;
        RAISE NOTICE '[validera_schemanamn]   » Skyddsnivå: %',
            (SELECT beskrivning FROM public.standardiserade_skyddsnivaer
             WHERE schema_namn LIKE prefix || '_%'
             LIMIT 1);
        RAISE NOTICE '[validera_schemanamn]   » Datakategori: %',
            (SELECT beskrivning FROM public.standardiserade_datakategorier
             WHERE schema_namn LIKE '%_' || prefix || '_%'
             LIMIT 1);
    END LOOP;

    -- Slutsammanfattning
    RAISE NOTICE E'[validera_schemanamn] --------------------------------------------------';
    RAISE NOTICE '[validera_schemanamn] Sammanfattning:';
    RAISE NOTICE '[validera_schemanamn]   » Antal scheman kontrollerade: %', antal_scheman;
    RAISE NOTICE '[validera_schemanamn]   » Status: Alla scheman godkända';
    RAISE NOTICE '[validera_schemanamn] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE E'[validera_schemanamn] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[validera_schemanamn] Senaste kontext:';
        RAISE NOTICE '[validera_schemanamn]   - Schema: %', COALESCE(schema_namn, 'okänt');
        RAISE NOTICE '[validera_schemanamn]   - Valideringssteg: %', COALESCE(valideringssteg, 'okänt');
        RAISE NOTICE '[validera_schemanamn] Tekniska feldetaljer:';
        RAISE NOTICE '[validera_schemanamn]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[validera_schemanamn]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE '[validera_schemanamn] ======== AVBRUTEN ========';
        -- Låt felet bubbla upp för rollback
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.validera_schemanamn()
    OWNER TO postgres;

COMMENT ON FUNCTION public.validera_schemanamn()
    IS 'Event trigger-funktion som validerar schemanamn mot Hex namngivningskonvention.
Tillåtna skyddsnivåer och datakategorier hämtas dynamiskt från
standardiserade_skyddsnivaer och standardiserade_datakategorier.
Blockerar skapande av scheman som inte matchar mönstret.
Systemscheman (public, information_schema, pg_*) undantas från validering.';
