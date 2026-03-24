CREATE OR REPLACE FUNCTION public.tillämpa_grupprattigheter()
    RETURNS TABLE (
        behandlade    integer,
        beviljade     integer,
        hoppade_over  integer,
        fel           integer
    )
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    SECURITY DEFINER
    SET search_path = public
AS $BODY$

/******************************************************************************
 * Applicerar alla mappningar i hex_grupprattigheter:
 * beviljar Hex-schemaroller till AD-synkade grupproller.
 *
 * Kontrollerar att båda roller existerar i pg_roles innan GRANT genomförs.
 * Loggar (via RAISE NOTICE) varje beviljad och hoppats-över rad med orsak.
 * Idempotent – kan köras upprepade gånger utan biverkningar.
 *
 * SECURITY DEFINER: Körs med ägarrollens (system_owner) rättigheter.
 * system_owner har ADMIN OPTION på alla Hex-schemaroller (beviljas i
 * hantera_standardiserade_roller vid skapandet), vilket krävs för att
 * kunna GRANT:a dessa roller vidare till AD-grupproller.
 *
 * Anropas manuellt av DBA efter att rader lagts till i hex_grupprattigheter:
 *   SELECT * FROM tillämpa_grupprattigheter();
 *
 * RETURNERAR: en rad med sammanfattning (behandlade, beviljade,
 *             hoppade_over, fel)
 ******************************************************************************/
DECLARE
    v_behandlade    integer := 0;
    v_beviljade     integer := 0;
    v_hoppade_over  integer := 0;
    v_fel           integer := 0;

    r               record;
    v_ad_finns      boolean;
    v_hex_finns     boolean;
BEGIN
    RAISE NOTICE '[tillämpa_grupprattigheter] === START ===';

    FOR r IN
        SELECT id, ad_grupproll, hex_roll
          FROM public.hex_grupprattigheter
         ORDER BY id
    LOOP
        v_behandlade := v_behandlade + 1;

        -- Kontrollera att AD-grupproll finns i pg_roles
        SELECT EXISTS (
            SELECT 1 FROM pg_roles WHERE rolname = r.ad_grupproll
        ) INTO v_ad_finns;

        IF NOT v_ad_finns THEN
            RAISE NOTICE '[tillämpa_grupprattigheter] Hoppar över rad %: AD-roll "%" finns inte i pg_roles',
                r.id, r.ad_grupproll;
            v_hoppade_over := v_hoppade_over + 1;
            CONTINUE;
        END IF;

        -- Kontrollera att Hex-schemaroll finns i pg_roles
        SELECT EXISTS (
            SELECT 1 FROM pg_roles WHERE rolname = r.hex_roll
        ) INTO v_hex_finns;

        IF NOT v_hex_finns THEN
            RAISE NOTICE '[tillämpa_grupprattigheter] Hoppar över rad %: Hex-roll "%" finns inte i pg_roles',
                r.id, r.hex_roll;
            v_hoppade_over := v_hoppade_over + 1;
            CONTINUE;
        END IF;

        -- Bevilja Hex-schemarollen till AD-grupproll
        BEGIN
            EXECUTE format('GRANT %I TO %I', r.hex_roll, r.ad_grupproll);
            RAISE NOTICE '[tillämpa_grupprattigheter] GRANT % TO % – beviljad (rad %)',
                r.hex_roll, r.ad_grupproll, r.id;
            v_beviljade := v_beviljade + 1;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '[tillämpa_grupprattigheter] FEL vid GRANT % TO % (rad %): %',
                    r.hex_roll, r.ad_grupproll, r.id, SQLERRM;
                v_fel := v_fel + 1;
        END;

    END LOOP;

    RAISE NOTICE '[tillämpa_grupprattigheter] === SLUT === behandlade: %, beviljade: %, hoppade_over: %, fel: %',
        v_behandlade, v_beviljade, v_hoppade_over, v_fel;

    RETURN QUERY
        SELECT v_behandlade, v_beviljade, v_hoppade_over, v_fel;
END;
$BODY$;

ALTER FUNCTION public.tillämpa_grupprattigheter()
    OWNER TO gis_admin;

COMMENT ON FUNCTION public.tillämpa_grupprattigheter()
    IS 'Applicerar mappningar i hex_grupprattigheter: beviljar Hex-schemaroller till
     AD-synkade grupproller. Kontrollerar att båda roller existerar i pg_roles.
     Idempotent – kan köras upprepade gånger. Returnerar sammanfattningsrad.
     Anropas manuellt av DBA: SELECT * FROM tillämpa_grupprattigheter();';
