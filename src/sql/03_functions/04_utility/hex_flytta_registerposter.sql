CREATE OR REPLACE FUNCTION public.hex_flytta_registerposter(
    p_schema_namn text,
    p_gammalt_namn text,
    p_nytt_namn text
)
    RETURNS integer
    LANGUAGE 'plpgsql'
AS $BODY$
/******************************************************************************
 * Flyttar en tabells rader i de namnnycklade drifttillståndstabellerna efter
 * ALTER TABLE ... RENAME TO.
 *
 * hex_dummy_geometrier, hex_afvaktande_geometri och hex_avvikande_srid
 * nycklas på (schema_namn, tabell_namn), inte på OID. Utan flytten pekar
 * raderna på ett namn som inte längre finns: hex_ta_bort_dummy_rad() hittar
 * inte dummy-raden (den blir kvar i tabellen), och FME-tvåsteget slutförs
 * aldrig för en afvaktande tabell som döpts om.
 *
 * Raderna flyttas med DELETE ... RETURNING följt av INSERT, så att
 * registrerad och registrerad_av står kvar. PUBLIC har INSERT och DELETE på
 * tabellerna (event-triggrarna körs som den som gör DDL:en) men inte UPDATE
 * på alla, och funktionen behöver därför inga utökade rättigheter.
 *
 * Rader som redan står på det nya namnet är kvarlevor från en tidigare
 * tabell med samma namn och ersätts.
 *
 * Anropas av hex_hantera_ny_kolumn() vid RENAME TO. Gör ingenting om det
 * gamla namnet fortfarande är en relation i schemat – då är det inte den
 * här tabellens gamla namn.
 *
 * RETURVÄRDE
 * Antal flyttade rader.
 ******************************************************************************/
DECLARE
    antal  integer := 0;
    n      integer;
BEGIN
    IF p_gammalt_namn IS NULL OR p_nytt_namn IS NULL
       OR p_gammalt_namn = p_nytt_namn
       OR to_regclass(format('%I.%I', p_schema_namn, p_gammalt_namn)) IS NOT NULL
    THEN
        RETURN 0;
    END IF;

    -- hex_dummy_geometrier
    IF EXISTS (SELECT 1 FROM public.hex_dummy_geometrier d
               WHERE d.schema_namn = p_schema_namn AND d.tabell_namn = p_gammalt_namn) THEN
        DELETE FROM public.hex_dummy_geometrier d
        WHERE d.schema_namn = p_schema_namn AND d.tabell_namn = p_nytt_namn;

        WITH flyttade AS (
            DELETE FROM public.hex_dummy_geometrier d
            WHERE d.schema_namn = p_schema_namn AND d.tabell_namn = p_gammalt_namn
            RETURNING d.gid, d.registrerad
        )
        INSERT INTO public.hex_dummy_geometrier (schema_namn, tabell_namn, gid, registrerad)
        SELECT p_schema_namn, p_nytt_namn, f.gid, f.registrerad FROM flyttade f;
        GET DIAGNOSTICS n = ROW_COUNT;
        antal := antal + n;
    END IF;

    -- hex_afvaktande_geometri
    IF EXISTS (SELECT 1 FROM public.hex_afvaktande_geometri a
               WHERE a.schema_namn = p_schema_namn AND a.tabell_namn = p_gammalt_namn) THEN
        DELETE FROM public.hex_afvaktande_geometri a
        WHERE a.schema_namn = p_schema_namn AND a.tabell_namn = p_nytt_namn;

        WITH flyttade AS (
            DELETE FROM public.hex_afvaktande_geometri a
            WHERE a.schema_namn = p_schema_namn AND a.tabell_namn = p_gammalt_namn
            RETURNING a.registrerad, a.registrerad_av
        )
        INSERT INTO public.hex_afvaktande_geometri (schema_namn, tabell_namn, registrerad, registrerad_av)
        SELECT p_schema_namn, p_nytt_namn, f.registrerad, f.registrerad_av FROM flyttade f;
        GET DIAGNOSTICS n = ROW_COUNT;
        antal := antal + n;
    END IF;

    -- hex_avvikande_srid
    IF EXISTS (SELECT 1 FROM public.hex_avvikande_srid s
               WHERE s.schema_namn = p_schema_namn AND s.tabell_namn = p_gammalt_namn) THEN
        DELETE FROM public.hex_avvikande_srid s
        WHERE s.schema_namn = p_schema_namn AND s.tabell_namn = p_nytt_namn;

        WITH flyttade AS (
            DELETE FROM public.hex_avvikande_srid s
            WHERE s.schema_namn = p_schema_namn AND s.tabell_namn = p_gammalt_namn
            RETURNING s.srid, s.registrerad, s.registrerad_av
        )
        INSERT INTO public.hex_avvikande_srid (schema_namn, tabell_namn, srid, registrerad, registrerad_av)
        SELECT p_schema_namn, p_nytt_namn, f.srid, f.registrerad, f.registrerad_av FROM flyttade f;
        GET DIAGNOSTICS n = ROW_COUNT;
        antal := antal + n;
    END IF;

    IF antal > 0 THEN
        RAISE NOTICE '[hex_flytta_registerposter] ✓ % registerrad(er) flyttade: %.% → %.%',
            antal, p_schema_namn, p_gammalt_namn, p_schema_namn, p_nytt_namn;
    END IF;

    RETURN antal;
END;
$BODY$;

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER FUNCTION public.hex_flytta_registerposter(text, text, text) OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

COMMENT ON FUNCTION public.hex_flytta_registerposter(text, text, text)
    IS 'Flyttar en omdöpt tabells rader i hex_dummy_geometrier, hex_afvaktande_geometri
och hex_avvikande_srid från det gamla till det nya namnet. Anropas av
hex_hantera_ny_kolumn() vid ALTER TABLE ... RENAME TO.';
