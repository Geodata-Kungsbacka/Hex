-- TABELL: public.hex_paus
--
-- Bokföring för pausläget. Tabellen håller som mest en rad: finns raden är Hex
-- pausat, saknas den är Hex igång.
--
-- Tabellen är BOKFÖRING, inte mekanism. Det som faktiskt stänger av Hex är
-- evtenabled i pg_event_trigger och tgenabled i pg_trigger. Kolumnen
-- tidigare_lage är kvittot på hur det såg ut före pausen, så att
-- hex_ateruppta() kan lägga tillbaka exakt det läget i stället för att gissa
-- att allt var påslaget. En event-trigger som en DBA medvetet stängt av innan
-- pausen ska vara avstängd även efteråt.
--
-- Skrivs av:  hex_pausa()
-- Raderas av: hex_ateruppta()
-- Läses av:   hex_pausstatus(), hex_underhall(), install_hex.py

CREATE TABLE IF NOT EXISTS public.hex_paus (
    enkelrad      boolean     PRIMARY KEY DEFAULT true,
    pausad_sedan  timestamptz NOT NULL DEFAULT now(),
    pausad_av     text        NOT NULL DEFAULT session_user,
    anledning     text,
    pausad_till   timestamptz,
    tidigare_lage jsonb       NOT NULL,

    -- Spärren som gör tabellen till en enradstabell. Utan den kan två
    -- överlappande pauser lägga in var sin rad, och hex_ateruppta() vet då
    -- inte vilket "tidigare läge" som är det sanna.
    CONSTRAINT hex_paus_enkelrad CHECK (enkelrad)
);

-- Ägaren sätts via hex_systemagare() i stället för ett hårdkodat rollnamn,
-- så att manuell installation ger samma ägarskap som install_hex.py.
DO $$
BEGIN
    EXECUTE format(
        'ALTER TABLE public.hex_paus OWNER TO %I',
        public.hex_systemagare()
    );
END;
$$;

-- Läsbar för alla: hex_pausstatus() och felsökning ska fungera utan
-- superanvändare. Skrivning sker enbart genom hex_pausa()/hex_ateruppta(),
-- som kräver superanvändare eftersom ALTER EVENT TRIGGER gör det.
REVOKE ALL ON public.hex_paus FROM PUBLIC;
GRANT SELECT ON public.hex_paus TO PUBLIC;

COMMENT ON TABLE public.hex_paus IS
    'Bokföring för pausläget – som mest en rad. Finns raden är Hex pausat.
     Själva avstängningen sitter i pg_event_trigger.evtenabled och
     pg_trigger.tgenabled; den här tabellen berättar vem som pausade, varför,
     och vilket läge hex_ateruppta() ska lägga tillbaka.';

COMMENT ON COLUMN public.hex_paus.enkelrad IS
    'Konstant true. Primärnyckel + CHECK-spärr som håller tabellen vid en rad.';
COMMENT ON COLUMN public.hex_paus.pausad_sedan IS
    'När pausen började.';
COMMENT ON COLUMN public.hex_paus.pausad_av IS
    'session_user vid pausen – den faktiskt inloggade användaren, inte en
     SET ROLE-identitet.';
COMMENT ON COLUMN public.hex_paus.anledning IS
    'Fritext från operatören, t.ex. "pg_restore av prod till test".';
COMMENT ON COLUMN public.hex_paus.pausad_till IS
    'Tidpunkt då pausen senast borde ha hävts. Enbart en varningsgräns –
     ingenting återupptas automatiskt. hex_pausstatus() flaggar överskriden
     gräns så att en glömd paus syns i en övervakningsfråga.';
COMMENT ON COLUMN public.hex_paus.tidigare_lage IS
    'JSON med lägena före pausen:
       {"event_triggers": [{"namn": ..., "lage": "O"}, ...],
        "radtriggers":    [{"schema": ..., "tabell": ..., "namn": ..., "lage": "O"}, ...]}
     Lägeskoderna är pg_event_trigger.evtenabled respektive pg_trigger.tgenabled:
     O = påslagen, D = avstängd, R = replica, A = always.';
