CREATE OR REPLACE FUNCTION public.skapa_historik_qa(
    p_schema_namn text,
    p_tabell_namn text
)
    RETURNS boolean
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Skapar historiktabell och QA-triggers om minst en kolumn har historik_qa.
 * 
 * Historiktabellen har historikkolumner FÖRST:
 * - h_typ: 'U' för UPDATE, 'D' för DELETE
 * - h_tidpunkt: När operationen utfördes
 * - h_av: Vem som utförde operationen
 * Följt av alla kolumner från modertabellen.
 *
 * UPPDATERAD: Använder nu session_user istället för current_user för att
 * fånga den faktiskt autentiserade användaren (inte SET ROLE-identitet).
 *
 * UPPDATERAD: Använder nu hamta_geometri_definition() för korrekt 
 * geometrihantering i historiktabeller.
 ******************************************************************************/
DECLARE
    qa_kolumner text[];
    qa_uttryck text[];
    trigger_satser text := '';
    trigger_funktionsnamn text;
    i integer;
    kolumn_lista text;
    kolumn_definitioner text;
    antal_qa_kolumner integer := 0;
    antal_original_kolumner integer := 0;
    op_steg text;  -- För felhantering
    
    -- Nya variabler för geometrihantering
    har_geometri boolean := false;
    geometriinfo geom_info;
