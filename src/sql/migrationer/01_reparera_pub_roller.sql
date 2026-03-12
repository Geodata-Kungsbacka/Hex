-- =============================================================================
-- MIGRATION: Reparera och normalisera _pub-roller
-- =============================================================================
-- Hanterar två problem:
--
--   1. GAMLA LOGINROLLER (_cesium, _geoserver, _qgis)
--      Skapar en motsvarande _pub LOGIN-roll och ger den samma grupmedlemskap
--      som den gamla rollen. Den gamla rollen berörs inte - ta bort den manuellt
--      när du bekräftat att allt fungerar.
--
--   2. SAKNADE SKX-ROLLER
--      Skapar r_{schema}, r_{schema}_pub, w_{schema} och w_{schema}_pub för
--      befintliga skx_*-scheman som skapades innan skx fick _pub-behandling.
--
-- Kör som postgres eller gis_admin (superuser krävs för CREATE ROLE).
-- Idempotent - kan köras flera gånger utan skada.
-- =============================================================================

DO $$
DECLARE
    -- Del 1
    v_old_role      text;
    v_old_suffix    text;
    v_new_role      text;
    v_grp           text;
    v_found_groups  integer;

    -- Del 2
    v_schema        text;
    v_grp_read      text;
    v_login_read    text;
    v_grp_write     text;
    v_login_write   text;

    -- Gemensamt
    v_owner         text;
BEGIN
    -- Lös upp system_owner() om funktionen finns i denna databas,
    -- annars fall tillbaka på 'gis_admin'.
    BEGIN
        SELECT system_owner() INTO v_owner;
    EXCEPTION WHEN undefined_function THEN
        v_owner := 'gis_admin';
        RAISE NOTICE 'system_owner() saknas i denna databas – använder ''gis_admin'' som ägare.';
    END;

-- =============================================================================
-- DEL 1: Skapa _pub-roller för gamla _cesium / _geoserver / _qgis loginroller
-- =============================================================================
RAISE NOTICE '';
RAISE NOTICE '=== DEL 1: Gamla loginroller → _pub ===';

FOR v_old_role, v_old_suffix IN
    SELECT rolname,
           CASE
               WHEN rolname LIKE '%\_cesium'    THEN '_cesium'
               WHEN rolname LIKE '%\_geoserver' THEN '_geoserver'
               WHEN rolname LIKE '%\_qgis'      THEN '_qgis'
           END
    FROM pg_roles
    WHERE rolcanlogin = true
      AND (   rolname LIKE '%\_cesium'
           OR rolname LIKE '%\_geoserver'
           OR rolname LIKE '%\_qgis')
    ORDER BY rolname
LOOP
    -- Härledd _pub-roll: byt ut det gamla suffixet mot _pub
    v_new_role := left(v_old_role, length(v_old_role) - length(v_old_suffix)) || '_pub';

    RAISE NOTICE '';
    RAISE NOTICE '--- Gammal roll: %', v_old_role;
    RAISE NOTICE '    → Ny _pub-roll: %', v_new_role;

    -- Skapa _pub LOGIN-roll om den saknas
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_new_role) THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN', v_new_role);
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', v_new_role, v_owner);
        RAISE NOTICE '    ✓ Skapade LOGIN-roll: %', v_new_role;
    ELSE
        RAISE NOTICE '    - LOGIN-roll finns redan: %', v_new_role;
    END IF;

    -- Kopiera alla grupmedlemskap från den gamla rollen
    v_found_groups := 0;
    FOR v_grp IN
        SELECT gr.rolname
        FROM pg_auth_members am
        JOIN pg_roles gr ON gr.oid = am.roleid
        WHERE am.member = (SELECT oid FROM pg_roles WHERE rolname = v_old_role)
        ORDER BY gr.rolname
    LOOP
        v_found_groups := v_found_groups + 1;

        IF NOT EXISTS (
            SELECT 1 FROM pg_auth_members
            WHERE roleid = (SELECT oid FROM pg_roles WHERE rolname = v_grp)
              AND member = (SELECT oid FROM pg_roles WHERE rolname = v_new_role)
        ) THEN
            EXECUTE format('GRANT %I TO %I', v_grp, v_new_role);
            RAISE NOTICE '    ✓ Tilldelade grupp: % → %', v_grp, v_new_role;
        ELSE
            RAISE NOTICE '    - Redan medlem i: %', v_grp;
        END IF;
    END LOOP;

    IF v_found_groups = 0 THEN
        RAISE WARNING '    ! Inga grupmedlemskap hittades för %. Kontrollera att grupproller finns.', v_old_role;
    END IF;

END LOOP;

RAISE NOTICE '';
RAISE NOTICE '=== DEL 1 klar ===';


-- =============================================================================
-- DEL 2: Skapa saknade roller för befintliga skx_*-scheman
-- =============================================================================
RAISE NOTICE '';
RAISE NOTICE '=== DEL 2: Saknade roller för skx_*-scheman ===';

