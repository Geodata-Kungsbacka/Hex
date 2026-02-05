CREATE TABLE IF NOT EXISTS public.standardiserade_roller (
    gid integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    rollnamn text NOT NULL,              
    rolltyp text NOT NULL CHECK (rolltyp IN ('read', 'write')),
    schema_uttryck text NOT NULL DEFAULT 'IS NOT NULL',
    global_roll boolean DEFAULT false,
    ta_bort_med_schema boolean DEFAULT true,
    login_roller text[] DEFAULT '{}',
    beskrivning text,
    
    CONSTRAINT standardiserade_roller_pkey PRIMARY KEY (gid),
    -- Enklare constraint utan subquery - använder regex på array-to-string
    CONSTRAINT valid_login_roller_format 
    CHECK (
        array_to_string(login_roller, '|') ~ '^(_[^|]*|[^|]*_)(\|(_[^|]*|[^|]*_))*$|^$'
    )
);

ALTER TABLE public.standardiserade_roller
    OWNER TO postgres;

COMMENT ON TABLE public.standardiserade_roller
    IS 'Definierar vilka roller som ska skapas automatiskt för nya scheman. 
    Stöder både schemaspecifika och globala roller med valfria LOGIN-roller per applikation.';

COMMENT ON COLUMN public.standardiserade_roller.login_roller
    IS 'Array med suffix/prefix för LOGIN-roller. Värden som börjar med _ blir suffix, 
    värden som slutar med _ blir prefix. Ex: ["_geoserver", "_qgis"] skapar 
    r_schema_geoserver och r_schema_qgis som LOGIN-roller.';

-- Globala roller för sk0 och sk1
INSERT INTO standardiserade_roller (
    rollnamn, rolltyp, schema_uttryck, global_roll, ta_bort_med_schema, login_roller, beskrivning
) VALUES 
    ('r_sk0_global', 'read', 'LIKE ''sk0_%''', true, false, ARRAY['_geoserver', '_cesium', '_qgis'], 'Global läsroll för sk0'),
    ('r_sk1_global', 'read', 'LIKE ''sk1_%''', true, false, ARRAY['_geoserver', '_cesium', '_qgis'], 'Global läsroll för sk1');

-- Schemaspecifika roller
INSERT INTO standardiserade_roller (rollnamn, rolltyp, schema_uttryck, login_roller, beskrivning) VALUES 
    ('r_{schema}', 'read', 'LIKE ''sk2_%''', ARRAY['_geoserver', '_cesium','_qgis'], 'Schemaspecifik läsroll'),
    ('w_{schema}', 'write', 'IS NOT NULL', ARRAY['_geoserver', '_cesium','_qgis'], 'Schemaspecifik skrivroll');
