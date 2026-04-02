-- FUNCTION: public.blockera_schema_namnbyte()

CREATE OR REPLACE FUNCTION public.blockera_schema_namnbyte()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$

/******************************************************************************
 * Blockerar ALTER SCHEMA ... RENAME TO.
 *
 * BAKGRUND:
 *   Ett schemanamn i Hex är inte bara en etikett – det är identitetsnyckeln
 *   för ett helt ekosystem av beroenden. Att döpa om ett schema river sönder
 *   alla dessa kopplingar utan att systemet kan återställa dem automatiskt:
 *
 *   1. GeoServer-workspace – namnges identiskt med schemat (sk0_kba_bygg →
 *      workspace "sk0_kba_bygg"). Efter ett namnbyte är workspace föräldralös
 *      och nya schemat saknar workspace. Lager försvinner från WMS/WFS.
 *
 *   2. Databasroller – skapas från mall: r_{schema} och w_{schema}
 *      (t.ex. r_sk0_kba_bygg, w_sk0_kba_bygg). Efter namnbyte pekar rollerna
 *      på ett schema som inte längre finns, och nya schemat saknar roller –
 *      ingen kan ansluta, GeoServer kan inte autentisera.
 *
 *   3. hex_role_credentials – lösenord lagras med rollnamnet som nyckel.
 *      GeoServer-lyssnaren hittar inte autentiseringsuppgifter för det
 *      nya schemanamnet och misslyckas med att konfigurera datastoren.
 *
 *   4. hex_metadata – parent_schema lagras som text. Tabellerna i schemat
 *      tappar kopplingen till sina historiktabeller och triggar.
 *
 *   5. Skyddsnivå och datakategori – båda kodas in i schemanamnet
 *      (sk0_kba_bygg: skyddsnivå=sk0, kategori=kba). Det är omöjligt att
 *      validera att ett nytt namn är konsistent med befintligt innehåll.
 *
 * RÄTT TILLVÄGAGÅNGSSÄTT:
 *   DROP SCHEMA <gammalt_namn> CASCADE  →  Hex städar upp roller och GeoServer
 *   CREATE SCHEMA <nytt_namn>           →  Hex etablerar nytt ekosystem från noll
 *
 * TRIGGER: Körs vid ALTER SCHEMA, kontrollerar om satsen är ett RENAME
 ******************************************************************************/
DECLARE
    kommando        record;
    schema_namn     text;
BEGIN
    RAISE NOTICE E'[blockera_schema_namnbyte] ======== START ========';
    RAISE NOTICE '[blockera_schema_namnbyte] Kontrollerar ALTER SCHEMA-sats';

    -- Kontrollera om detta är ett RENAME-kommando
    IF current_query() ~* '\mRENAME\s+TO\M' THEN

        -- Hämta schemanamnet från DDL-händelsen
        FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
            WHERE command_tag = 'ALTER SCHEMA'
        LOOP
            schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

            RAISE NOTICE '[blockera_schema_namnbyte] RENAME TO detekterat för schema: %', schema_namn;
            RAISE NOTICE '[blockera_schema_namnbyte] !!! BLOCKERAR NAMNBYTE !!!';

            RAISE EXCEPTION
                E'[blockera_schema_namnbyte] ALTER SCHEMA ... RENAME TO är inte tillåtet i Hex.\n\n'
                'Schemanamnet är identitetsnyckeln för ett helt ekosystem av beroenden:\n'
                '  • GeoServer-workspace (namnges identiskt med schemat)\n'
                '  • Databasroller r_%% och w_%% (härleds från schemanamnet)\n'
                '  • Autentiseringsuppgifter i hex_role_credentials\n'
                '  • Schemanamn i hex_metadata (parent_schema)\n\n'
                'Ett namnbyte river sönder alla dessa kopplingar utan möjlighet\n'
                'till automatisk återställning.\n\n'
                'Rätt tillvägagångssätt:\n'
                '  1. DROP SCHEMA % CASCADE   -- Hex städar upp roller och GeoServer\n'
                '  2. CREATE SCHEMA <nytt_namn>  -- Hex etablerar nytt ekosystem',
                schema_namn;
        END LOOP;

    END IF;

    RAISE NOTICE '[blockera_schema_namnbyte] Ingen RENAME TO-sats – tillåter ALTER SCHEMA';
    RAISE NOTICE E'[blockera_schema_namnbyte] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE E'[blockera_schema_namnbyte] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[blockera_schema_namnbyte]   - Schema: %', COALESCE(schema_namn, 'okänt');
        RAISE NOTICE '[blockera_schema_namnbyte]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[blockera_schema_namnbyte]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE E'[blockera_schema_namnbyte] ======== AVBRUTEN ========';
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.blockera_schema_namnbyte()
    OWNER TO postgres;

COMMENT ON FUNCTION public.blockera_schema_namnbyte()
    IS 'Event trigger-funktion som blockerar ALTER SCHEMA ... RENAME TO.
Schemanamnet är identitetsnyckeln för GeoServer-workspace, databasroller,
autentiseringsuppgifter i hex_role_credentials och poster i hex_metadata.
Ett namnbyte river sönder alla dessa kopplingar. Rätt tillvägagångssätt
är DROP SCHEMA CASCADE följt av CREATE SCHEMA med det nya namnet.';
