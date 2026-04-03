CREATE OR REPLACE FUNCTION public.hantera_standardiserade_roller()
    RETURNS event_trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
    SECURITY DEFINER
    SET search_path = public
AS $BODY$

/******************************************************************************
 * Event trigger-funktion som skapar roller automatiskt när nya scheman skapas.
 *
 * SECURITY DEFINER: Körs som funktionens ägare (postgres) för att säkerställa
 * att roller kan skapas och hanteras korrekt oavsett vilken användare som
 * skapar schemat.
 *
 * FUNKTIONALITET:
 * 1. Läser konfiguration från standardiserade_roller-tabellen
 * 2. Evaluerar schema_uttryck för att avgöra vilka roller som ska skapas
 * 3. Skapar roller med eller utan LOGIN beroende på with_login-flaggan
 * 4. LOGIN-roller får ett autogenererat lösenord via pgcrypto,
 *    lösenordet sparas i hex_role_credentials för GeoServer-lyssnaren
 *
 * ROLLSTRUKTUR:
 * - NOLOGIN (with_login = false): ren behörighetsgrupp, t.ex. framtida globala roller
 * - LOGIN   (with_login = true):  t.ex. r_sk1_kba_bygg, w_sk1_kba_bygg
 *
 * TRIGGER: Körs automatiskt vid CREATE SCHEMA
 ******************************************************************************/
DECLARE
    kommando            record;
    schema_namn         text;
    rollkonfiguration   record;
    slutligt_rollnamn   text;
    matchar             boolean;
    generated_password  text;
    antal_roller        integer := 0;
BEGIN
    RAISE NOTICE E'[hantera_standardiserade_roller] === START ===';
    RAISE NOTICE '[hantera_standardiserade_roller] Hanterar rollskapande för nya scheman';

    -- Hantera alla CREATE SCHEMA-kommandon
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

        RAISE NOTICE E'[hantera_standardiserade_roller] ================';
        RAISE NOTICE '[hantera_standardiserade_roller] Bearbetar schema: %', schema_namn;

        -- Hoppa över systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[hantera_standardiserade_roller] Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;

        -- Loopa genom alla rollkonfigurationer
        FOR rollkonfiguration IN
            SELECT * FROM standardiserade_roller ORDER BY gid
        LOOP
            RAISE NOTICE '[hantera_standardiserade_roller] Testar rollkonfiguration: % (typ: %)',
                rollkonfiguration.rollnamn, rollkonfiguration.rolltyp;

            -- Testa om schema_uttryck matchar detta schema
            BEGIN
                EXECUTE format('SELECT %L %s', schema_namn, rollkonfiguration.schema_uttryck) INTO matchar;
                RAISE NOTICE '[hantera_standardiserade_roller]   Schema_uttryck "%" matchar: %',
                    rollkonfiguration.schema_uttryck, matchar;

                IF matchar THEN
                    -- Ersätt {schema} med faktiskt schemanamn
                    slutligt_rollnamn := replace(rollkonfiguration.rollnamn, '{schema}', schema_namn);
                    RAISE NOTICE '[hantera_standardiserade_roller]   Slutligt rollnamn: %', slutligt_rollnamn;

                    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = slutligt_rollnamn) THEN

                        IF rollkonfiguration.with_login THEN
                            -- Generera lösenord och skapa LOGIN-roll
                            generated_password := encode(gen_random_bytes(18), 'base64');
                            EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L',
                                slutligt_rollnamn, generated_password);

                            -- Ge rollen CONNECT-rättighet på aktuell databas.
                            -- Utan detta kan rollen inte ansluta om PUBLIC:s CONNECT-rättighet
                            -- har återkallats (vilket är standard i produktionsmiljö).
                            EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                                current_database(), slutligt_rollnamn);

                            -- Spara lösenord för GeoServer-lyssnaren
                            INSERT INTO hex_role_credentials(rolname, password)
                            VALUES (slutligt_rollnamn, generated_password)
                            ON CONFLICT (rolname) DO UPDATE
                                SET password = EXCLUDED.password,
                                    created_at = now();

                            RAISE NOTICE '[hantera_standardiserade_roller]   ✓ Skapade LOGIN-roll: %', slutligt_rollnamn;
                        ELSE
                            EXECUTE format('CREATE ROLE %I WITH NOLOGIN', slutligt_rollnamn);
                            RAISE NOTICE '[hantera_standardiserade_roller]   ✓ Skapade NOLOGIN-roll: %', slutligt_rollnamn;
                        END IF;

                        -- Lägg till i hex_geoserver_roller så att pg_hba.conf kan matcha
                        -- alla systemanvändare via +hex_geoserver_roller
                        IF rollkonfiguration.with_login THEN
                            EXECUTE format('GRANT hex_geoserver_roller TO %I', slutligt_rollnamn);
                        END IF;

                        -- Ge ägarrollen ADMIN OPTION så den kan hantera denna roll
                        EXECUTE format('GRANT %I TO %I', slutligt_rollnamn, system_owner());
                        antal_roller := antal_roller + 1;

                        -- Tilldela rättigheter till roll
                        PERFORM tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                    ELSE
                        RAISE NOTICE '[hantera_standardiserade_roller]   - Roll finns redan: %', slutligt_rollnamn;

                        -- Tilldela rättigheter på detta schema även till befintlig roll
                        PERFORM tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                    END IF;
                ELSE
                    RAISE NOTICE '[hantera_standardiserade_roller]   - Schema_uttryck matchade inte, hoppar över';
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING '[hantera_standardiserade_roller] Fel vid evaluering av schema_uttryck för roll %: %',
                        rollkonfiguration.rollnamn, SQLERRM;
            END;
        END LOOP;

        -- Sammanfattning för detta schema
        RAISE NOTICE '[hantera_standardiserade_roller] Sammanfattning för schema %:', schema_namn;
        RAISE NOTICE '[hantera_standardiserade_roller]   » Roller skapade: %', antal_roller;

        -- Återställ räknare för nästa schema
        antal_roller := 0;
    END LOOP;

    RAISE NOTICE '[hantera_standardiserade_roller] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hantera_standardiserade_roller] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hantera_standardiserade_roller]   - Schema: %', schema_namn;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Rollkonfiguration: %', rollkonfiguration.rollnamn;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hantera_standardiserade_roller]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hantera_standardiserade_roller()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hantera_standardiserade_roller()
    IS 'Event trigger-funktion för automatisk rollskapande vid CREATE SCHEMA.
    Läser konfiguration från standardiserade_roller och skapar roller enligt
    schema_uttryck-matchning. Roller med with_login = true får LOGIN och ett
    autogenererat lösenord som sparas i hex_role_credentials.
    Kräver pgcrypto-tillägget för lösenordsgenerering.';
