USE master
GO

create or ALTER PROCEDURE dbo.sp_exportTableConfigToJSON
(
    @fullTableName VARCHAR(128),
    @exportPath VARCHAR(260) = 'C:\temp',
    @bWriteableColumnsOnly BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dbName SYSNAME = PARSENAME(@fullTableName, 3),
            @schName SYSNAME = PARSENAME(@fullTableName, 2),
            @tblName SYSNAME = PARSENAME(@fullTableName, 1);

    IF @dbName IS NULL
        SET @dbName = DB_NAME();

    IF @schName IS NULL OR @schName = ''
        SET @schName = 'dbo';

    PRINT 'Target table: [' + @dbName + '].[' + @schName + '].[' + @tblName + ']';

    DECLARE @colFilter NVARCHAR(100) = N'';

    IF @bWriteableColumnsOnly = 1
        SET @colFilter = N' AND c.is_computed = 0 AND c.is_identity = 0 ';

    DECLARE @dynSql NVARCHAR(MAX) = N'
DECLARE @temp NVARCHAR(MAX);

WITH targetObj AS (
    SELECT object_id
    FROM [' + @dbName + N'].sys.objects o
    JOIN [' + @dbName + N'].sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.name = ''' + @tblName + N'''
      AND s.name = ''' + @schName + N'''
),
cols AS (
    SELECT
        c.column_id AS ordinal,
        c.name AS columnName,
        t.name AS sqlType,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        c.is_identity,
        c.is_computed,
        cc.definition AS computedDefinition,
        cc.is_persisted,
        dc.definition AS defaultValue,
        c.collation_name,
        c.is_rowguidcol,
        ic.seed_value,
        ic.increment_value
    FROM [' + @dbName + N'].sys.columns c
    JOIN [' + @dbName + N'].sys.types t
      ON c.user_type_id = t.user_type_id
    LEFT JOIN [' + @dbName + N'].sys.computed_columns cc
      ON cc.object_id = c.object_id AND cc.column_id = c.column_id
    LEFT JOIN [' + @dbName + N'].sys.default_constraints dc
      ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
    LEFT JOIN [' + @dbName + N'].sys.identity_columns ic
      ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE c.object_id = (SELECT object_id FROM targetObj) ' + @colFilter + N'
),
idx AS (
    SELECT
        i.name AS indexName,
        i.is_unique,
        i.is_primary_key,
        i.type_desc,
        ic.index_column_id,
        col.name AS columnName
    FROM [' + @dbName + N'].sys.indexes i
    JOIN [' + @dbName + N'].sys.index_columns ic
      ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    JOIN [' + @dbName + N'].sys.columns col
      ON col.object_id = ic.object_id AND col.column_id = ic.column_id
    WHERE i.object_id = (SELECT object_id FROM targetObj)
      AND i.is_hypothetical = 0
      AND i.index_id > 0
),
constr AS (
    SELECT
        obj.name AS constraintName,
        obj.type_desc,
        cc.definition AS definition,
        fk.referenced_object_id,
        NULL AS value
    FROM [' + @dbName + N'].sys.objects obj
    LEFT JOIN [' + @dbName + N'].sys.check_constraints cc
      ON obj.object_id = cc.object_id
    LEFT JOIN [' + @dbName + N'].sys.foreign_keys fk
      ON obj.object_id = fk.object_id
    WHERE obj.parent_object_id = (SELECT object_id FROM targetObj)
    UNION ALL
    SELECT
        dc.name AS constraintName,
        ''DEFAULT'' AS type_desc,
        dc.definition AS definition,
        NULL AS referenced_object_id,
        dc.definition AS value
    FROM [' + @dbName + N'].sys.default_constraints dc
    WHERE dc.parent_object_id = (SELECT object_id FROM targetObj)
)
SELECT @temp = (
    SELECT
        ''' + @dbName + N'_' + @schName + N'_' + @tblName + N''' AS tableName,
        (
            SELECT ordinal, columnName, sqlType, max_length, precision, scale, is_nullable,
                   is_identity, is_computed, computedDefinition, is_persisted, defaultValue,
                   collation_name, is_rowguidcol, seed_value, increment_value
            FROM cols
            FOR JSON PATH
        ) AS columns,
        (
            SELECT indexName, is_unique, is_primary_key, type_desc,
                   (
                       SELECT columnName
                       FROM idx i2
                       WHERE i2.indexName = idx.indexName
                       ORDER BY i2.index_column_id
                       FOR JSON PATH
                   ) AS indexColumns
            FROM idx
            GROUP BY indexName, is_unique, is_primary_key, type_desc
            FOR JSON PATH
        ) AS indexes,
        (
            SELECT constraintName, type_desc, definition, referenced_object_id, value
            FROM constr
            FOR JSON PATH
        ) AS constraints
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);

SELECT @temp AS jsonOutput;
';

    PRINT 'Dynamic SQL (preview): ' + LEFT(@dynSql, 4000);

    IF OBJECT_ID('tempdb..#exportjson') IS NOT NULL
        DROP TABLE #exportjson;

    CREATE TABLE #exportjson (jsonOutput NVARCHAR(MAX));

    INSERT #exportjson (jsonOutput)
    EXEC sp_executesql @dynSql;

    DECLARE @json NVARCHAR(MAX) = (SELECT TOP 1 jsonOutput FROM #exportjson);

    PRINT 'JSON preview: ' + LEFT(ISNULL(@json, '(null)'), 2000);

    IF @json IS NULL OR LEN(@json) = 0
    BEGIN
        PRINT 'No JSON output generated. Check if table or filters returned results.';
        RETURN;
    END;

    -- Check if OLE Automation is enabled before attempting to write to disk
    DECLARE @oleEnabled INT = 0;
    SELECT @oleEnabled = CAST(value_in_use AS INT)
    FROM sys.configurations
    WHERE name = 'Ole Automation Procedures';

    IF @oleEnabled = 1
    BEGIN
        -- OLE Automation is enabled - write to disk
        DECLARE @currentDate VARCHAR(8) = CONVERT(VARCHAR(8), GETDATE(), 112);
        DECLARE @currentTime VARCHAR(6) = REPLACE(CONVERT(VARCHAR(8), GETDATE(), 108), ':', '');
        DECLARE @jsonFilePath NVARCHAR(500) = @exportPath + N'\' + @dbName + N'_' + @schName + N'_' + @tblName + N'_' + @currentDate + N'_' + @currentTime + N'.json';

        DECLARE @fso INT, @fileHandle INT, @hr INT;

        EXEC @hr = sp_OACreate 'Scripting.FileSystemObject', @fso OUT;

        IF @hr = 0
        BEGIN
            EXEC @hr = sp_OAMethod @fso, 'CreateTextFile', @fileHandle OUT, @jsonFilePath, 2, 1;

            IF @hr = 0
            BEGIN
                EXEC @hr = sp_OAMethod @fileHandle, 'Write', NULL, @json;
                EXEC sp_OAMethod @fileHandle, 'Close';
                EXEC sp_OADestroy @fileHandle;
                PRINT 'File saved to: ' + @jsonFilePath;
            END
            ELSE
            BEGIN
                PRINT 'Failed to create file (HRESULT=' + CAST(@hr AS VARCHAR(10)) + ')';
            END

            EXEC sp_OADestroy @fso;
        END
        ELSE
        BEGIN
            PRINT 'Failed to create FileSystemObject (HRESULT=' + CAST(@hr AS VARCHAR(10)) + ')';
        END
    END
    ELSE
    BEGIN
        PRINT 'OLE Automation disabled - skipping file write';
    END

    -- Always return the JSON regardless of file write success
    SELECT @json AS jsonOutput;
END;
GO
