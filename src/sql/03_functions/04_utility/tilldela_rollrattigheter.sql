CREATE OR REPLACE FUNCTION public.tilldela_rollrattigheter(
    p_schema_namn text,
    p_rollnamn text,
    p_rolltyp text
)
RETURNS void
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$

/******************************************************************************
 * Tilldelar rättigheter till en roll baserat på rolltyp.
 * 
 * PARAMETRAR:
 * - p_schema_namn: Namnet på schemat som rollen ska få rättigheter på
 * - p_rollnamn: Namnet på rollen som ska få rättigheter
 * - p_rolltyp: 'read' (SELECT) eller 'write' (SELECT, INSERT, UPDATE, DELETE)
 *
 * ANVÄNDNING:
 * Anropas automatiskt av hantera_standardiserade_roller() när nya roller skapas.
 * Tilldelar både rättigheter på befintliga objekt och framtida objekt (DEFAULT PRIVILEGES).
 ******************************************************************************/
BEGIN
    RAISE NOTICE '[tilldela_rollrattigheter] Tilldelar % rättigheter till % på schema %', 
        p_rolltyp, p_rollnamn, p_schema_namn;
    
    -- USAGE på schema (behövs för båda typer)
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', p_schema_namn, p_rollnamn);
    RAISE NOTICE '[tilldela_rollrattigheter] USAGE beviljat på schema %', p_schema_namn;
    
    IF p_rolltyp = 'read' THEN
        -- Endast läsrättigheter på tabeller och vyer
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', p_schema_namn, p_rollnamn);
        -- DEFAULT PRIVILEGES för postgres (kör denna funktion via SECURITY DEFINER)
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
                      p_schema_namn, p_rollnamn);
        -- DEFAULT PRIVILEGES för ägarrollen (skapar tabeller via FME, QGIS, etc.)
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
                      system_owner(), p_schema_namn, p_rollnamn);
        RAISE NOTICE '[tilldela_rollrattigheter] SELECT-rättigheter beviljade (inkl. DEFAULT PRIVILEGES för %)', system_owner();

    ELSIF p_rolltyp = 'write' THEN
        -- Skrivrättigheter: SELECT, INSERT, UPDATE, DELETE
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I',
                      p_schema_namn, p_rollnamn);
        -- DEFAULT PRIVILEGES för postgres
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
                      p_schema_namn, p_rollnamn);
        -- DEFAULT PRIVILEGES för ägarrollen
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
                      system_owner(), p_schema_namn, p_rollnamn);
        RAISE NOTICE '[tilldela_rollrattigheter] Skrivrättigheter beviljade (inkl. DEFAULT PRIVILEGES för %)', system_owner();
    END IF;
    
    RAISE NOTICE '[tilldela_rollrattigheter] Rättighetstilldelning slutförd för %', p_rollnamn;
END;
$BODY$;

ALTER FUNCTION public.tilldela_rollrattigheter(text, text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION public.tilldela_rollrattigheter(text, text, text)
    IS 'Tilldelar rättigheter till roller baserat på rolltyp. Hanterar både read (SELECT)
    och write (SELECT, INSERT, UPDATE, DELETE) med DEFAULT PRIVILEGES för framtida objekt.
    Sätter DEFAULT PRIVILEGES både för postgres och system_owner() (ägarrollen) så att
    tabeller skapade av t.ex. FME automatiskt får korrekta rättigheter.';
