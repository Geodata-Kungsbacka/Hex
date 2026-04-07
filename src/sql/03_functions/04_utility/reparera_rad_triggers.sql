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
 * Hanterar åtta åtgärdstyper:
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
 *   login-konvertering   Konverterar NOLOGIN-roller till LOGIN-roller med
 *                        autogenererade lösenord och fyller i
 *                        hex_role_credentials. Hanterar scheman skapade med
 *                        äldre JNDI-baserad konfiguration där rollerna
 *                        skapades som NOLOGIN-grupper utan lösenord.
 *                        Idempotent – LOGIN-roller med sparade lösenord rörs
 *                        inte. Obs: endast roller definierade i
 *                        standardiserade_roller hanteras; anpassade roller
 *                        utanför konfigurationen fångas inte.
 *
 *   hex_geoserver_roller Säkerställer att alla Hex-skapade LOGIN-roller
 *   (rollmedlemskap)     (lagrade i hex_role_credentials) är medlemmar i
 *                        hex_geoserver_roller för pg_hba.conf-matchning.
 *
 *   schemabehörigheter   Kör tilldela_rollrattigheter för alla scheman och
 *                        roller enligt standardiserade_roller. Idempotent –
 *                        säkerställer att GRANT och DEFAULT PRIVILEGES är
 *                        korrekta oavsett när tabeller skapades relativt schemat.
 *
 *   geoserver_notifiering Skickar pg_notify('geoserver_schema', schema) för
 *                        scheman vars prefix har publiceras_geoserver = true
 *                        och som har autentiseringsuppgifter i
 *                        hex_role_credentials. Lyssnaren är idempotent
 *                        (skapar inte om redan existerande workspaces/stores),
 *                        så det är säkert att alltid skicka notifieringen.
 *                        Täcker scheman skapade före ett prefix fick
 *                        publiceras_geoserver = true, eller scheman som
 *                        missades vid den ursprungliga CREATE SCHEMA.
 *
 * Funktionen är idempotent – befintliga triggers och rättigheter rörs inte
 * i onödan. Returnerar en rad per undersökt åtgärd med resultatet
 * 'skapad'/'beviljad'/'uppdaterade' eller 'redan finns'.
 ******************************************************************************/
DECLARE
    r             record;
    rol           record;
    trig_exists   boolean;
    tabell        text;
    matchar       boolean;
    rollnamn_full      text;
    schema_regex       text;
    generated_password text;
