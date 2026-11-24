-- ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment, Feb 2025). Not built or tested by this package; see ../NOTES.md.
-- Original name: resources/database/sprocs/create_table_from_json.sql (unchanged apart from this header and ASCII list bullets).
-- Input:  JSON text produced by source-mssql/sproc_exportTableConfigToJson.sql
--         { tableName, columns[], indexes[], constraints[] }
-- Output: table "tableName" in the current schema, dropped and recreated, with indexes and primary key.
-- Usage:  SELECT create_table_from_json($$ {...} $$);

------------------------------------------------------------
-- Main Script: Drop existing functions and recreate them
------------------------------------------------------------

-- Drop functions if they exist
DROP FUNCTION IF EXISTS transform_default_value(text, text);
DROP FUNCTION IF EXISTS map_sqlserver_type(text, int, int, int);
DROP FUNCTION IF EXISTS create_table_from_json(text);

------------------------------------------------------------
-- 1. Function: transform_default_value
--
-- Transforms a SQL Server default expression into a PostgreSQL default.
-- It removes extra outer parentheses, converts getdate() to now(), and for
-- bit columns converts 0/1 to false/true.
------------------------------------------------------------
CREATE OR REPLACE FUNCTION transform_default_value(def text, orig_type text)
RETURNS text
LANGUAGE plpgsql
AS
$$
DECLARE
    res text := def;
BEGIN
    -- Remove any outer matching parentheses.
    WHILE left(res, 1) = '(' AND right(res, 1) = ')' LOOP
         res := substr(res, 2, char_length(res) - 2);
    END LOOP;
    -- Replace getdate() with now()
    IF lower(res) = 'getdate()' OR lower(res) = 'getdate' THEN
         res := 'now()';
    END IF;
    -- For SQL Server 'bit' columns (mapped to boolean) convert 0/1 to false/true.
    IF lower(orig_type) = 'bit' THEN
         IF res = '0' THEN
             res := 'false';
         ELSIF res = '1' THEN
             res := 'true';
         END IF;
    END IF;
    RETURN res;
END;
$$;

------------------------------------------------------------
-- 2. Function: map_sqlserver_type
--
-- Maps a SQL Server data type (with metadata) to a PostgreSQL type.
------------------------------------------------------------
CREATE OR REPLACE FUNCTION map_sqlserver_type(
    _sqltype    text,
    _maxlen     int,
    _precision  int,
    _scale      int
)
RETURNS text
LANGUAGE plpgsql
AS
$$
BEGIN
    CASE
        WHEN _sqltype = 'int' THEN
            RETURN 'integer';
        WHEN _sqltype = 'tinyint' THEN
            RETURN 'smallint';  -- PostgreSQL does not have tinyint
        WHEN _sqltype = 'bit' THEN
            RETURN 'boolean';
        WHEN _sqltype = 'float' AND _precision = 53 THEN
            RETURN 'double precision';
        WHEN _sqltype = 'money' THEN
            RETURN 'numeric(19,4)';
        WHEN _sqltype = 'smallmoney' THEN
            RETURN 'numeric(10,4)';
        WHEN _sqltype = 'datetime2' THEN
            RETURN 'timestamp';
        WHEN _sqltype = 'date' THEN
            RETURN 'date';
        WHEN _sqltype IN ('varchar', 'nvarchar') THEN
            -- For very large lengths you might choose TEXT.
            RETURN format('varchar(%s)', _maxlen);
        ELSE
            RETURN 'text';
    END CASE;
END;
$$;

