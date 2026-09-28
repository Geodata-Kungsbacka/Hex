-- FUNCTION: public.hex_kolumntyp(text, text, text)

-- DROP FUNCTION IF EXISTS public.hex_kolumntyp(text, text, text);

CREATE OR REPLACE FUNCTION public.hex_kolumntyp(
    p_schema_namn text,
    p_tabell_namn text,
    p_kolumn_namn text)
    RETURNS text
    LANGUAGE 'sql'
    STABLE
    PARALLEL SAFE
AS $BODY$
/******************************************************************************
 * Returnerar en kolumns datatyp exakt som den ska skrivas i CREATE TABLE eller
 * ALTER TABLE ... ADD COLUMN. NULL om kolumnen inte finns.
 *
 * VARFÖR FUNKTIONEN FINNS
 * Typen rekonstruerades tidigare för hand på tre ställen – i
 * hex_hamta_kolumnstandard, hex_skapa_historik_qa och hex_hantera_ny_kolumn –
 * med varsin CASE över information_schema.columns:
 *
 *     CASE WHEN data_type = 'USER-DEFINED' THEN udt_name
 *          WHEN data_type = 'character varying' THEN 'character varying(' || ...
 *          WHEN data_type = 'numeric' THEN 'numeric(' || ...
 *          ELSE data_type END
 *
 * Varje kopia täckte olika många specialfall och alla missade något:
 *   - udt_name tappar typmodifieraren (numeric(10,2) → numeric) och ger
 *     internnamnet för arrayer (text[] → _text).
 *   - data_type ger 'ARRAY' för varje arraytyp, vilket blir syntaxfel.
 *   - Domäner och enum:er föll igenom som oskrivbara namn utan schemaprefix.
 *
 * format_type() är PostgreSQL:s egen funktion för precis det här och täcker
 * samtliga fall, geometry(PolygonZ,3007) inkluderad. En kolumn utan
 * typmodifierare får sin bara typ tillbaka (geometry, text), vilket är den
 * korrekta återgivningen av hur kolumnen faktiskt är deklarerad.
 *
 * OMFATTNING
 * Funktionen returnerar BARA datatypen. DEFAULT, NOT NULL, COLLATE, IDENTITY
 * och GENERATED hör till andra delar av systemet:
 *   - DEFAULT/NOT NULL/CHECK/IDENTITY  → hex_spara_kolumnegenskaper och
 *                                        hex_aterskapa_kolumnegenskaper
 *   - GENERATED ALWAYS AS (...) STORED → hex_hamta_kolumnstandard, som är den
 *                                        enda plats där en beräknad kolumn ska
 *                                        återskapas som beräknad
 * Historiktabeller ska spegla en beräknad kolumn som VANLIG kolumn – annars
 * kan QA-triggerns INSERT (som listar alla kolumner explicit) inte skriva
 * värdet. Att funktionen utelämnar GENERATED är alltså rätt för alla
 * historikanrop, inte en förenkling.
 ******************************************************************************/
    SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema_namn
    AND c.relname = p_tabell_namn
    AND a.attname = p_kolumn_namn
    AND a.attnum > 0
    AND NOT a.attisdropped;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_kolumntyp(text, text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_kolumntyp(text, text, text)
    IS 'Returnerar en kolumns datatyp så som den ska skrivas i CREATE TABLE eller
ALTER TABLE ... ADD COLUMN, via format_type(). Typmodifierare bevaras
(numeric(10,2), character varying(50), geometry(PolygonZ,3007)) och arrayer får
sin skrivbara form (text[], inte _text). Returnerar bara datatypen – DEFAULT,
NOT NULL, IDENTITY och GENERATED hanteras av hex_spara_kolumnegenskaper,
hex_aterskapa_kolumnegenskaper respektive hex_hamta_kolumnstandard. NULL om
kolumnen inte finns.';