BEGIN
    RAISE NOTICE E'[skapa_historik_qa] === START ===';
    RAISE NOTICE '[skapa_historik_qa] Skapar historik/QA för %.%', p_schema_namn, p_tabell_namn;
    
    -- Steg 1: Kontrollera QA-kolumner
    op_steg := 'kontrollera qa-kolumner';
    RAISE NOTICE '[skapa_historik_qa] Steg 1: Kontrollerar QA-kolumner';
    
    SELECT 
        array_agg(sk.kolumnnamn ORDER BY sk.ordinal_position),
        array_agg(sk.default_varde ORDER BY sk.ordinal_position)
    INTO qa_kolumner, qa_uttryck
    FROM standardiserade_kolumner sk
    WHERE sk.historik_qa = true
    AND sk.default_varde IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = p_schema_namn 
        AND c.table_name = p_tabell_namn 
        AND c.column_name = sk.kolumnnamn
    );
    
    antal_qa_kolumner := COALESCE(array_length(qa_kolumner, 1), 0);
    
    IF antal_qa_kolumner = 0 THEN
        RAISE NOTICE '[skapa_historik_qa]   » Inga QA-kolumner med historik_qa = true hittades';
        RAISE NOTICE '[skapa_historik_qa] === AVBRUTEN (ingen historik behövs) ===';
        RETURN false;
    END IF;
    
    RAISE NOTICE '[skapa_historik_qa]   » Hittade % QA-kolumner:', antal_qa_kolumner;
    FOR i IN 1..antal_qa_kolumner LOOP
        RAISE NOTICE '[skapa_historik_qa]     #%: % (uttryck: %)',
            i, qa_kolumner[i], qa_uttryck[i];
    END LOOP;
    
    -- Steg 2: Kontrollera om tabellen har geometri
    op_steg := 'kontrollera geometri';
    RAISE NOTICE '[skapa_historik_qa] Steg 2: Kontrollerar geometrikolumn';
    
    SELECT EXISTS(
        SELECT 1 FROM geometry_columns
        WHERE f_table_schema = p_schema_namn 
        AND f_table_name = p_tabell_namn
        AND f_geometry_column = 'geom'
    ) INTO har_geometri;
    
    IF har_geometri THEN
        RAISE NOTICE '[skapa_historik_qa]   » Geometrikolumn upptäckt - hämtar definition';
        geometriinfo := hamta_geometri_definition(p_schema_namn, p_tabell_namn);
        RAISE NOTICE '[skapa_historik_qa]   » Geometridefinition: %s', geometriinfo.definition;
    ELSE
        RAISE NOTICE '[skapa_historik_qa]   » Ingen geometrikolumn funnen';
    END IF;
    
    -- Steg 3: Hämta kolumndefinitioner från originaltabellen
    op_steg := 'hämta kolumndefinitioner';
    RAISE NOTICE '[skapa_historik_qa] Steg 3: Analyserar originaltabellens struktur';
    
    SELECT 
        string_agg(
            format('%I %s%s',
                c.column_name,
                -- Datatyp med specialhantering för geometri
                CASE 
                    WHEN c.data_type = 'USER-DEFINED' AND c.udt_name = 'geometry' AND har_geometri THEN
                        -- Använd hjälpfunktionen för korrekt geometridefinition
                        geometriinfo.definition
                    WHEN c.data_type = 'USER-DEFINED' THEN 
                        c.udt_name
                    WHEN c.data_type = 'character varying' THEN 
                        'character varying' || 
                        CASE WHEN c.character_maximum_length IS NOT NULL 
                             THEN '(' || c.character_maximum_length || ')'
                             ELSE ''
                        END
                    WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL THEN 
                        'numeric(' || c.numeric_precision || ',' || c.numeric_scale || ')'
                    ELSE c.data_type
                END,
                -- COLLATE om det finns
                CASE 
                    WHEN c.collation_name IS NOT NULL 
                    THEN ' COLLATE ' || c.collation_name 
                    ELSE '' 
                END
            ),
            E',\n        '
            ORDER BY c.ordinal_position
        ),
        COUNT(*)
    INTO kolumn_definitioner, antal_original_kolumner
    FROM information_schema.columns c
    WHERE c.table_schema = p_schema_namn
    AND c.table_name = p_tabell_namn;
    
    RAISE NOTICE '[skapa_historik_qa]   » Originaltabell har %s kolumner', antal_original_kolumner;
    
    -- Hämta kolumnnamn för INSERT
    SELECT string_agg(c.column_name, ', ' ORDER BY c.ordinal_position)
    INTO kolumn_lista
    FROM information_schema.columns c
    WHERE c.table_schema = p_schema_namn
    AND c.table_name = p_tabell_namn;
    
    RAISE NOTICE '[skapa_historik_qa]   » Kolumnlista för INSERT: %s', 
        substring(kolumn_lista from 1 for 50) || 
        CASE WHEN length(kolumn_lista) > 50 THEN '...' ELSE '' END;
    
    -- Steg 4: Skapa historiktabell
    -- ÄNDRING: Använder session_user istället för current_user
    op_steg := 'skapa historiktabell';
    RAISE NOTICE '[skapa_historik_qa] Steg 4: Skapar historiktabell';
    RAISE NOTICE '[skapa_historik_qa]   » Tabellnamn: %s.%s', p_schema_namn, p_tabell_namn || '_h';
    RAISE NOTICE '[skapa_historik_qa]   » Med 3 h_-kolumner + %s originalkolumner', antal_original_kolumner;
    
    EXECUTE format(
        'CREATE TABLE %I.%I (
        h_typ char(1) NOT NULL CHECK (h_typ IN (''U'', ''D'')),
        h_tidpunkt timestamptz NOT NULL DEFAULT NOW(),
        h_av text NOT NULL DEFAULT session_user,
        %s
    )',
        p_schema_namn, p_tabell_namn || '_h',
        kolumn_definitioner
    );
    RAISE NOTICE '[skapa_historik_qa]   ✓ Historiktabell skapad';
    
    -- Steg 5: Skapa index
    op_steg := 'skapa index';
    RAISE NOTICE '[skapa_historik_qa] Steg 5: Skapar index för prestanda';
    
    -- Index name capped at 56 chars to avoid colliding with the 63-char history
    -- table name when p_tabell_namn is 61+ characters long.
    EXECUTE format(
        'CREATE INDEX %I ON %I.%I (gid, h_tidpunkt DESC)',
        left(p_tabell_namn, 50) || '_h_idx',
        p_schema_namn, p_tabell_namn || '_h'
    );
    RAISE NOTICE '[skapa_historik_qa]   ✓ Index skapat: %', left(p_tabell_namn, 50) || '_h_idx';
    
    -- Steg 6: Bygg trigger-satser
    op_steg := 'bygg trigger-satser';
    RAISE NOTICE '[skapa_historik_qa] Steg 6: Bygger trigger-satser för QA-uppdatering';
    
    FOR i IN 1..antal_qa_kolumner LOOP
        trigger_satser := trigger_satser || format(
            E'        rad.%I = %s;\n',
            qa_kolumner[i], qa_uttryck[i]
        );
    END LOOP;
    RAISE NOTICE '[skapa_historik_qa]   » Trigger kommer sätta %s QA-värden', antal_qa_kolumner;
    
    -- Steg 7: Skapa triggerfunktion
    -- ÄNDRING: Använder session_user istället för current_user
    op_steg := 'skapa triggerfunktion';
    trigger_funktionsnamn := 'trg_fn_' || p_tabell_namn || '_qa';
    RAISE NOTICE '[skapa_historik_qa] Steg 7: Skapar triggerfunktion %s', trigger_funktionsnamn;
    
    EXECUTE format($TRIG$
        CREATE OR REPLACE FUNCTION %I.%I()
        RETURNS TRIGGER AS $$
        DECLARE
            rad %I.%I%%ROWTYPE;
        BEGIN
            IF TG_OP = 'UPDATE' THEN
                rad := NEW;
                
                -- Sätt QA-värden
%s                
                -- Kopiera gamla värdet till historik
                INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                SELECT 'U', NOW(), session_user, OLD.*;
                
                RETURN rad;
            ELSE -- DELETE
                rad := OLD;
                
                -- Sätt QA-värden även för DELETE (för konsistens)
%s                
                -- Kopiera till historik
                INSERT INTO %I.%I (h_typ, h_tidpunkt, h_av, %s)
                SELECT 'D', NOW(), session_user, rad.*;
                
                RETURN OLD;
            END IF;
        END;
        $$ LANGUAGE plpgsql;
    $TRIG$,
        p_schema_namn, trigger_funktionsnamn,
        p_schema_namn, p_tabell_namn,
        trigger_satser,
        p_schema_namn, p_tabell_namn || '_h', kolumn_lista,
        trigger_satser,
        p_schema_namn, p_tabell_namn || '_h', kolumn_lista
    );
    RAISE NOTICE '[skapa_historik_qa]   ✓ Triggerfunktion skapad';
    
    -- Steg 8: Skapa trigger
    op_steg := 'skapa trigger';
    RAISE NOTICE '[skapa_historik_qa] Steg 8: Skapar trigger på modertabell';
    
    EXECUTE format(
        'CREATE TRIGGER trg_%s_qa 
        BEFORE UPDATE OR DELETE ON %I.%I
        FOR EACH ROW EXECUTE FUNCTION %I.%I()',
        p_tabell_namn, p_schema_namn, p_tabell_namn,
        p_schema_namn, trigger_funktionsnamn
    );
    RAISE NOTICE '[skapa_historik_qa]   ✓ Trigger skapad: trg_%s_qa', p_tabell_namn;
    
    -- Steg 9: Dokumentera
    op_steg := 'dokumentera';
    RAISE NOTICE '[skapa_historik_qa] Steg 9: Lägger till dokumentation';
    
    EXECUTE format(
        'COMMENT ON TABLE %I.%I IS %L',
        p_schema_namn, p_tabell_namn || '_h',
        format('Historiktabell för %s.%s. Historikkolumner först: h_typ (U/D), h_tidpunkt, h_av. %s Skapad: %s',
            p_schema_namn, p_tabell_namn, 
            CASE WHEN har_geometri THEN 'Geometri: ' || geometriinfo.definition || '. ' ELSE '' END,
            NOW()::date)
    );
    
    -- Sammanfattning
    RAISE NOTICE '[skapa_historik_qa] Sammanfattning:';
    RAISE NOTICE '[skapa_historik_qa]   » Historiktabell:     %s.%s_h', p_schema_namn, p_tabell_namn;
    RAISE NOTICE '[skapa_historik_qa]   » Triggerfunktion:    %s', trigger_funktionsnamn;
    RAISE NOTICE '[skapa_historik_qa]   » QA-kolumner:        %s', array_to_string(qa_kolumner, ', ');
    RAISE NOTICE '[skapa_historik_qa]   » Geometri:           %s', 
        CASE WHEN har_geometri THEN geometriinfo.definition ELSE 'Ingen' END;
    RAISE NOTICE '[skapa_historik_qa]   » Totalt kolumner:    %s (3 h_ + %s original)', 
        3 + antal_original_kolumner, antal_original_kolumner;
    
    RAISE NOTICE '[skapa_historik_qa] === SLUT ===';
    RETURN true;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '[skapa_historik_qa] !!! FEL UPPSTOD !!!';
        RAISE NOTICE '[skapa_historik_qa] Senaste kontext:';
        RAISE NOTICE '[skapa_historik_qa]   - Schema: %', p_schema_namn;
        RAISE NOTICE '[skapa_historik_qa]   - Tabell: %', p_tabell_namn;
        RAISE NOTICE '[skapa_historik_qa]   - Operation: %', op_steg;
        RAISE NOTICE '[skapa_historik_qa]   - QA-kolumner: %', COALESCE(array_to_string(qa_kolumner, ', '), 'inga');
        RAISE NOTICE '[skapa_historik_qa] Tekniska feldetaljer:';
        RAISE NOTICE '[skapa_historik_qa]   - Felkod: %', SQLSTATE;
        RAISE NOTICE '[skapa_historik_qa]   - Felmeddelande: %', SQLERRM;
        RAISE;
END;
$BODY$;

ALTER FUNCTION public.skapa_historik_qa(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.skapa_historik_qa(text, text)
    IS 'Skapar historiktabell och QA-triggers för tabeller som har QA-kolumner med historik_qa=true.
Använder session_user för att fånga den faktiskt autentiserade användaren (inte SET ROLE-identitet).
Använder hamta_geometri_definition() för korrekt geometrihantering i historiktabeller, vilket 
säkerställer att geometrikolumner behåller sin specifika typ och SRID (t.ex. geometry(PolygonZ,3007))
istället för generisk geometry-typ. Detta förhindrar QA-trigger-krascher vid geometrikopiering.';
