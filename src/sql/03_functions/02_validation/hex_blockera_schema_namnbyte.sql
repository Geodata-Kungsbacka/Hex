-- FUNCTION: public.hex_blockera_schema_namnbyte()

CREATE OR REPLACE FUNCTION public.hex_blockera_schema_namnbyte()
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
 *   3. hex_rolluppgifter – lösenord lagras med rollnamnet som nyckel.
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
 *
 * DETEKTERING:
 *   PostgreSQL exponerar ingen text för den enskilda DDL-satsen i en
 *   event-trigger, så namnbytet måste kännas igen via current_query().
 *   current_query() returnerar dock den YTTERSTA satsen, inte den sats som
 *   utlöste triggern. Att bara leta efter frasen "RENAME TO" räcker därför
 *   inte: Hex kör själv ALTER SCHEMA ... OWNER TO inifrån
 *   hex_hantera_std_roller vid CREATE SCHEMA, och den satsen träffas då av
 *   varje yttre sats som råkar innehålla frasen — även i en kommentar, och
 *   även när den gäller en tabell. Följden blev att CREATE SCHEMA
 *   misslyckades för klienter som skickar flera satser i samma anrop.
 *
 *   Frasen kopplas därför till det faktiska objektet: vid ett namnbyte är
 *   object_identity det NYA schemanamnet, och satsen måste alltså byta namn
 *   TILL just det schemat. En ALTER SCHEMA ... OWNER TO matchar aldrig det,
 *   oavsett vad den yttre satsen innehåller.
 ******************************************************************************/
DECLARE
    kommando        record;
    schema_namn     text;
    gammalt_namn    text;
    namn_monster    text;
BEGIN
    RAISE NOTICE E'[hex_blockera_schema_namnbyte] ======== START ========';
    RAISE NOTICE '[hex_blockera_schema_namnbyte] Kontrollerar ALTER SCHEMA-sats';

    -- Kontrollera om detta är ett RENAME-kommando
    IF current_query() ~* '\mRENAME\s+TO\M' THEN

        -- Hämta schemanamnet från DDL-händelsen
        FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
            WHERE command_tag = 'ALTER SCHEMA'
        LOOP
            schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

            -- Escapa regex-metatecken – schemanamnets fria del kan innehålla
            -- vad som helst om det citerats i CREATE SCHEMA.
            namn_monster := regexp_replace(schema_namn, '([\\^$.|?*+()\[\]{}])', '\\\1', 'g');

            -- Kräv att satsen byter namn TILL just det här schemat. Annars är
            -- det inte ett schemanamnbyte, utan en annan ALTER SCHEMA-variant
            -- (typiskt OWNER TO) som råkar köras medan frasen finns i den
            -- yttre satsen.
            IF current_query() !~* ('\mRENAME\s+TO\s+"?' || namn_monster || '"?\M') THEN
                RAISE NOTICE '[hex_blockera_schema_namnbyte] Ingen namnbytesmålsträff för "%" – annan ALTER SCHEMA-variant, tillåts', schema_namn;
                CONTINUE;
            END IF;

            -- Namnet före bytet, för ett användbart felmeddelande. Efter att
            -- namnbytet blockerats är det gamla namnet det som finns kvar.
            gammalt_namn := COALESCE(
                (regexp_match(current_query(),
                              '\mALTER\s+SCHEMA\s+"?([^"\s]+)"?\s+RENAME\s+TO', 'i'))[1],
                schema_namn);

            RAISE NOTICE '[hex_blockera_schema_namnbyte] RENAME TO detekterat: % -> %', gammalt_namn, schema_namn;
            RAISE NOTICE '[hex_blockera_schema_namnbyte] !!! BLOCKERAR NAMNBYTE !!!';

            RAISE EXCEPTION
                E'[hex_blockera_schema_namnbyte] ALTER SCHEMA ... RENAME TO är inte tillåtet i Hex.\n\n'
                'Schemanamnet är identitetsnyckeln för ett helt ekosystem av beroenden:\n'
                '  • GeoServer-workspace (namnges identiskt med schemat)\n'
                '  • Databasroller r_%% och w_%% (härleds från schemanamnet)\n'
                '  • Autentiseringsuppgifter i hex_rolluppgifter\n'
                '  • Schemanamn i hex_metadata (parent_schema)\n\n'
                'Ett namnbyte river sönder alla dessa kopplingar utan möjlighet\n'
                'till automatisk återställning.\n\n'
                'Rätt tillvägagångssätt:\n'
                '  1. DROP SCHEMA % CASCADE   -- Hex städar upp roller och GeoServer\n'
                '  2. CREATE SCHEMA <nytt_namn>  -- Hex etablerar nytt ekosystem',
                gammalt_namn;
        END LOOP;

    END IF;

    RAISE NOTICE '[hex_blockera_schema_namnbyte] Ingen RENAME TO-sats – tillåter ALTER SCHEMA';
    RAISE NOTICE E'[hex_blockera_schema_namnbyte] ======== SLUT ========';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE E'[hex_blockera_schema_namnbyte] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_blockera_schema_namnbyte]   - Schema: %', COALESCE(schema_namn, 'okänt');
        RAISE NOTICE '[hex_blockera_schema_namnbyte]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hex_blockera_schema_namnbyte]   - Felmeddelande: %', SQLERRM;
        RAISE NOTICE E'[hex_blockera_schema_namnbyte] ======== AVBRUTEN ========';
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hex_blockera_schema_namnbyte()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_blockera_schema_namnbyte()
    IS 'Event trigger-funktion som blockerar ALTER SCHEMA ... RENAME TO.
Schemanamnet är identitetsnyckeln för GeoServer-workspace, databasroller,
autentiseringsuppgifter i hex_rolluppgifter och poster i hex_metadata.
Ett namnbyte river sönder alla dessa kopplingar. Rätt tillvägagångssätt
är DROP SCHEMA CASCADE följt av CREATE SCHEMA med det nya namnet.';
