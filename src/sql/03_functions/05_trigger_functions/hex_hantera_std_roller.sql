CREATE OR REPLACE FUNCTION public.hex_hantera_std_roller()
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
 * ROLLSTRUKTUR (fyra roller per schema):
 *
 *   r_{schema}    NOLOGIN – läsbehörighetsgrupp.
 *                 Tilldelas AD-användare och AD-grupper för direktåtkomst till databasen.
 *                 Är INTE i hex_geoserver_roller. Sparas i hex_role_credentials
 *                 med rolcanlogin=false och password=NULL.
 *
 *   w_{schema}    NOLOGIN – skrivbehörighetsgrupp.
 *                 Tilldelas AD-användare och AD-grupper för direktåtkomst.
 *                 Är INTE i hex_geoserver_roller.
 *
 *   gs_r_{schema} LOGIN – GeoServer läs-tjänstekonto.
 *                 Ärver rättigheter från r_{schema} via GRANT.
 *                 Är i hex_geoserver_roller för pg_hba.conf-matchning.
 *                 Lösenord sparas i hex_role_credentials med rolcanlogin=true.
 *
 *   gs_w_{schema} LOGIN – GeoServer skriv-tjänstekonto.
 *                 Ärver rättigheter från w_{schema} via GRANT.
 *                 Är i hex_geoserver_roller för pg_hba.conf-matchning.
 *
 * SEPARATION AV AD-ANVÄNDARE OCH TJÄNSTEKONTON:
 *   Eftersom r_* och w_* är NOLOGIN och INTE ingår i hex_geoserver_roller
 *   kan de fritt tilldelas AD-användare utan att störa pg_hba.conf-logiken.
 *   Transitiv gruppmedlemskap via r_- och w_-grupper når aldrig hex_geoserver_roller.
 *
 * TRIGGER: Körs automatiskt vid CREATE SCHEMA
 ******************************************************************************/
DECLARE
    kommando            record;
    schema_namn         text;
    rollkonfiguration   record;
    slutligt_rollnamn   text;
    arvs_rollnamn       text;
    matchar             boolean;
    generated_password  text;
    antal_roller        integer := 0;
