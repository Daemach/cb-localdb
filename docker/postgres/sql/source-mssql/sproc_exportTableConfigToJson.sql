-- ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment). Not built or tested by this package; see ../../NOTES.md.
-- Runs on the central SQL Server (the data source), not in the container.
-- Original name: resources/database/sprocs/sproc_exportTableConfigToJson.sql, last edited 2025-03-31
-- (an earlier copy, dated 2025-02-14, was named sp_exportTableConfigToJSON and lived in master).
-- Only change: "alter procedure" is now "create or alter procedure" so the file runs on a fresh server.
-- Input:  @fullTableName  [db.][schema.]table
--         @exportPath     folder on the SQL Server host; '' returns the JSON as a result set only
--         @bWriteableColumnsOnly  1 = leave out computed and identity columns
-- Output: one row, column jsonOutput; with @exportPath also <db>_<schema>_<table>_YYYYMMDD_HHMMSS.json (UTF-16LE)
-- Needs:  Ole Automation Procedures enabled when @exportPath is used.

set ansi_Nulls on;
go

set quoted_Identifier on;
go

create or alter procedure dbo.sproc_exportTableConfigToJSON
(
  @fullTableName varchar(128), @exportPath varchar(260) = '', @bWriteableColumnsOnly bit = 0
)
as
begin
  set noCount on;


  declare @dbName sysname = parseName( @fullTableName, 3 ), @schName sysname = parseName( @fullTableName, 2 ), @tblName sysname = parseName( @fullTableName, 1 );

  if @dbName is null
    set @dbName = db_Name();

  if @schName is null
  or @schName = ''
    set @schName = 'dbo';

  print 'Target table: [' + @dbName + '].[' + @schName + '].[' + @tblName + ']';


  declare @colFilter nVarchar(100) = N'';

  if @bWriteableColumnsOnly = 1
    set @colFilter = N' AND c.is_computed = 0 AND c.is_identity = 0 ';


  declare @dynSql nVarchar(max)
    = N'
DECLARE @temp NVARCHAR(MAX);

WITH targetObj AS (
  SELECT object_id
  FROM [' + @dbName + N'].sys.objects o
  JOIN [' + @dbName + N'].sys.schemas s ON o.schema_id = s.schema_id
  WHERE o.name = ''' + @tblName + N'''
    AND s.name = ''' + @schName
      + N'''
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
  WHERE c.object_id = (SELECT object_id FROM targetObj) ' + @colFilter
      + N'
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
  JOIN [' + @dbName
      + N'].sys.columns col
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
  LEFT JOIN [' + @dbName
      + N'].sys.foreign_keys fk
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
      ''' + @dbName + N'_' + @schName + N'_' + @tblName
      + N''' AS tableName,
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
' ;

  print 'Dynamic SQL (preview): ' + left(@dynSql, 4000);


  if object_Id( 'tempdb..#exportjson' ) is not null
    drop table #exportjson;

  create table #exportjson
  (
    jsonOutput nVarchar(max)
  );

  insert #exportjson ( jsonOutput )
  exec sp_executesql @dynSql;

  declare @json nVarchar(max) = ( select top 1 jsonOutput from #exportjson );

  --print 'JSON preview: ' + left(isNull( @json, '(null)' ), 2000);


  declare @currentDate varchar(8) = convert( varchar(8), getDate(), 112 ); -- YYYYMMDD
  declare @currentTime varchar(6) = replace( convert( varchar(8), getDate(), 108 ), ':', '' ); -- HHMMSS

  declare @jsonFilePath nVarchar(500);

  set @jsonFilePath = @exportPath + N'\' + @dbName + N'_' + @schName + N'_' + @tblName + N'_' + @currentDate + N'_' + @currentTime + N'.json';


  if @json is null
  or len( @json ) = 0
  begin
    print 'No JSON output generated. Check if table or filters returned results.';

    return;
  end;

  if @exportPath <> ''
  begin
    declare @fso int, @fileHandle int, @hr int;

    exec @hr = sp_OACreate 'Scripting.FileSystemObject', @fso out;

    if @hr <> 0
    begin
      print 'Failed to create FileSystemObject. HRESULT=' + cast(@hr as varchar(10));

      return;
    end;

    exec @hr = sp_OAMethod @fso, 'CreateTextFile', @fileHandle out, @jsonFilePath, 2, True;

    if @hr <> 0
    begin
      print 'Failed to create file ' + @jsonFilePath + '. HRESULT=' + cast(@hr as varchar(10));

      exec sp_OADestroy @fso;

      return;
    end;

    exec @hr = sp_OAMethod @fileHandle, 'Write', null, @json;

    if @hr <> 0
    begin
      print 'Failed to write to file. HRESULT=' + cast(@hr as varchar(10));

      exec sp_OAMethod @fileHandle, 'Close';

      exec sp_OADestroy @fileHandle;

      exec sp_OADestroy @fso;

      return;
    end;

    exec @hr = sp_OAMethod @fileHandle, 'Close';

    exec sp_OADestroy @fileHandle;

    exec sp_OADestroy @fso;

    print 'File saved to: ' + @jsonFilePath;
  end;

  select @json as jsonOutput;
end;
