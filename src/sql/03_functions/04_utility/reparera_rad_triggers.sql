CREATE OR REPLACE FUNCTION public.reparera_rad_triggers()
    RETURNS TABLE (
        schema_namn  text,
        tabell_namn  text,
        trigger_namn text,
        atgard       text
    )
    LANGUAGE plpgsql
AS $BODY$
/******************************************************************************
 * Återkopplar saknade rad-nivå-triggers och reparerar behörigheter på alla
 * Hex-hanterade tabeller och roller.
 *
 * Anropas automatiskt av installeraren efter varje installation/uppgradering
 * för att säkerställa att befintliga tabeller och roller har all förväntad
 * funktionalitet, även när de skapades med en äldre version av Hex.
 *
 * Schemaprefix hämtas dynamiskt från standardiserade_skyddsnivaer, så att
 * egna prefix (t.ex. sc1, sk3) fungerar utan kodändringar.
 *
 * Hanterar nio åtgärdstyper:
 *
 *   schemamigrering      Uppgraderar hex_role_credentials och standardiserade_roller
 *                        till aktuellt schema idempotent (ADD COLUMN IF NOT EXISTS).
 *                        Körs alltid först.
 *
 *   hex_tvinga_gid       BEFORE INSERT på alla Hex-tabeller med en gid
 *                        IDENTITY-kolumn. Förhindrar att klienter (t.ex. QGIS)
 *                        väljer eget gid via OVERRIDING SYSTEM VALUE.
 *
 *   hex_kontrollera_geom BEFORE INSERT OR UPDATE på geometritabeller vars
 *                        datakategori har validera_geometri = true.
 *                        Validerar OGC-giltighet.
 *
 *   hex_ta_bort_dummy    AFTER INSERT på geometritabeller som fortfarande har
 *                        en dummy-rad registrerad i hex_dummy_geometrier.
 *                        Transient – tar bort sig själv när första riktiga
 *                        raden infogas. Återkopplas bara om dummy-raden finns.
 *
 *   trg_<tabell>_qa      BEFORE UPDATE OR DELETE på tabeller med historik.
 *                        Identifieras via triggerfunktioner (trg_fn_%_qa) som
 *                        lever i respektive Hex-schema och överlever en
 *                        oinstallation av Hex.
 *
 *   rollstruktur         Verifierar och reparerar alla fyra roller per schema:
 *                          r_{schema}    NOLOGIN behörighetsgrupp (läs)
 *                          w_{schema}    NOLOGIN behörighetsgrupp (skriv)
 *                          gs_r_{schema} LOGIN GeoServer läs-tjänstekonto
 *                          gs_w_{schema} LOGIN GeoServer skriv-tjänstekonto
 *                        Hanterar migrering från äldre installationer där r_- och w_-roller
 *                        skapades som LOGIN-roller (konverteras till NOLOGIN och
 *                        gs_*-konton skapas). Idempotent.
 *
 *   hex_geoserver_roller Säkerställer att gs_*-roller (rolcanlogin=true i
 *   (rollmedlemskap)     hex_role_credentials) är i hex_geoserver_roller.
 *                        Tar bort NOLOGIN-roller som felaktigt hamnat där.
 *
 *   schemabehörigheter   Kör tilldela_rollrattigheter för NOLOGIN-roller och
 *                        säkerställer GRANT arvs_fran för gs_*-roller.
 *                        Idempotent.
 *
 *   geoserver_notifiering Skickar pg_notify('geoserver_schema', schema) för
 *                        scheman vars prefix har publiceras_geoserver = true
 *                        och som har gs_r_-uppgifter i hex_role_credentials.
 *                        Lyssnaren är idempotent, så det är säkert att alltid
 *                        skicka notifieringen.
 *
 * Funktionen är idempotent – befintliga triggers och rättigheter rörs inte
 * i onödan. Returnerar en rad per undersökt åtgärd med resultatet
 * 'skapad'/'beviljad'/'uppdaterade' eller 'redan finns'.
 ******************************************************************************/
