-- FUNCTION: public.validera_schemanamn()

CREATE OR REPLACE FUNCTION public.validera_schemanamn()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Validerar att nya scheman följer Praxis namngivningskonvention.
 * 
 * MÖNSTER: sk[0-2]_(ext|kba|sys)_*
 * 
 * Där:
 *   sk0, sk1, sk2 = Säkerhetsnivå (0=öppen, 1=kommun, 2=begränsad)
 *   ext = Externa datakällor
 *   kba = Interna kommunala datakällor  
 *   sys = Systemdata
 *
 * EXEMPEL PÅ GILTIGA NAMN:
 *   sk0_ext_sgu
 *   sk1_kba_bygg
 *   sk2_sys_admin
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
    schema_pattern text := '^sk[012]_(ext|kba|sys)_.+$';
    antal_scheman integer := 0;
    valideringssteg text;
BEGIN
    RAISE NOTICE E'[validera_schemanamn] ======== START ========';
    RAISE NOTICE '[validera_schemanamn] Kontrollerar schemanamn mot Praxis namngivningskonvention';
    RAISE NOTICE '[validera_schemanamn] Förväntat mönster: sk[0-2]_(ext|kba|sys)_*';
    
    -- Steg 1: Hämta CREATE SCHEMA-kommandon
    valideringssteg := 'hämtar schema-kommandon';
    RAISE NOTICE E'[validera_schemanamn] --------------------------------------------------';
    RAISE NOTICE '[validera_schemanamn] Steg 1: Identifierar nya scheman från DDL-händelse';
    
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        antal_scheman := antal_scheman + 1;
        schema_namn := split_part(kommando.object_identity, '.', 1);
        
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
        
        IF schema_namn LIKE 'pg\_%' THEN
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
            
            RAISE EXCEPTION E'[validera_schemanamn] Ogiltigt schemanamn: "%"\n'
                'Schemanamn måste följa mönstret: sk[0-2]_(ext|kba|sys)_*\n\n'
                'Där:\n'
                '  sk0, sk1, sk2 = Säkerhetsnivå (0=öppen, 1=kommun, 2=begränsad)\n'
                '  ext = Externa datakällor\n'
                '  kba = Interna kommunala datakällor\n'
                '  sys = Systemdata\n\n'
                'Exempel:\n'
                '  sk0_ext_sgu\n'
                '  sk1_kba_bygg\n'
                '  sk2_sys_admin',
                schema_namn;
        END IF;
        
        RAISE NOTICE '[validera_schemanamn]   ✓ Schema "%" matchar mönstret', schema_namn;
        
        -- Steg 4: Sammanfattning för detta schema
        RAISE NOTICE '[validera_schemanamn] Steg 4: Validering slutförd för schema "%"', schema_namn;
        RAISE NOTICE '[validera_schemanamn]   » Säkerhetsnivå: %', substring(schema_namn from 3 for 1);
        RAISE NOTICE '[validera_schemanamn]   » Kategori: %', 
            CASE 
                WHEN schema_namn LIKE '%_ext_%' THEN 'extern datakälla'
                WHEN schema_namn LIKE '%_kba_%' THEN 'intern kommunal datakälla'
                WHEN schema_namn LIKE '%_sys_%' THEN 'systemdata'
                ELSE 'okänd'
            END;
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
    IS 'Event trigger-funktion som validerar schemanamn mot Praxis namngivningskonvention.
Blockerar skapande av scheman som inte matchar mönstret sk[0-2]_(ext|kba|sys)_*.
Systemscheman (public, information_schema, pg_*) undantas från validering.';