FOR v_schema IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname LIKE 'skx\_%' ESCAPE '\'
    ORDER BY nspname
LOOP
    v_grp_read   := 'r_' || v_schema;
    v_login_read := 'r_' || v_schema || '_pub';
    v_grp_write  := 'w_' || v_schema;
    v_login_write := 'w_' || v_schema || '_pub';

    RAISE NOTICE '';
    RAISE NOTICE '--- Schema: %', v_schema;

    -- Läs-grupproll
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_grp_read) THEN
        EXECUTE format('CREATE ROLE %I WITH NOLOGIN', v_grp_read);
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', v_grp_read, v_owner);
        PERFORM tilldela_rollrattigheter(v_schema, v_grp_read, 'read');
        RAISE NOTICE '    ✓ Skapade grupproll (NOLOGIN): %', v_grp_read;
    ELSE
        RAISE NOTICE '    - Grupproll finns redan: %', v_grp_read;
        -- Säkerställ att rättigheterna är aktuella ändå
        PERFORM tilldela_rollrattigheter(v_schema, v_grp_read, 'read');
    END IF;

    -- Läs-loginroll
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_login_read) THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN', v_login_read);
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', v_login_read, v_owner);
        EXECUTE format('GRANT %I TO %I', v_grp_read, v_login_read);
        RAISE NOTICE '    ✓ Skapade LOGIN-roll: %', v_login_read;
    ELSE
        RAISE NOTICE '    - LOGIN-roll finns redan: %', v_login_read;
    END IF;

    -- Skriv-grupproll
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_grp_write) THEN
        EXECUTE format('CREATE ROLE %I WITH NOLOGIN', v_grp_write);
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', v_grp_write, v_owner);
        PERFORM tilldela_rollrattigheter(v_schema, v_grp_write, 'write');
        RAISE NOTICE '    ✓ Skapade grupproll (NOLOGIN): %', v_grp_write;
    ELSE
        RAISE NOTICE '    - Grupproll finns redan: %', v_grp_write;
        PERFORM tilldela_rollrattigheter(v_schema, v_grp_write, 'write');
    END IF;

    -- Skriv-loginroll
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_login_write) THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN', v_login_write);
        EXECUTE format('GRANT %I TO %I WITH ADMIN OPTION', v_login_write, v_owner);
        EXECUTE format('GRANT %I TO %I', v_grp_write, v_login_write);
        RAISE NOTICE '    ✓ Skapade LOGIN-roll: %', v_login_write;
    ELSE
        RAISE NOTICE '    - LOGIN-roll finns redan: %', v_login_write;
    END IF;

END LOOP;

RAISE NOTICE '';
RAISE NOTICE '=== DEL 2 klar ===';


-- =============================================================================
-- DEL 3: Backfill tabellrättigheter för globala roller (sk0, sk1)
-- =============================================================================
-- r_sk0_global och r_sk1_global skapas en gång och ärver sedan automatiskt
-- USAGE + SELECT på nya scheman via event-triggern. Men scheman som skapades
-- INNAN triggern, eller innan rollen fick en _pub-loginroll, saknar dessa
-- rättigheter på befintliga tabeller. tilldela_rollrattigheter är idempotent.
-- =============================================================================
RAISE NOTICE '';
RAISE NOTICE '=== DEL 3: Backfill tabellrättigheter för globala roller ===';

FOR v_schema IN
    SELECT nspname FROM pg_namespace WHERE nspname LIKE 'sk0\_%' ESCAPE '\'
    ORDER BY nspname
LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk0_global') THEN
        PERFORM tilldela_rollrattigheter(v_schema, 'r_sk0_global', 'read');
        RAISE NOTICE '    ✓ Backfilled r_sk0_global på %', v_schema;
    ELSE
        RAISE WARNING '    ! r_sk0_global saknas – hoppar över %', v_schema;
    END IF;
END LOOP;

FOR v_schema IN
    SELECT nspname FROM pg_namespace WHERE nspname LIKE 'sk1\_%' ESCAPE '\'
    ORDER BY nspname
LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r_sk1_global') THEN
        PERFORM tilldela_rollrattigheter(v_schema, 'r_sk1_global', 'read');
        RAISE NOTICE '    ✓ Backfilled r_sk1_global på %', v_schema;
    ELSE
        RAISE WARNING '    ! r_sk1_global saknas – hoppar över %', v_schema;
    END IF;
END LOOP;

RAISE NOTICE '';
RAISE NOTICE '=== DEL 3 klar ===';
RAISE NOTICE '';
RAISE NOTICE 'Migration slutförd.';
RAISE NOTICE 'Gamla _cesium/_geoserver/_qgis-roller är INTE borttagna.';
RAISE NOTICE 'Verifiera _pub-rollerna och ta sedan bort de gamla manuellt:';
RAISE NOTICE '  SELECT rolname FROM pg_roles WHERE rolname LIKE ''%%_cesium'' OR rolname LIKE ''%%_geoserver'' OR rolname LIKE ''%%_qgis'';';

END $$;