DECLARE
    r                  record;
    rol                record;
    trig_exists        boolean;
    tabell             text;
    matchar            boolean;
    rollnamn_full      text;
    arvs_rollnamn      text;
    schema_regex       text;
    generated_password text;
BEGIN
    -- -------------------------------------------------------------------------
    -- 0. Schemamigrering
    --    Uppgraderar tabellscheman från äldre Hex-installationer idempotent.
    --    ALTER TABLE ... ADD COLUMN IF NOT EXISTS och DROP NOT NULL är no-ops
    --    om kolumnen redan har rätt definition.
    -- -------------------------------------------------------------------------
    EXECUTE 'ALTER TABLE public.hex_role_credentials ALTER COLUMN password DROP NOT NULL';
    EXECUTE 'ALTER TABLE public.hex_role_credentials ADD COLUMN IF NOT EXISTS rolcanlogin boolean NOT NULL DEFAULT true';
    EXECUTE 'ALTER TABLE public.standardiserade_roller ADD COLUMN IF NOT EXISTS arvs_fran text DEFAULT NULL';

    -- Bygg regex från standardiserade_skyddsnivaer en gång.
    -- Alla schemanamnkontroller i denna funktion använder denna variabel
    -- så att egna prefix fungerar utan kodändringar.
    SELECT '^(' || string_agg(prefix, '|') || ')_'
    INTO   schema_regex
    FROM   public.standardiserade_skyddsnivaer;

    -- -------------------------------------------------------------------------
    -- 1. hex_tvinga_gid
    --    Alla tabeller i Hex-scheman med en gid IDENTITY-kolumn.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind = 'r'
          AND  n.nspname ~ schema_regex
          AND  EXISTS (
                   SELECT 1
                   FROM   pg_attribute a
                   WHERE  a.attrelid    = c.oid
                     AND  a.attname     = 'gid'
                     AND  a.attidentity != ''
                     AND  NOT a.attisdropped
               )
        ORDER BY n.nspname, c.relname
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM   pg_trigger   t
            JOIN   pg_class     c ON c.oid = t.tgrelid
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = r.t
              AND  t.tgname  = 'hex_tvinga_gid'
        ) INTO trig_exists;

        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'hex_tvinga_gid';

        IF NOT trig_exists THEN
            EXECUTE format(
                'CREATE TRIGGER hex_tvinga_gid'
                ' BEFORE INSERT ON %I.%I'
                ' FOR EACH ROW EXECUTE FUNCTION public.tvinga_gid_fran_sekvens()',
                r.s, r.t
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 2. hex_kontrollera_geom
    --    Scheman vars datakategori har validera_geometri = true i
    --    standardiserade_datakategorier, med en kolumn 'geom' av PostGIS-typ.
    --    Historiktabeller (har h_typ-kolumn) undantas.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind = 'r'
          AND  EXISTS (
                   SELECT 1 FROM public.standardiserade_datakategorier d
                   WHERE  d.validera_geometri = true
                     AND  n.nspname ~ (schema_regex || d.prefix || '_')
               )
          AND  EXISTS (
                   SELECT 1
                   FROM   pg_attribute a
                   JOIN   pg_type      ty ON ty.oid = a.atttypid
                   WHERE  a.attrelid      = c.oid
                     AND  a.attname       = 'geom'
                     AND  ty.typname      = 'geometry'
                     AND  NOT a.attisdropped
               )
          AND  NOT EXISTS (
                   SELECT 1
                   FROM   pg_attribute a
                   WHERE  a.attrelid  = c.oid
                     AND  a.attname   = 'h_typ'
                     AND  NOT a.attisdropped
               )
        ORDER BY n.nspname, c.relname
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM   pg_trigger   t
            JOIN   pg_class     c ON c.oid = t.tgrelid
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = r.t
              AND  t.tgname  = 'hex_kontrollera_geom'
        ) INTO trig_exists;

        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'hex_kontrollera_geom';

        IF NOT trig_exists THEN
            EXECUTE format(
                'CREATE TRIGGER hex_kontrollera_geom'
                ' BEFORE INSERT OR UPDATE ON %I.%I'
                ' FOR EACH ROW EXECUTE FUNCTION public.kontrollera_geometri_trigger()',
                r.s, r.t
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 3. hex_ta_bort_dummy
    --    AFTER INSERT på geometritabeller som fortfarande har en dummy-rad
    --    registrerad i hex_dummy_geometrier. Triggern är transient – den tar
    --    bort sig själv när första riktiga raden infogas – och ska bara
    --    återkopplas om dummy-raden faktiskt finns kvar.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT d.schema_namn AS s, d.tabell_namn AS t
        FROM   public.hex_dummy_geometrier d
        ORDER BY d.schema_namn, d.tabell_namn
    LOOP
        -- Hoppa över om tabellen inte längre existerar.
        IF NOT EXISTS (
            SELECT 1
            FROM   pg_class     c
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = r.t
              AND  c.relkind = 'r'
        ) THEN
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM   pg_trigger   t
            JOIN   pg_class     c ON c.oid = t.tgrelid
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = r.t
              AND  t.tgname  = 'hex_ta_bort_dummy'
        ) INTO trig_exists;

        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'hex_ta_bort_dummy';

        IF NOT trig_exists THEN
            EXECUTE format(
                'CREATE TRIGGER hex_ta_bort_dummy'
                ' AFTER INSERT ON %I.%I'
                ' FOR EACH ROW EXECUTE FUNCTION public.ta_bort_dummy_rad()',
                r.s, r.t
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 4. trg_<tabell>_qa
    --    Tabeller med historik identifieras via triggerfunktioner som matchar
    --    mönstret trg_fn_<tabell>_qa i respektive Hex-schema. Dessa funktioner
    --    lever i användarscheman och överlever en oinstallation av Hex, vilket
    --    gör dem till en pålitlig källa även när hex_metadata är tom.
    --
    --    Obs: Om föräldertabellen har döpts om efter att historiken skapades
    --    matchar inte det härledda tabellnamnet längre – dessa tabeller hoppas
    --    över tyst (tabellen existerar inte under det gamla namnet).
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s, p.proname AS fn
        FROM   pg_proc      p
        JOIN   pg_namespace n ON n.oid = p.pronamespace
        WHERE  n.nspname ~ schema_regex
          AND  p.proname  ~ '^trg_fn_.+_qa$'
        ORDER BY n.nspname, p.proname
    LOOP
        -- Härleda föräldertabellnamn från funktionsnamnet.
        tabell := substring(r.fn FROM '^trg_fn_(.+)_qa$');

        -- Hoppa över om föräldertabellen inte längre existerar under det namnet.
        IF NOT EXISTS (
            SELECT 1
            FROM   pg_class     c
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = tabell
              AND  c.relkind = 'r'
        ) THEN
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM   pg_trigger   t
            JOIN   pg_class     c ON c.oid = t.tgrelid
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            WHERE  n.nspname = r.s
              AND  c.relname = tabell
              AND  t.tgname  = 'trg_' || tabell || '_qa'
        ) INTO trig_exists;

        schema_namn  := r.s;
        tabell_namn  := tabell;
        trigger_namn := 'trg_' || tabell || '_qa';

        IF NOT trig_exists THEN
            EXECUTE format(
                'CREATE TRIGGER trg_%s_qa'
                ' BEFORE UPDATE OR DELETE ON %I.%I'
                ' FOR EACH ROW EXECUTE FUNCTION %I.%I()',
                tabell, r.s, tabell, r.s, r.fn
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 5. rollstruktur
    --    Verifierar och reparerar alla fyra roller per schema enligt
    --    standardiserade_roller. Hanterar både nyinstallationer och migrering
    --    från äldre konfigurationer (r_*/w_* som LOGIN → NOLOGIN).
    --
    --    NOLOGIN-roller (with_login=false, t.ex. r_*, w_*):
    --      a) Saknas helt              → CREATE NOLOGIN, behörigheter, hex_role_credentials
    --      b) Är LOGIN (gammal config) → ALTER NOLOGIN, REVOKE hex_geoserver_roller,
    --                                    uppdatera hex_role_credentials
    --      c) Finns som NOLOGIN        → säkerställ hex_role_credentials-post
    --
    --    LOGIN-roller med arvs_fran (with_login=true, t.ex. gs_r_*, gs_w_*):
    --      a) Saknas helt              → CREATE LOGIN, lösenord, hex_geoserver_roller,
    --                                    GRANT arvs_fran, hex_role_credentials
    --      b) LOGIN, saknar credentials → backfyll lösenord i hex_role_credentials
    --      c) Allt korrekt             → 'redan korrekt'
    --
    --    Alltid säkerställs: behörigheter (NOLOGIN), arvs_fran-grant (LOGIN),
    --    hex_role_credentials-post, system_owner-grant (NOLOGIN).
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        WHERE  n.nspname ~ schema_regex
        ORDER BY n.nspname
    LOOP
        FOR rol IN
            SELECT rollnamn, rolltyp, schema_uttryck, with_login, arvs_fran
            FROM   public.standardiserade_roller
            ORDER BY gid
        LOOP
            BEGIN
                EXECUTE format('SELECT %L %s', r.s, rol.schema_uttryck)
                    INTO matchar;
            EXCEPTION WHEN OTHERS THEN
                matchar := false;
            END;

            CONTINUE WHEN NOT matchar;

            rollnamn_full := replace(rol.rollnamn, '{schema}', r.s);
            schema_namn   := r.s;
            tabell_namn   := rollnamn_full;
            trigger_namn  := 'rollstruktur';

            IF NOT rol.with_login THEN
                -- -------------------------------------------------------
                -- NOLOGIN behörighetsgrupp (r_*, w_*)
                -- -------------------------------------------------------
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full) THEN
                    -- Fall a: saknas helt
                    EXECUTE format('CREATE ROLE %I WITH NOLOGIN', rollnamn_full);
                    INSERT INTO public.hex_role_credentials (rolname, password, rolcanlogin)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rolname) DO UPDATE
                        SET rolcanlogin = false, password = NULL, created_at = now();
                    EXECUTE format('GRANT %I TO %I', rollnamn_full, system_owner());
                    PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'NOLOGIN-grupp skapad';

                ELSIF EXISTS (
                    SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full AND rolcanlogin
                ) THEN
                    -- Fall b: var LOGIN (gammal config) – migrera till NOLOGIN
                    EXECUTE format('ALTER ROLE %I WITH NOLOGIN', rollnamn_full);
                    -- Ta bort från hex_geoserver_roller om den hamnat där
                    IF EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = 'hex_geoserver_roller'
                          AND mem.rolname = rollnamn_full
                    ) THEN
                        EXECUTE format('REVOKE hex_geoserver_roller FROM %I', rollnamn_full);
                    END IF;
                    -- Uppdatera hex_role_credentials
                    INSERT INTO public.hex_role_credentials (rolname, password, rolcanlogin)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rolname) DO UPDATE
                        SET rolcanlogin = false, password = NULL, created_at = now();
                    -- Säkerställ system_owner-grant
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = rollnamn_full
                          AND mem.rolname = system_owner()
                    ) THEN
                        EXECUTE format('GRANT %I TO %I', rollnamn_full, system_owner());
                    END IF;
                    PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'LOGIN→NOLOGIN migrerad';

                ELSE
                    -- Fall c: finns som NOLOGIN – säkerställ hex_role_credentials
                    INSERT INTO public.hex_role_credentials (rolname, password, rolcanlogin)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rolname) DO UPDATE
                        SET rolcanlogin = false, password = NULL;
                    -- Säkerställ system_owner-grant
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = rollnamn_full
                          AND mem.rolname = system_owner()
                    ) THEN
                        EXECUTE format('GRANT %I TO %I', rollnamn_full, system_owner());
                    END IF;
                    PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'redan NOLOGIN';
                END IF;

            ELSE
                -- -------------------------------------------------------
                -- LOGIN tjänstekonto med arvs_fran (gs_r_*, gs_w_*)
                -- -------------------------------------------------------
                IF rol.arvs_fran IS NOT NULL THEN
                    arvs_rollnamn := replace(rol.arvs_fran, '{schema}', r.s);
                ELSE
                    arvs_rollnamn := NULL;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full) THEN
                    -- Fall a: saknas helt
                    generated_password := encode(gen_random_bytes(18), 'base64');
                    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L',
                        rollnamn_full, generated_password);
                    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                        current_database(), rollnamn_full);
                    EXECUTE format('GRANT hex_geoserver_roller TO %I', rollnamn_full);
                    IF arvs_rollnamn IS NOT NULL AND EXISTS (
                        SELECT 1 FROM pg_roles WHERE rolname = arvs_rollnamn
                    ) THEN
                        EXECUTE format('GRANT %I TO %I', arvs_rollnamn, rollnamn_full);
                    END IF;
                    INSERT INTO public.hex_role_credentials (rolname, password, rolcanlogin)
                    VALUES (rollnamn_full, generated_password, true)
                    ON CONFLICT (rolname) DO UPDATE
                        SET password = EXCLUDED.password, rolcanlogin = true, created_at = now();
                    atgard := 'LOGIN-tjänstekonto skapad';

                ELSIF NOT EXISTS (
                    SELECT 1 FROM public.hex_role_credentials
                    WHERE rolname = rollnamn_full AND rolcanlogin = true
                ) THEN
                    -- Fall b: finns som LOGIN men saknar credentials – backfyll
                    generated_password := encode(gen_random_bytes(18), 'base64');
                    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L',
                        rollnamn_full, generated_password);
                    INSERT INTO public.hex_role_credentials (rolname, password, rolcanlogin)
                    VALUES (rollnamn_full, generated_password, true)
                    ON CONFLICT (rolname) DO UPDATE
                        SET password = EXCLUDED.password, rolcanlogin = true, created_at = now();
                    -- Säkerställ hex_geoserver_roller
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = 'hex_geoserver_roller'
                          AND mem.rolname = rollnamn_full
                    ) THEN
                        EXECUTE format('GRANT hex_geoserver_roller TO %I', rollnamn_full);
                    END IF;
                    -- Säkerställ arvs_fran
                    IF arvs_rollnamn IS NOT NULL AND EXISTS (
                        SELECT 1 FROM pg_roles WHERE rolname = arvs_rollnamn
                    ) THEN
                        IF NOT EXISTS (
                            SELECT 1 FROM pg_auth_members am
                            JOIN pg_roles grp ON grp.oid = am.roleid
                            JOIN pg_roles mem ON mem.oid = am.member
                            WHERE grp.rolname = arvs_rollnamn
                              AND mem.rolname = rollnamn_full
                        ) THEN
                            EXECUTE format('GRANT %I TO %I', arvs_rollnamn, rollnamn_full);
                        END IF;
                    END IF;
                    atgard := 'lösenord backfyllt';

                ELSE
                    -- Fall c: allt korrekt – säkerställ ändå hex_geoserver_roller och arvs_fran
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = 'hex_geoserver_roller'
                          AND mem.rolname = rollnamn_full
                    ) THEN
                        EXECUTE format('GRANT hex_geoserver_roller TO %I', rollnamn_full);
                    END IF;
                    IF arvs_rollnamn IS NOT NULL AND EXISTS (
                        SELECT 1 FROM pg_roles WHERE rolname = arvs_rollnamn
                    ) THEN
                        IF NOT EXISTS (
                            SELECT 1 FROM pg_auth_members am
                            JOIN pg_roles grp ON grp.oid = am.roleid
                            JOIN pg_roles mem ON mem.oid = am.member
                            WHERE grp.rolname = arvs_rollnamn
                              AND mem.rolname = rollnamn_full
                        ) THEN
                            EXECUTE format('GRANT %I TO %I', arvs_rollnamn, rollnamn_full);
                        END IF;
                    END IF;
                    atgard := 'redan korrekt';
                END IF;
            END IF;

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 6. hex_geoserver_roller rollmedlemskap
    --    Säkerställer att gs_*-roller (rolcanlogin=true) är i hex_geoserver_roller.
    --    Tar också bort NOLOGIN-roller (rolcanlogin=false) som felaktigt hamnat
    --    i hex_geoserver_roller – förekommer vid migrering från äldre config.
    -- -------------------------------------------------------------------------

    -- 6a. Lägg till saknade LOGIN-roller
    FOR r IN
        SELECT rolname AS s
        FROM   public.hex_role_credentials
        WHERE  rolcanlogin = true
        ORDER BY rolname
    LOOP
        schema_namn  := '-';
        tabell_namn  := r.s;
        trigger_namn := 'hex_geoserver_roller (rollmedlemskap)';

        IF NOT EXISTS (
            SELECT 1
            FROM   pg_auth_members am
            JOIN   pg_roles grp ON grp.oid = am.roleid
            JOIN   pg_roles mem ON mem.oid = am.member
            WHERE  grp.rolname = 'hex_geoserver_roller'
              AND  mem.rolname = r.s
        ) THEN
            EXECUTE format('GRANT hex_geoserver_roller TO %I', r.s);
            atgard := 'beviljad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- 6b. Ta bort NOLOGIN-roller som felaktigt finns i hex_geoserver_roller
    FOR r IN
        SELECT hrc.rolname AS s
        FROM   public.hex_role_credentials hrc
        WHERE  hrc.rolcanlogin = false
          AND  EXISTS (
                   SELECT 1 FROM pg_auth_members am
                   JOIN pg_roles grp ON grp.oid = am.roleid
                   JOIN pg_roles mem ON mem.oid = am.member
                   WHERE grp.rolname = 'hex_geoserver_roller'
                     AND mem.rolname = hrc.rolname
               )
        ORDER BY hrc.rolname
    LOOP
        EXECUTE format('REVOKE hex_geoserver_roller FROM %I', r.s);
        schema_namn  := '-';
        tabell_namn  := r.s;
        trigger_namn := 'hex_geoserver_roller (rollmedlemskap)';
        atgard       := 'NOLOGIN-roll borttagen ur hex_geoserver_roller';
        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 7. Schemabehörigheter
    --    För NOLOGIN-roller: kör tilldela_rollrattigheter (idempotent).
    --    För LOGIN-roller med arvs_fran: säkerställ GRANT arvs_fran TO roll
    --    i stället för direkta grants – gs_*-roller ärver via gruppmedlemskap.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        WHERE  n.nspname ~ schema_regex
        ORDER BY n.nspname
    LOOP
        FOR rol IN
            SELECT rollnamn, rolltyp, schema_uttryck, with_login, arvs_fran
            FROM   public.standardiserade_roller
            ORDER BY gid
        LOOP
            BEGIN
                EXECUTE format('SELECT %L %s', r.s, rol.schema_uttryck)
                    INTO matchar;
            EXCEPTION WHEN OTHERS THEN
                matchar := false;
            END;

            CONTINUE WHEN NOT matchar;

            rollnamn_full := replace(rol.rollnamn, '{schema}', r.s);

            CONTINUE WHEN NOT EXISTS (
                SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full
            );

            schema_namn  := r.s;
            tabell_namn  := rollnamn_full;
            trigger_namn := 'schemabehörigheter';

            IF NOT rol.with_login THEN
                -- NOLOGIN-roll: direkta schemabehörigheter
                PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                atgard := 'behörigheter uppdaterade';
            ELSE
                -- LOGIN-tjänstekonto: säkerställ arvs_fran-grant
                IF rol.arvs_fran IS NOT NULL THEN
                    arvs_rollnamn := replace(rol.arvs_fran, '{schema}', r.s);
                    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = arvs_rollnamn)
                    AND NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = arvs_rollnamn
                          AND mem.rolname = rollnamn_full
                    ) THEN
                        EXECUTE format('GRANT %I TO %I', arvs_rollnamn, rollnamn_full);
                        atgard := 'arvs_fran-grant tillagd';
                    ELSE
                        atgard := 'arvs_fran redan beviljad';
                    END IF;
                ELSE
                    PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'behörigheter uppdaterade';
                END IF;
            END IF;

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 8. geoserver_notifiering
    --    Skickar pg_notify('geoserver_schema', schema) för alla Hex-scheman
    --    vars prefix har publiceras_geoserver = true och som har gs_r_-uppgifter
    --    i hex_role_credentials (dvs. lyssnaren kan sätta upp datastore).
    --
    --    Täcker tre scenarier:
    --      a) Schema skapades med äldre config – notifiering skickades aldrig
    --      b) Prefix fick publiceras_geoserver = true efter att schemat skapats
    --      c) Lyssnaren var nere när schemat skapades och missade notifieringen
    --
    --    Lyssnaren är idempotent, så det är säkert att alltid skicka notifieringen.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        JOIN   public.standardiserade_skyddsnivaer ssn
               ON n.nspname LIKE ssn.prefix || '_%'
              AND ssn.publiceras_geoserver = true
        WHERE  EXISTS (
                   SELECT 1 FROM public.hex_role_credentials
                   WHERE  rolname     = 'gs_r_' || n.nspname
                     AND  rolcanlogin = true
               )
        ORDER BY n.nspname
    LOOP
        PERFORM pg_notify('geoserver_schema', r.s);

        schema_namn  := r.s;
        tabell_namn  := '-';
        trigger_namn := 'geoserver_notifiering';
        atgard       := 'notifiering skickad';
        RETURN NEXT;
    END LOOP;
