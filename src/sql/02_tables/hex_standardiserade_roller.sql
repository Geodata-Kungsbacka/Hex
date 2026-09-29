CREATE TABLE IF NOT EXISTS public.hex_standardiserade_roller (
    gid             integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    rollnamn        text    NOT NULL,
    rolltyp         text    NOT NULL CHECK (rolltyp IN ('read', 'write')),
    schema_uttryck  text    NOT NULL DEFAULT 'IS NOT NULL',
    ta_bort_med_schema boolean DEFAULT true,
    kan_logga_in    boolean DEFAULT false,
    arvs_fran       text    DEFAULT NULL,
    beskrivning     text,
    geoserver_konto text    DEFAULT NULL CHECK (geoserver_konto IN ('las', 'skriv')),

    CONSTRAINT hex_standardiserade_roller_pkey PRIMARY KEY (gid),
    CONSTRAINT hex_standardiserade_roller_rollnamn_key UNIQUE (rollnamn),
    -- NULL räknas som distinkt, så bara 'las' och 'skriv' begränsas till en rad
    -- vardera. DEFERRABLE: återställningen efter --upgrade skriver tillbaka
    -- raderna en i taget, och en DBA som flyttat 'las' till en egen roll får
    -- då ett mellanläge med två 'las' innan standardraden nollställs.
    CONSTRAINT hex_standardiserade_roller_geoserver_konto_key
        UNIQUE (geoserver_konto) DEFERRABLE INITIALLY DEFERRED
);

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_standardiserade_roller OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON TABLE public.hex_standardiserade_roller
    IS 'Definierar vilka roller som ska skapas automatiskt för nya scheman.
    Stöder både schemaspecifika och globala roller.';

COMMENT ON COLUMN public.hex_standardiserade_roller.kan_logga_in
    IS 'Om true skapas rollen med LOGIN och ett autogenererat lösenord (via pgcrypto).
    Lösenordet sparas i hex_rolluppgifter.
    Om false skapas rollen som NOLOGIN (behörighetsgrupp för t.ex. AD-användare).';

COMMENT ON COLUMN public.hex_standardiserade_roller.arvs_fran
    IS 'Om satt, beviljas denna roll till den nya rollen via GRANT istället för att
    hex_tilldela_rollrattigheter() anropas direkt. Stödjer {schema}-substitution.
    Används för att låta gs_r_{schema} och gs_w_{schema} ärva rättigheter från
    r_{schema} respektive w_{schema}, så att behörigheterna hålls synkroniserade.';

COMMENT ON COLUMN public.hex_standardiserade_roller.geoserver_konto
    IS 'Markerar rollen som GeoServers tjänstekonto: ''las'' för läs-workspacen, ''skriv''
    för skriv-workspacen. Högst en rad per värde. hex_geoserver_rollnamn() och
    GeoServer-lyssnaren slår upp kontot via markeringen i stället för via namnet,
    så att rollmallen kan döpas om. Rollen bör ha kan_logga_in = true.';

-- Fyra roller per schema:
--   r_  / w_     – NOLOGIN behörighetsgrupper, tilldelas AD-användare och AD-grupper
--   gs_r_ / gs_w_ – LOGIN tjänstekonton för GeoServer, ärver från r_/w_
INSERT INTO hex_standardiserade_roller (rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran, beskrivning, geoserver_konto)
SELECT v.rollnamn, v.rolltyp, v.schema_uttryck, v.kan_logga_in, v.arvs_fran, v.beskrivning,
       -- Markeringen sätts bara om ingen annan rad redan har den. En DBA som
       -- flyttat den till en egen roll får behålla det valet vid ominstallation.
       CASE WHEN v.geoserver_konto IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM hex_standardiserade_roller b
                             WHERE b.geoserver_konto = v.geoserver_konto)
            THEN v.geoserver_konto
       END
FROM (VALUES
    ('r_{schema}',    'read',  'IS NOT NULL', false, NULL,          'Läsbehörighetsgrupp – tilldelas AD-användare och AD-grupper',        NULL),
    ('w_{schema}',    'write', 'IS NOT NULL', false, NULL,          'Skrivbehörighetsgrupp – tilldelas AD-användare och AD-grupper',      NULL),
    ('gs_r_{schema}', 'read',  'IS NOT NULL', true,  'r_{schema}',  'GeoServer läs-tjänstekonto – ärver behörigheter från r_{schema}',   'las'),
    ('gs_w_{schema}', 'write', 'IS NOT NULL', true,  'w_{schema}',  'GeoServer skriv-tjänstekonto – ärver behörigheter från w_{schema}', 'skriv')
) AS v (rollnamn, rolltyp, schema_uttryck, kan_logga_in, arvs_fran, beskrivning, geoserver_konto)
-- WHERE true: utan den tolkar parsern ON CONFLICT som ett JOIN-villkor.
WHERE true
-- kan_logga_in och arvs_fran rättas på VARJE installation och är avsiktligt inte
-- DBA:ns att ändra på de fyra standardraderna: blir r_/w_ LOGIN hamnar de i
-- hex_geoserver_roller och öppnar pg_hba för behörighetsgrupperna (95ead68).
-- install_hex.py listar samma två kolumner under hex_agda, så att inte heller
-- återställningen efter --upgrade kan skriva tillbaka ett felaktigt värde.
--
-- rolltyp, beskrivning och geoserver_konto skrivs däremot INTE över. En DBA
-- som ändrat dem ska inte få ändringen struken vid nästa ominstallation.
ON CONFLICT (rollnamn) DO UPDATE
    SET kan_logga_in = EXCLUDED.kan_logga_in,
        arvs_fran    = EXCLUDED.arvs_fran;

-- Alla databasanvändare som skapar tabeller behöver läsa dessa konfigurationstabeller,
-- eftersom triggerfunktionerna (hex_hantera_ny_tabell, hex_hantera_ny_kolumn) körs
-- som SECURITY INVOKER (den anropande användarens rättigheter).
GRANT SELECT ON public.hex_standardiserade_roller TO PUBLIC;