BEGIN
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
    -- 5. login-konvertering
    --    Scheman skapade med äldre JNDI-baserad Hex-konfiguration har roller
    --    som NOLOGIN-grupper utan lösenord och utan post i hex_role_credentials.
    --    Denna sektion konverterar sådana roller till LOGIN-roller med
    --    autogenererade lösenord och fyller i tabellen.
    --
    --    Tre fall hanteras:
    --      a) Rollen saknas helt            → CREATE ROLE ... LOGIN PASSWORD
    --      b) Rollen är NOLOGIN             → ALTER ROLE ... LOGIN PASSWORD
    --      c) Rollen är LOGIN utan lösenord → ALTER ROLE ... PASSWORD (backfill)
    --
    --    Idempotent – LOGIN-roller med sparade lösenord rörs inte.
    --    Obs: enbart roller definierade i standardiserade_roller hanteras.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        WHERE  n.nspname ~ schema_regex
        ORDER BY n.nspname
    LOOP
        FOR rol IN
            SELECT rollnamn, rolltyp, schema_uttryck
            FROM   public.standardiserade_roller
            WHERE  with_login = true
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

            schema_namn  := r.s;
            tabell_namn  := rollnamn_full;
            trigger_namn := 'login-konvertering';

            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full) THEN
                -- Fall a: rollen saknas helt – skapa som LOGIN med lösenord
                generated_password := encode(gen_random_bytes(18), 'base64');
                EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L',
                    rollnamn_full, generated_password);
                EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                    current_database(), rollnamn_full);
                INSERT INTO public.hex_role_credentials (rolname, password)
                VALUES (rollnamn_full, generated_password)
                ON CONFLICT (rolname) DO UPDATE
                    SET password   = EXCLUDED.password,
                        created_at = now();
                EXECUTE format('GRANT hex_geoserver_roller TO %I', rollnamn_full);
                EXECUTE format('GRANT %I TO %I', rollnamn_full, system_owner());
                PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                atgard := 'skapad';

            ELSIF EXISTS (
                SELECT 1 FROM pg_roles
                WHERE  rolname = rollnamn_full AND NOT rolcanlogin
            ) THEN
                -- Fall b: rollen finns som NOLOGIN (gammal JNDI) – konvertera
                generated_password := encode(gen_random_bytes(18), 'base64');
                EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L',
                    rollnamn_full, generated_password);
                EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                    current_database(), rollnamn_full);
                INSERT INTO public.hex_role_credentials (rolname, password)
                VALUES (rollnamn_full, generated_password)
                ON CONFLICT (rolname) DO UPDATE
                    SET password   = EXCLUDED.password,
                        created_at = now();
                EXECUTE format('GRANT hex_geoserver_roller TO %I', rollnamn_full);
                atgard := 'konverterad till LOGIN';

            ELSIF NOT EXISTS (
                SELECT 1 FROM public.hex_role_credentials WHERE rolname = rollnamn_full
            ) THEN
                -- Fall c: rollen är LOGIN men saknar post i hex_role_credentials
                generated_password := encode(gen_random_bytes(18), 'base64');
                EXECUTE format('ALTER ROLE %I WITH PASSWORD %L',
                    rollnamn_full, generated_password);
                INSERT INTO public.hex_role_credentials (rolname, password)
                VALUES (rollnamn_full, generated_password);
                atgard := 'lösenord backfyllt';

            ELSE
                atgard := 'redan LOGIN';
            END IF;

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 6. hex_geoserver_roller rollmedlemskap
    --    Alla Hex-skapade LOGIN-roller (lagrade i hex_role_credentials) ska
    --    vara medlemmar i hex_geoserver_roller för pg_hba.conf-matchning.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT rolname AS s
        FROM   public.hex_role_credentials
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

    -- -------------------------------------------------------------------------
    -- 7. Schemabehörigheter
    --    Speglar logiken i hantera_standardiserade_roller: utvärderar
    --    schema_uttryck från standardiserade_roller för varje Hex-schema och
    --    kör tilldela_rollrattigheter på matchande roller som existerar.
    --    Idempotent – säkerställer att GRANT SELECT ON ALL TABLES och
    --    DEFAULT PRIVILEGES är korrekta oavsett när tabeller skapades.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        WHERE  n.nspname ~ schema_regex
        ORDER BY n.nspname
    LOOP
        FOR rol IN
            SELECT rollnamn, rolltyp, schema_uttryck
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

            PERFORM tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);

            schema_namn  := r.s;
            tabell_namn  := rollnamn_full;
            trigger_namn := 'schemabehörigheter';
            atgard       := 'uppdaterade';
            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 8. geoserver_notifiering
    --    Skickar pg_notify('geoserver_schema', schema) för alla Hex-scheman
    --    vars prefix har publiceras_geoserver = true och som har poster i
    --    hex_role_credentials (dvs. lyssnaren kan faktiskt sätta upp datastore).
    --
    --    Täcker tre scenarier:
    --      a) Schema skapades med JNDI – notifiering skickades aldrig
    --      b) Prefix fick publiceras_geoserver = true efter att schemat skapats
    --      c) Lyssnaren var nere när schemat skapades och missade notifieringen
    --
    --    Lyssnaren är idempotent (create_workspace_acl hanterar "already exists"),
    --    så det är säkert att alltid skicka notifieringen.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        JOIN   public.standardiserade_skyddsnivaer ssn
               ON n.nspname LIKE ssn.prefix || '_%'
              AND ssn.publiceras_geoserver = true
        WHERE  EXISTS (
                   SELECT 1 FROM public.hex_role_credentials
                   WHERE rolname = 'r_' || n.nspname
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
    IS 'Återkopplar saknade rad-nivå-triggers (hex_tvinga_gid, hex_kontrollera_geom,
hex_ta_bort_dummy, trg_<tabell>_qa), konverterar NOLOGIN-roller till LOGIN-roller med
autogenererade lösenord (för JNDI-migrering), säkerställer hex_geoserver_roller-
medlemskap för alla Hex-skapade LOGIN-roller, reparerar schemabehörigheter enligt
standardiserade_roller, och skickar pg_notify till GeoServer-lyssnaren för scheman
vars prefix har publiceras_geoserver = true. Schemaprefix hämtas från
standardiserade_skyddsnivaer – egna prefix fungerar utan kodändringar.
Idempotent. Anropas automatiskt av installeraren efter varje installation/uppgradering.';