------------------------------------------------------------
-- 3. Function: create_table_from_json
--
-- Reads a JSON document defining a table (with columns, indexes,
-- and constraints), then:
--   - Drops the target table if it exists.
--   - Builds a CREATE TABLE statement using the provided column data:
--       - For computed columns, creates a GENERATED column.
--         After replacing square brackets with double quotes, it loops
--         over all column definitions from the JSON and replaces any
--         lower-case (flattened) references with the properly quoted name.
--       - For identity columns, uses GENERATED ALWAYS AS IDENTITY.
--       - For regular columns, adds a DEFAULT clause (using the transformed
--         default) and a NOT NULL clause as needed.
--   - Executes the CREATE TABLE.
--   - Processes any provided index definitions.
------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_table_from_json(json_text text)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    js              jsonb := json_text::jsonb;
    v_table_name    text;
    v_sql           text;
    v_columns       text := '';
    col_array_length int;  -- total number of columns in JSON
    rec             record;  -- for iterating over columns in ordinal order
    col             jsonb;
    col_name        text;
    col_pg_type     text;
    default_clause  text;
    identity_clause text;
    computed_clause text;
    has_id_column   boolean := false;
    j               int;  -- inner loop counter for computed clause fix
    tmp             jsonb;
    origName        text;
    lowerName       text;