BEGIN
    RAISE NOTICE E'[hex_hantera_std_roller] === START ===';
    RAISE NOTICE '[hex_hantera_std_roller] Hanterar rollskapande för nya scheman';

    -- Hantera alla CREATE SCHEMA-kommandon
    FOR kommando IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        schema_namn := replace(split_part(kommando.object_identity, '.', 1), '"', '');

        RAISE NOTICE E'[hex_hantera_std_roller] ================';
        RAISE NOTICE '[hex_hantera_std_roller] Bearbetar schema: %', schema_namn;

        -- Hoppa över systemscheman
        IF schema_namn IN ('public', 'information_schema') OR schema_namn ~ '^pg_' THEN
            RAISE NOTICE '[hex_hantera_std_roller] Hoppar över systemschema: %', schema_namn;
            CONTINUE;
        END IF;

        -- Loopa genom alla rollkonfigurationer (i gid-ordning, r_/w_ skapas före gs_r_/gs_w_)
        FOR rollkonfiguration IN
            SELECT * FROM hex_standardiserade_roller ORDER BY gid
        LOOP
            RAISE NOTICE '[hex_hantera_std_roller] Testar rollkonfiguration: % (typ: %, login: %)',
                rollkonfiguration.rollnamn, rollkonfiguration.rolltyp, rollkonfiguration.with_login;

            -- Testa om schema_uttryck matchar detta schema
            BEGIN
                EXECUTE format('SELECT %L %s', schema_namn, rollkonfiguration.schema_uttryck) INTO matchar;
                RAISE NOTICE '[hex_hantera_std_roller]   Schema_uttryck "%" matchar: %',
                    rollkonfiguration.schema_uttryck, matchar;

                IF matchar THEN
                    -- Ersätt {schema} med faktiskt schemanamn
                    slutligt_rollnamn := replace(rollkonfiguration.rollnamn, '{schema}', schema_namn);
                    RAISE NOTICE '[hex_hantera_std_roller]   Slutligt rollnamn: %', slutligt_rollnamn;

                    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = slutligt_rollnamn) THEN

                        IF rollkonfiguration.with_login THEN
                            -- -------------------------------------------------------
                            -- LOGIN-roll: GeoServer-tjänstekonto (gs_r_*, gs_w_*)
                            -- -------------------------------------------------------
                            generated_password := encode(gen_random_bytes(18), 'base64');
                            EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L',
                                slutligt_rollnamn, generated_password);

                            -- CONNECT-rättighet på aktuell databas
                            EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                                current_database(), slutligt_rollnamn);

                            -- Spara uppgifter i hex_role_credentials
                            INSERT INTO hex_role_credentials(rolname, password, rolcanlogin)
                            VALUES (slutligt_rollnamn, generated_password, true)
                            ON CONFLICT (rolname) DO UPDATE
                                SET password    = EXCLUDED.password,
                                    rolcanlogin = true,
                                    created_at  = now();

                            -- Lägg till i hex_geoserver_roller för pg_hba.conf-matchning
                            EXECUTE format('GRANT hex_geoserver_roller TO %I', slutligt_rollnamn);

                            -- Ärv behörigheter från arvs_fran-rollen (r_* resp. w_*)
                            -- i stället för direkta GRANT på schema – håller behörigheter synkroniserade
                            IF rollkonfiguration.arvs_fran IS NOT NULL THEN
                                arvs_rollnamn := replace(rollkonfiguration.arvs_fran, '{schema}', schema_namn);
                                EXECUTE format('GRANT %I TO %I', arvs_rollnamn, slutligt_rollnamn);
                                RAISE NOTICE '[hex_hantera_std_roller]   ✓ Ärver behörigheter från: %', arvs_rollnamn;
                            ELSE
                                PERFORM hex_tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                            END IF;

                            -- gs_*-roller tilldelas INTE hex_systemagare – de är systeminterna
                            -- och ska inte kunna vidaredelegeras manuellt
                            RAISE NOTICE '[hex_hantera_std_roller]   ✓ Skapade LOGIN-tjänstekonto: %', slutligt_rollnamn;

                        ELSE
                            -- -------------------------------------------------------
                            -- NOLOGIN-roll: behörighetsgrupp (r_*, w_*)
                            -- -------------------------------------------------------
                            EXECUTE format('CREATE ROLE %I WITH NOLOGIN', slutligt_rollnamn);

                            -- Registrera i hex_role_credentials utan lösenord
                            INSERT INTO hex_role_credentials(rolname, password, rolcanlogin)
                            VALUES (slutligt_rollnamn, NULL, false)
                            ON CONFLICT (rolname) DO UPDATE
                                SET rolcanlogin = false,
                                    password    = NULL,
                                    created_at  = now();

                            -- Direkta schemabehörigheter på behörighetsgruppen
                            PERFORM hex_tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);

                            -- Ge ägarrollen rättighet att tilldela denna grupp till AD-användare
                            EXECUTE format('GRANT %I TO %I', slutligt_rollnamn, hex_systemagare());

                            RAISE NOTICE '[hex_hantera_std_roller]   ✓ Skapade NOLOGIN-behörighetsgrupp: %', slutligt_rollnamn;
                        END IF;

                        antal_roller := antal_roller + 1;

                    ELSE
                        RAISE NOTICE '[hex_hantera_std_roller]   - Roll finns redan: %', slutligt_rollnamn;

                        -- Säkerställ att befintlig NOLOGIN-roll ändå får rätt behörigheter
                        -- (t.ex. om tabeller skapades innan rollen fick rättigheter)
                        IF NOT rollkonfiguration.with_login THEN
                            PERFORM hex_tilldela_rollrattigheter(schema_namn, slutligt_rollnamn, rollkonfiguration.rolltyp);
                        ELSE
                            -- Säkerställ att befintlig LOGIN-roll är i hex_geoserver_roller
                            -- (kan saknas om rollen överlevde en avinstallation eller skapades manuellt)
                            IF NOT EXISTS (
                                SELECT 1 FROM pg_auth_members am
                                JOIN pg_roles grp ON grp.oid = am.roleid
                                JOIN pg_roles mem ON mem.oid = am.member
                                WHERE grp.rolname = 'hex_geoserver_roller'
                                  AND mem.rolname = slutligt_rollnamn
                            ) THEN
                                EXECUTE format('GRANT hex_geoserver_roller TO %I', slutligt_rollnamn);
                                RAISE NOTICE '[hex_hantera_std_roller]   ✓ Lade till befintlig LOGIN-roll i hex_geoserver_roller: %', slutligt_rollnamn;
                            END IF;
                        END IF;
                    END IF;
                ELSE
                    RAISE NOTICE '[hex_hantera_std_roller]   - Schema_uttryck matchade inte, hoppar över';
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING '[hex_hantera_std_roller] Fel vid evaluering av schema_uttryck för roll %: %',
                        rollkonfiguration.rollnamn, SQLERRM;
            END;
        END LOOP;

        -- Sammanfattning för detta schema
        RAISE NOTICE '[hex_hantera_std_roller] Sammanfattning för schema %:', schema_namn;
        RAISE NOTICE '[hex_hantera_std_roller]   » Roller skapade: %', antal_roller;

        -- Återställ räknare för nästa schema
        antal_roller := 0;
    END LOOP;

    RAISE NOTICE '[hex_hantera_std_roller] === SLUT ===';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[hex_hantera_std_roller] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[hex_hantera_std_roller]   - Schema: %', schema_namn;
        RAISE NOTICE '[hex_hantera_std_roller]   - Rollkonfiguration: %', rollkonfiguration.rollnamn;
        RAISE NOTICE '[hex_hantera_std_roller]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[hex_hantera_std_roller]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.hex_hantera_std_roller()
    OWNER TO postgres;

COMMENT ON FUNCTION public.hex_hantera_std_roller()
    IS 'Event trigger-funktion för automatisk rollskapande vid CREATE SCHEMA.
    Skapar fyra roller per schema:
      r_{schema}    NOLOGIN behörighetsgrupp (läs) – tilldelas AD-användare/grupper
      w_{schema}    NOLOGIN behörighetsgrupp (skriv) – tilldelas AD-användare/grupper
      gs_r_{schema} LOGIN GeoServer läs-tjänstekonto – ärver r_{schema}, i hex_geoserver_roller
      gs_w_{schema} LOGIN GeoServer skriv-tjänstekonto – ärver w_{schema}, i hex_geoserver_roller
    Alla fyra roller registreras i hex_role_credentials (LOGIN-roller med lösenord,
    NOLOGIN-roller med password=NULL och rolcanlogin=false).
    Separation av AD-användare och tjänstekonton: r_*/w_* ingår aldrig i
    hex_geoserver_roller, vilket förhindrar transitiv pg_hba.conf-matchning för AD-konton.
    Kräver pgcrypto-tillägget för lösenordsgenerering.';
