CREATE OR REPLACE FUNCTION public.hex_underhall()
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
 * Schemaprefix hämtas dynamiskt från hex_standardiserade_skyddsnivaer, så att
 * egna prefix (t.ex. sc1, sk3) fungerar utan kodändringar.
 *
 * Hanterar tio åtgärdstyper:
 *
 *   ägarskapsöverföring  Säkerställer att scheman, tabeller, sekvenser och
 *                        funktioner i Hex-hanterade scheman ägs av
 *                        hex_systemagare(). Fångar objekt skapade av
 *                        superusers (t.ex. postgres) innan ägarskapsöverföringen
 *                        lades till i hex_hantera_std_roller och
 *                        hex_hantera_ny_tabell. Körs först.
 *
 *   hex_tvinga_gid       BEFORE INSERT på alla Hex-tabeller med en gid
 *                        IDENTITY-kolumn. Förhindrar att klienter (t.ex. QGIS)
 *                        väljer eget gid via OVERRIDING SYSTEM VALUE.
 *
 *   hex_tvinga_anvandarvarden
 *                        BEFORE INSERT på tabeller med kolumner där
 *                        anvandare_kan_redigera = false. Identifieras via
 *                        trg_fn_*_insert_audit-funktioner i respektive schema.
 *                        Klientvärden kastas tyst; default_varde används.
 *
 *   hex_kontrollera_geom BEFORE INSERT OR UPDATE på geometritabeller vars
 *                        datakategori har hex_validera_geometri = true.
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
 *                        Invarianten är att r_/w_ ska vara NOLOGIN: en r_- eller
 *                        w_-roll som står som LOGIN konverteras tillbaka och tas
 *                        ur hex_geoserver_roller, oavsett hur den blev LOGIN.
 *                        Släpps den igenom hamnar behörighetsgruppen i
 *                        hex_geoserver_roller och öppnar pg_hba.conf för den.
 *                        Säkerställer även WITH ADMIN OPTION på
 *                        hex_systemagare()-granten (behövs på PG16+ för att
 *                        ägarrollen ska kunna GRANT:a r_/w_ vidare utan
 *                        superuser). Idempotent.
 *
 *   hex_geoserver_roller Säkerställer att gs_*-roller (kan_logga_in=true i
 *   (rollmedlemskap)     hex_rolluppgifter) är i hex_geoserver_roller.
 *                        Tar bort NOLOGIN-roller som felaktigt hamnat där.
 *
 *   schemabehörigheter   Kör hex_tilldela_rollrattigheter för NOLOGIN-roller och
 *                        säkerställer GRANT arvs_fran för gs_*-roller.
 *                        Idempotent.
 *
 *   ägarskap_schema      Korrigerar ägare på Hex-scheman som ägs av fel roll.
 *                        Uppstår t.ex. när en superanvändare skapat schemat
 *                        direkt och förbigått event-triggern. Alla scheman vars
 *                        namn matchar schema_regex och vars ägare inte är
 *                        hex_systemagare() åtgärdas. Idempotent.
 *
 *   ägarskap_objekt      Korrigerar ägare på tabeller, vyer, materialiserade
 *                        vyer, sekvenser, fremmande tabeller och funktioner i
 *                        Hex-scheman. Samma schema_regex-filter som övriga
 *                        sektioner. Idempotent.
 *
 *   geoserver_notifiering Skickar pg_notify('geoserver_schema', schema) för
 *                        scheman vars prefix har publiceras_geoserver = true
 *                        och som har gs_r_-uppgifter i hex_rolluppgifter.
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
    -- Varna om Hex är pausat.
    --
    -- hex_ateruppta() kör den här funktionen med flit medan pausen pågår – det
    -- är så en återläsning repareras – så det får inte bli ett fel. Men en
    -- installatörskörning eller ett manuellt anrop mitt under en pg_restore är
    -- något annat: underhållet skapar triggar, delar ut rättigheter och skickar
    -- pg_notify till GeoServer-lyssnaren mot halvt inlästa tabeller. Varningen
    -- är det som gör den skillnaden synlig i loggen.
    --
    -- to_regclass-vakten finns för uppgraderingar: hex_underhall() kan hinna
    -- köras i en databas där hex_paus ännu inte skapats. Kontrollerna måste
    -- vara nästlade – ett kortslutande AND hade räknats som ett uttryck och
    -- parsats i sin helhet, vilket ger UndefinedTable innan vakten hinner slå.
    IF to_regclass('public.hex_paus') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM public.hex_paus) THEN
            RAISE WARNING '[hex_underhall] Hex är pausat (se hex_pausstatus()). '
                          'Underhållet körs ändå. Är det här inte hex_ateruppta() '
                          'som kör, avbryt och vänta tills återläsningen är klar.';
        END IF;
    END IF;

    -- Bygg regex från hex_standardiserade_skyddsnivaer en gång.
    -- Alla schemanamnkontroller i denna funktion använder denna variabel
    -- så att egna prefix fungerar utan kodändringar.
    SELECT '^(' || string_agg(prefix, '|') || ')_'
    INTO   schema_regex
    FROM   public.hex_standardiserade_skyddsnivaer;

    -- -------------------------------------------------------------------------
    -- 0. Ägarskapsöverföring
    --     Säkerställer att alla Hex-hanterade objekt ägs av hex_systemagare().
    --     Fångar scheman och tabeller skapade av superusers innan
    --     hex_hantera_std_roller och hex_hantera_ny_tabell fick inbyggd
    --     ägarskapsöverföring.
    -- -------------------------------------------------------------------------

    -- 0-i. Scheman
    FOR r IN
        SELECT n.nspname AS s
        FROM   pg_namespace n
        JOIN   pg_roles     own ON own.oid = n.nspowner
        WHERE  n.nspname ~ schema_regex
          AND  own.rolname != hex_systemagare()
        ORDER BY n.nspname
    LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.s, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := '-';
        trigger_namn := 'ägarskapsöverföring';
        atgard       := 'schema: ägare uppdaterad';
        RETURN NEXT;
    END LOOP;

    -- 0-ii. Tabeller
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n   ON n.oid = c.relnamespace
        JOIN   pg_roles     own ON own.oid = c.relowner
        WHERE  c.relkind = 'r'
          AND  n.nspname ~ schema_regex
          AND  own.rolname != hex_systemagare()
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', r.s, r.t, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'ägarskapsöverföring';
        atgard       := 'tabell: ägare uppdaterad';
        RETURN NEXT;
    END LOOP;

    -- 0-iii. Sekvenser
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n   ON n.oid = c.relnamespace
        JOIN   pg_roles     own ON own.oid = c.relowner
        WHERE  c.relkind = 'S'
          AND  n.nspname ~ schema_regex
          AND  own.rolname != hex_systemagare()
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', r.s, r.t, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'ägarskapsöverföring';
        atgard       := 'sekvens: ägare uppdaterad';
        RETURN NEXT;
    END LOOP;

    -- 0-iv. Funktioner (t.ex. trg_fn_*_qa som lever i användarscheman)
    FOR r IN
        SELECT n.nspname AS s,
               p.proname AS t,
               pg_get_function_identity_arguments(p.oid) AS args
        FROM   pg_proc      p
        JOIN   pg_namespace n   ON n.oid = p.pronamespace
        JOIN   pg_roles     own ON own.oid = p.proowner
        WHERE  n.nspname ~ schema_regex
          AND  own.rolname != hex_systemagare()
        ORDER BY n.nspname, p.proname
    LOOP
        EXECUTE format('ALTER FUNCTION %I.%I(%s) OWNER TO %I',
            r.s, r.t, r.args, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'ägarskapsöverföring';
        atgard       := 'funktion: ägare uppdaterad';
        RETURN NEXT;
    END LOOP;

    -- 0-v. Vyer
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n   ON n.oid = c.relnamespace
        JOIN   pg_roles     own ON own.oid = c.relowner
        WHERE  c.relkind = 'v'
          AND  n.nspname ~ schema_regex
          AND  own.rolname != hex_systemagare()
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format('ALTER VIEW %I.%I OWNER TO %I', r.s, r.t, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'ägarskapsöverföring';
        atgard       := 'vy: ägare uppdaterad';
        RETURN NEXT;
    END LOOP;

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
                ' FOR EACH ROW EXECUTE FUNCTION public.hex_tvinga_gid_fran_sekvens()',
                r.s, r.t
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 1b. hex_tvinga_anvandarvarden
    --     Tabeller med en trg_fn_*_insert_audit-funktion i respektive schema.
    --     Förhindrar att klienter (t.ex. FME) sätter kolumner med
    --     anvandare_kan_redigera = false (skapad_av, skapad_tidpunkt,
    --     andrad_av, andrad_tidpunkt) vid INSERT.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s, p.proname AS fn
        FROM   pg_proc      p
        JOIN   pg_namespace n ON n.oid = p.pronamespace
        WHERE  n.nspname ~ schema_regex
          AND  p.proname  ~ '^trg_fn_.+_insert_audit$'
        ORDER BY n.nspname, p.proname
    LOOP
        tabell := substring(r.fn FROM '^trg_fn_(.+)_insert_audit$');

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
              AND  t.tgname  = 'hex_tvinga_anvandarvarden'
        ) INTO trig_exists;

        schema_namn  := r.s;
        tabell_namn  := tabell;
        trigger_namn := 'hex_tvinga_anvandarvarden';

        IF NOT trig_exists THEN
            EXECUTE format(
                'CREATE TRIGGER hex_tvinga_anvandarvarden'
                ' BEFORE INSERT ON %I.%I'
                ' FOR EACH ROW EXECUTE FUNCTION %I.%I()',
                r.s, tabell, r.s, r.fn
            );
            atgard := 'skapad';
        ELSE
            atgard := 'redan finns';
        END IF;

        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 2. hex_kontrollera_geom
    --    Scheman vars datakategori har hex_validera_geometri = true i
    --    hex_standardiserade_datakategorier, med en kolumn 'geom' av PostGIS-typ.
    --    Historiktabeller (har h_typ-kolumn) undantas.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s, c.relname AS t
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind = 'r'
          AND  EXISTS (
                   SELECT 1 FROM public.hex_standardiserade_datakategorier d
                   WHERE  d.hex_validera_geometri = true
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
                ' FOR EACH ROW EXECUTE FUNCTION public.hex_kontrollera_geometri_trigger()',
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
                ' FOR EACH ROW EXECUTE FUNCTION public.hex_ta_bort_dummy_rad()',
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
    --    hex_standardiserade_roller. Håller invarianten att r_*/w_* är NOLOGIN
    --    och gs_r_*/gs_w_* är LOGIN, oavsett hur ett avvikande värde uppstått.
    --
    --    NOLOGIN-roller (kan_logga_in=false, t.ex. r_*, w_*):
    --      a) Saknas helt              → CREATE NOLOGIN, behörigheter, hex_rolluppgifter
    --      b) Är LOGIN (ska inte vara) → ALTER NOLOGIN, REVOKE hex_geoserver_roller,
    --                                    uppdatera hex_rolluppgifter
    --      c) Finns som NOLOGIN        → säkerställ hex_rolluppgifter-post
    --
    --    LOGIN-roller med arvs_fran (kan_logga_in=true, t.ex. gs_r_*, gs_w_*):
    --      a) Saknas helt              → CREATE LOGIN, lösenord, hex_geoserver_roller,
    --                                    GRANT arvs_fran, hex_rolluppgifter
    --      b) LOGIN, saknar credentials → backfyll lösenord i hex_rolluppgifter
    --      c) Allt korrekt             → 'redan korrekt'
    --
    --    Alltid säkerställs: behörigheter (NOLOGIN), arvs_fran-grant (LOGIN),
    --    hex_rolluppgifter-post, hex_systemagare-grant (NOLOGIN).
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT n.nspname AS s
        FROM   pg_namespace n
        WHERE  n.nspname ~ schema_regex
        ORDER BY n.nspname
    LOOP
        FOR rol IN
            SELECT rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran
            FROM   public.hex_standardiserade_roller
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

            IF NOT rol.kan_logga_in THEN
                -- -------------------------------------------------------
                -- NOLOGIN behörighetsgrupp (r_*, w_*)
                -- -------------------------------------------------------
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full) THEN
                    -- Fall a: saknas helt
                    EXECUTE format('CREATE ROLE %I WITH NOLOGIN', rollnamn_full);
                    INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rollnamn) DO UPDATE
                        SET kan_logga_in = false, losenord = NULL, skapad_tidpunkt = now();
                    -- WITH ADMIN OPTION: ägarrollen (t.ex. gis_admin) behöver detta för att
                    -- själv kunna GRANT:a rollen vidare till AD-användare, utan superuser.
                    EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', rollnamn_full, hex_systemagare());
                    PERFORM hex_tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'NOLOGIN-grupp skapad';

                ELSIF EXISTS (
                    SELECT 1 FROM pg_roles WHERE rolname = rollnamn_full AND rolcanlogin
                ) THEN
                    -- Fall b: står som LOGIN – tvinga tillbaka till NOLOGIN.
                    -- r_/w_ är behörighetsgrupper och får aldrig kunna logga in;
                    -- en LOGIN-roll här hamnar i hex_geoserver_roller och öppnar
                    -- pg_hba.conf för gruppen (buggen 95ead68 stängde).
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
                    -- Uppdatera hex_rolluppgifter
                    INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rollnamn) DO UPDATE
                        SET kan_logga_in = false, losenord = NULL, skapad_tidpunkt = now();
                    -- Säkerställ hex_systemagare-grant MED ADMIN OPTION. Kontrollerar
                    -- admin_option specifikt (inte bara medlemskap) så att en roll som
                    -- redan finns som vanlig medlem utan ADMIN OPTION (t.ex. beviljad av en
                    -- äldre Hex-version) uppgraderas i stället för att hoppas över.
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = rollnamn_full
                          AND mem.rolname = hex_systemagare()
                          AND am.admin_option
                    ) THEN
                        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', rollnamn_full, hex_systemagare());
                    END IF;
                    PERFORM hex_tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'LOGIN→NOLOGIN rättad';

                ELSE
                    -- Fall c: finns som NOLOGIN – säkerställ hex_rolluppgifter
                    INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)
                    VALUES (rollnamn_full, NULL, false)
                    ON CONFLICT (rollnamn) DO UPDATE
                        SET kan_logga_in = false, losenord = NULL;
                    -- Säkerställ hex_systemagare-grant MED ADMIN OPTION (se motsvarande
                    -- kommentar i Fall b ovan för varför admin_option kontrolleras explicit).
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_auth_members am
                        JOIN pg_roles grp ON grp.oid = am.roleid
                        JOIN pg_roles mem ON mem.oid = am.member
                        WHERE grp.rolname = rollnamn_full
                          AND mem.rolname = hex_systemagare()
                          AND am.admin_option
                    ) THEN
                        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', rollnamn_full, hex_systemagare());
                        atgard := 'ADMIN OPTION tillagd';
                    ELSE
                        atgard := 'redan NOLOGIN';
                    END IF;
                    PERFORM hex_tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
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
                    INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)
                    VALUES (rollnamn_full, generated_password, true)
                    ON CONFLICT (rollnamn) DO UPDATE
                        SET losenord = EXCLUDED.losenord, kan_logga_in = true, skapad_tidpunkt = now();
                    atgard := 'LOGIN-tjänstekonto skapad';

                ELSIF NOT EXISTS (
                    SELECT 1 FROM public.hex_rolluppgifter
                    WHERE rollnamn = rollnamn_full AND kan_logga_in = true
                ) THEN
                    -- Fall b: finns som LOGIN men saknar uppgifter – backfyll
                    generated_password := encode(gen_random_bytes(18), 'base64');
                    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L',
                        rollnamn_full, generated_password);
                    INSERT INTO public.hex_rolluppgifter (rollnamn, losenord, kan_logga_in)
                    VALUES (rollnamn_full, generated_password, true)
                    ON CONFLICT (rollnamn) DO UPDATE
                        SET losenord = EXCLUDED.losenord, kan_logga_in = true, skapad_tidpunkt = now();
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
    --    Säkerställer att gs_*-roller (kan_logga_in=true) är i hex_geoserver_roller.
    --    Tar också bort NOLOGIN-roller (kan_logga_in=false) som felaktigt hamnat
    --    i hex_geoserver_roller – de skulle annars öppna pg_hba.conf för en
    --    behörighetsgrupp.
    -- -------------------------------------------------------------------------

    -- 6a. Lägg till saknade LOGIN-roller
    FOR r IN
        SELECT rollnamn AS s
        FROM   public.hex_rolluppgifter
        WHERE  kan_logga_in = true
        ORDER BY rollnamn
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
        SELECT hru.rollnamn AS s
        FROM   public.hex_rolluppgifter hru
        WHERE  hru.kan_logga_in = false
          AND  EXISTS (
                   SELECT 1 FROM pg_auth_members am
                   JOIN pg_roles grp ON grp.oid = am.roleid
                   JOIN pg_roles mem ON mem.oid = am.member
                   WHERE grp.rolname = 'hex_geoserver_roller'
                     AND mem.rolname = hru.rollnamn
               )
        ORDER BY hru.rollnamn
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
    --    För NOLOGIN-roller: kör hex_tilldela_rollrattigheter (idempotent).
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
            SELECT rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran
            FROM   public.hex_standardiserade_roller
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

            IF NOT rol.kan_logga_in THEN
                -- NOLOGIN-roll: direkta schemabehörigheter
                PERFORM hex_tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
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
                    PERFORM hex_tilldela_rollrattigheter(r.s, rollnamn_full, rol.rolltyp);
                    atgard := 'behörigheter uppdaterade';
                END IF;
            END IF;

            RETURN NEXT;
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 8. ägarskap_schema
    --    Alla Hex-scheman (namn matchar schema_regex) vars nuvarande ägare
    --    inte är hex_systemagare() korrigeras med ALTER SCHEMA ... OWNER TO.
    --    Täcker scenariot där en superanvändare skapade schemat direkt och
    --    förbigick event-triggern hantera_standardiserade_roller.
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT n.nspname AS s,
               ro.rolname AS nuvarande_agare
        FROM   pg_catalog.pg_namespace n
        JOIN   pg_catalog.pg_roles     ro ON ro.oid = n.nspowner
        WHERE  n.nspname ~ schema_regex
          AND  ro.rolname != hex_systemagare()
        ORDER BY n.nspname
    LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.s, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := '-';
        trigger_namn := 'ägarskap_schema';
        atgard       := 'ägare korrigerad: ' || r.nuvarande_agare || ' → ' || hex_systemagare();
        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 9. ägarskap_objekt
    --    Tabeller, vyer, materialiserade vyer, sekvenser och fremmande tabeller
    --    i Hex-scheman vars ägare inte är hex_systemagare() korrigeras.
    --    Därefter korrigeras funktioner/procedurer i samma scheman.
    --    Idempotent – objekt med rätt ägare berörs inte.
    -- -------------------------------------------------------------------------

    -- 9a. Relationsobjekt (relkind r/v/m/S/f)
    FOR r IN
        SELECT n.nspname                AS s,
               c.relname               AS t,
               c.relkind               AS k,
               ro.rolname              AS nuvarande_agare
        FROM   pg_catalog.pg_class     c
        JOIN   pg_catalog.pg_namespace n  ON n.oid = c.relnamespace
        JOIN   pg_catalog.pg_roles     ro ON ro.oid = c.relowner
        WHERE  n.nspname ~ schema_regex
          AND  c.relkind IN ('r', 'v', 'm', 'S', 'f')
          AND  ro.rolname != hex_systemagare()
          -- Identitetssekvenser ägs av sin kolumn; ägandet kaskaderar automatiskt
          -- när tabellen byter ägare via ALTER TABLE. Direkt ALTER SEQUENCE OWNER TO
          -- på en identitetssekvens (deptype='i') är inte tillåtet i PostgreSQL.
          AND  NOT (c.relkind = 'S' AND EXISTS (
                   SELECT 1 FROM pg_catalog.pg_depend d
                   WHERE d.objid = c.oid AND d.deptype = 'i'))
        ORDER BY n.nspname, c.relname
    LOOP
        CASE r.k
            WHEN 'r' THEN
                EXECUTE format('ALTER TABLE %I.%I OWNER TO %I',
                    r.s, r.t, hex_systemagare());
            WHEN 'v' THEN
                EXECUTE format('ALTER VIEW %I.%I OWNER TO %I',
                    r.s, r.t, hex_systemagare());
            WHEN 'm' THEN
                EXECUTE format('ALTER MATERIALIZED VIEW %I.%I OWNER TO %I',
                    r.s, r.t, hex_systemagare());
            WHEN 'S' THEN
                EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I',
                    r.s, r.t, hex_systemagare());
            WHEN 'f' THEN
                EXECUTE format('ALTER FOREIGN TABLE %I.%I OWNER TO %I',
                    r.s, r.t, hex_systemagare());
        END CASE;
        schema_namn  := r.s;
        tabell_namn  := r.t;
        trigger_namn := 'ägarskap_objekt';
        atgard       := 'ägare korrigerad: ' || r.nuvarande_agare || ' → ' || hex_systemagare();
        RETURN NEXT;
    END LOOP;

    -- 9b. Funktioner och procedurer
    FOR r IN
        SELECT n.nspname                                     AS s,
               p.proname                                     AS fn,
               pg_catalog.pg_get_function_identity_arguments(p.oid) AS args,
               ro.rolname                                    AS nuvarande_agare
        FROM   pg_catalog.pg_proc      p
        JOIN   pg_catalog.pg_namespace n  ON n.oid = p.pronamespace
        JOIN   pg_catalog.pg_roles     ro ON ro.oid = p.proowner
        WHERE  n.nspname ~ schema_regex
          AND  ro.rolname != hex_systemagare()
        ORDER BY n.nspname, p.proname
    LOOP
        EXECUTE format('ALTER FUNCTION %I.%I(%s) OWNER TO %I',
            r.s, r.fn, r.args, hex_systemagare());
        schema_namn  := r.s;
        tabell_namn  := r.fn;
        trigger_namn := 'ägarskap_objekt';
        atgard       := 'ägare korrigerad: ' || r.nuvarande_agare || ' → ' || hex_systemagare();
        RETURN NEXT;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 10. geoserver_notifiering
    --    Skickar pg_notify('geoserver_schema', schema) för alla Hex-scheman
    --    vars prefix har publiceras_geoserver = true och som har gs_r_-uppgifter
    --    i hex_rolluppgifter (dvs. lyssnaren kan sätta upp datastore).
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
        JOIN   public.hex_standardiserade_skyddsnivaer ssn
               ON n.nspname LIKE ssn.prefix || '_%'
              AND ssn.publiceras_geoserver = true
        WHERE  EXISTS (
                   SELECT 1 FROM public.hex_rolluppgifter
                   WHERE  rollnamn     = 'gs_r_' || n.nspname
                     AND  kan_logga_in = true
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

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_underhall() OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_underhall()
    IS 'Reparerar och verifierar hela Hex-strukturen för alla scheman.
Överför ägarskap av scheman, tabeller, sekvenser, funktioner och vyer till hex_systemagare()
  – fångar objekt skapade av superusers innan ägarskapsöverföringen lades till i
  hex_hantera_std_roller/hex_hantera_ny_tabell.
Återkopplar saknade rad-nivå-triggers (hex_tvinga_gid, hex_tvinga_anvandarvarden, hex_kontrollera_geom,
hex_ta_bort_dummy, trg_<tabell>_qa).
Verifierar och reparerar alla fyra roller per schema:
  r_{schema}/w_{schema}       NOLOGIN behörighetsgrupper – tilldelas AD-användare
  gs_r_{schema}/gs_w_{schema} LOGIN GeoServer-tjänstekonton – i hex_geoserver_roller
Tvingar tillbaka r_*/w_* till NOLOGIN om de står som LOGIN och skapar saknade gs_*.
Uppgraderar hex_systemagare()-medlemskap på r_/w_-roller till WITH ADMIN OPTION
om det saknas, så att ägarrollen kan GRANT:a dem vidare utan superuser.
Säkerställer hex_geoserver_roller-medlemskap (enbart gs_*) och tar bort
NOLOGIN-roller som felaktigt hamnat där.
Reparerar schemabehörigheter (NOLOGIN: hex_tilldela_rollrattigheter,
LOGIN: GRANT arvs_fran).
Korrigerar schemaägare som inte är hex_systemagare() – täcker scheman skapade av
superanvändare som förbigick event-triggern.
Korrigerar objektägare (tabeller, vyer, materialiserade vyer, sekvenser,
fremmande tabeller, funktioner) i Hex-scheman vars ägare inte är hex_systemagare().
Skickar pg_notify för GeoServer-publicering (gs_r_-uppgifter krävs).
Schemaprefix hämtas från hex_standardiserade_skyddsnivaer – egna prefix fungerar
utan kodändringar. Idempotent. Anropas av installeraren efter varje
installation/uppgradering.';