BEGIN
    -- Get table name
    v_table_name := js ->> 'tableName';
    IF v_table_name IS NULL THEN
        RAISE EXCEPTION 'JSON does not contain a "tableName" field.';
    END IF;

    -- Drop the table if it exists
    v_sql := format('DROP TABLE IF EXISTS %I CASCADE', v_table_name);
    RAISE NOTICE 'Dropping table if exists: %', v_sql;
    EXECUTE v_sql;

    -- Determine total column count (for computed column reference fixes)
    col_array_length := jsonb_array_length(js->'columns');
    IF col_array_length = 0 THEN
        RAISE EXCEPTION 'No columns provided for table "%".', v_table_name;
    END IF;

    ----------------------------------------------------------------
    -- Build column definitions in the order specified by "ordinal"
    ----------------------------------------------------------------
    FOR rec IN
        SELECT value AS col
        FROM jsonb_array_elements(js->'columns')
        ORDER BY (value->>'ordinal')::int
    LOOP
        col := rec.col;
        col_name := col->>'columnName';

        col_pg_type := map_sqlserver_type(
                         col->>'sqlType',
                         (col->>'max_length')::int,
                         (col->>'precision')::int,
                         (col->>'scale')::int
                       );

        -- Begin column definition
        v_columns := v_columns || format('%I ', col_name);

        IF col->>'is_computed' = 'true' THEN
            -- Computed columns: create a generated column
            computed_clause := col->>'computedDefinition';
            IF computed_clause IS NOT NULL THEN
                -- Replace square brackets with double quotes
                computed_clause := replace(computed_clause, '[', '"');
                computed_clause := replace(computed_clause, ']', '"');
                -- Fix computed column references by matching lower-case references
                FOR j IN 0..(col_array_length - 1) LOOP
                    tmp := (js->'columns')->j;
                    origName := tmp->>'columnName';
                    lowerName := lower(origName);
                    computed_clause := regexp_replace(
                                          computed_clause,
                                          '"' || lowerName || '"',
                                          format('%I', origName),
                                          'g'
                                      );
                END LOOP;
                v_columns := v_columns || col_pg_type ||
                             ' GENERATED ALWAYS AS (' || computed_clause || ') STORED, ';
            ELSE
                v_columns := v_columns || col_pg_type || ', ';
            END IF;

        ELSIF col->>'is_identity' = 'true' THEN
            -- Identity columns: use GENERATED ALWAYS AS IDENTITY
            identity_clause := 'GENERATED ALWAYS AS IDENTITY';
            IF col ? 'seed_value' AND col ? 'increment_value' THEN
                identity_clause := identity_clause ||
                    format(' (START WITH %s INCREMENT BY %s)', col->>'seed_value', col->>'increment_value');
            END IF;
            v_columns := v_columns || col_pg_type || ' ' || identity_clause;
            IF col->>'is_nullable' = 'false' THEN
                v_columns := v_columns || ' NOT NULL';
            END IF;
            v_columns := v_columns || ', ';

            IF col_name = 'id' THEN
                has_id_column := true;
            END IF;

        ELSE
            -- Regular column
            v_columns := v_columns || col_pg_type;

            -- Add DEFAULT clause if provided
            IF col ? 'defaultValue'
               AND col->>'defaultValue' IS NOT NULL
               AND col->>'defaultValue' <> '' THEN
                default_clause := transform_default_value(col->>'defaultValue', col->>'sqlType');
                v_columns := v_columns || ' DEFAULT ' || default_clause;
            END IF;

            -- Add NOT NULL if specified
            IF col->>'is_nullable' = 'false' THEN
                v_columns := v_columns || ' NOT NULL';
            END IF;
            v_columns := v_columns || ', ';

            IF col_name = 'id' THEN
                has_id_column := true;
            END IF;
        END IF;
    END LOOP;

    -- Remove trailing comma/space
    v_columns := rtrim(v_columns, ', ');

    ----------------------------------------------------------------
    -- Build and execute the CREATE TABLE statement
    ----------------------------------------------------------------
    v_sql := format('CREATE TABLE %I (%s)', v_table_name, v_columns);
    RAISE NOTICE 'Creating table: %', v_sql;
    EXECUTE v_sql;

    ------------------------------------------------------------
    -- Process index definitions (if provided)
    ------------------------------------------------------------
    IF js ? 'indexes' THEN
        DECLARE
            idx_arr       jsonb := js->'indexes';
            idx_idx       int;
            index_obj     jsonb;
            index_name    text;
            is_unique     boolean;
            is_primary_key boolean;
            index_columns text;
            col_arr       jsonb;
            col_item      jsonb;
            col_idx       int;
            col_count_idx int;
            pk_defined    boolean := false;
        BEGIN
            FOR idx_idx IN 0 .. jsonb_array_length(idx_arr) - 1 LOOP
                index_obj := idx_arr->idx_idx;
                index_name := index_obj->>'indexName';
                is_unique := (index_obj->>'is_unique')::boolean;
                is_primary_key := (index_obj->>'is_primary_key')::boolean;
                col_arr := index_obj->'indexColumns';
                col_count_idx := jsonb_array_length(col_arr);
                index_columns := '';

                FOR col_idx IN 0 .. col_count_idx - 1 LOOP
                    col_item := col_arr->col_idx;
                    index_columns := index_columns || format('%I, ', col_item->>'columnName');
                END LOOP;
                index_columns := rtrim(index_columns, ', ');

                IF is_primary_key THEN
                    -- Create primary key constraint (only once)
                    IF NOT pk_defined THEN
                        v_sql := format('ALTER TABLE %I ADD CONSTRAINT %I_pkey PRIMARY KEY (%s)',
                                        v_table_name, v_table_name, index_columns);
                        RAISE NOTICE 'Adding primary key: %', v_sql;
                        EXECUTE v_sql;
                        pk_defined := true;
                    END IF;
                ELSE
                    -- Create a regular index
                    IF is_unique THEN
                        v_sql := format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I (%s)',
                                        index_name, v_table_name, index_columns);
                    ELSE
                        v_sql := format('CREATE INDEX IF NOT EXISTS %I ON %I (%s)',
                                        index_name, v_table_name, index_columns);
                    END IF;
                    RAISE NOTICE 'Creating index: %', v_sql;
                    EXECUTE v_sql;
                END IF;
            END LOOP;
        END;
    END IF;

    ------------------------------------------------------------
    -- If no primary key was defined and an "id" column was detected,
    -- add a primary key on id.
    ------------------------------------------------------------
    IF NOT (SELECT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = v_table_name::regclass
              AND contype = 'p'
         ))
       AND has_id_column
    THEN
        v_sql := format('ALTER TABLE %I ADD CONSTRAINT %I_pkey PRIMARY KEY (id)',
                        v_table_name, v_table_name);
        RAISE NOTICE 'Adding primary key constraint on id: %', v_sql;
        EXECUTE v_sql;
    END IF;

    RETURN;
END;
$$;
