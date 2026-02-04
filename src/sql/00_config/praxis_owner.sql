-- FUNCTION: public.praxis_owner()

/******************************************************************************
 * Returnerar namnet på ägarrollen för Praxis-objekt.
 * 
 * MANUELL INSTALLATION:
 * Ändra 'gis_admin' nedan till din ägarroll INNAN du kör detta skript.
 * Denna funktion måste installeras FÖRST, före alla andra Praxis-filer.
 *
 * INSTALLER:
 * Om du använder install_praxis.py ignoreras denna fil - installern
 * genererar funktionen dynamiskt baserat på OWNER_ROLE-konfigurationen.
 ******************************************************************************/

CREATE OR REPLACE FUNCTION public.praxis_owner()
    RETURNS text
    LANGUAGE 'sql'
    IMMUTABLE
AS $BODY$
    SELECT 'gis_admin'::text;  -- ← Ändra detta till din ägarroll
$BODY$;

ALTER FUNCTION public.praxis_owner() OWNER TO postgres;

COMMENT ON FUNCTION public.praxis_owner()
    IS 'Returnerar ägarrollen för Praxis-skapade roller. Används för att ge ADMIN OPTION så att ägarrollen kan hantera roller skapade av event triggers.';