END;
$BODY$;

ALTER FUNCTION public.reparera_rad_triggers()
    OWNER TO postgres;

COMMENT ON FUNCTION public.reparera_rad_triggers()
    IS 'Reparerar och verifierar hela Hex-strukturen för alla scheman.
Uppgraderar tabellscheman (hex_role_credentials, standardiserade_roller) idempotent.
Återkopplar saknade rad-nivå-triggers (hex_tvinga_gid, hex_kontrollera_geom,
hex_ta_bort_dummy, trg_<tabell>_qa).
Verifierar och reparerar alla fyra roller per schema:
  r_{schema}/w_{schema}       NOLOGIN behörighetsgrupper – tilldelas AD-användare
  gs_r_{schema}/gs_w_{schema} LOGIN GeoServer-tjänstekonton – i hex_geoserver_roller
Hanterar migrering från äldre config (r_*/w_* som LOGIN → NOLOGIN, skapar gs_*).
Säkerställer hex_geoserver_roller-medlemskap (enbart gs_*) och tar bort
NOLOGIN-roller som felaktigt hamnat där.
Reparerar schemabehörigheter (NOLOGIN: tilldela_rollrattigheter,
LOGIN: GRANT arvs_fran).
Skickar pg_notify för GeoServer-publicering (gs_r_-uppgifter krävs).
Schemaprefix hämtas från standardiserade_skyddsnivaer – egna prefix fungerar
utan kodändringar. Idempotent. Anropas av installeraren efter varje
installation/uppgradering.';
