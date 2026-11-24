-- ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment). Not built or tested by this package; see ../../NOTES.md.
-- Runs on the central SQL Server (the data source), not in the container.
-- Original name: resources/database/sprocs/sproc_exportTableToCsv.sql, last edited 2025-03-31
-- (an earlier copy, dated 2025-02-14, was named sp_exportTableToCsv). Unchanged apart from this header.
-- Input:  @fullTableName  [db.][schema.]table
--         @exportPath     folder on the SQL Server host
--         @bWriteableColumnsOnly  1 = leave out computed and identity columns
-- Output: <db>_<schema>_<table>_YYYYMMDD_HHMMSS.csv, pipe-delimited, LF rows, UTF-8, header row first
-- Needs:  xp_cmdshell enabled, bcp on the SQL Server host, a trusted connection to localhost.

set ansi_nulls on
go

set quoted_identifier on
go

create or alter procedure dbo.sproc_exportTableToCSV
(
  @fullTableName varchar(128), @exportPath varchar(260) = 'C:\temp', @bWriteableColumnsOnly bit = 0
)
as
begin
  set noCount on;


  declare @dbName sysname = parseName( @fullTableName, 3 );
  declare @schName sysname = parseName( @fullTableName, 2 );
  declare @tblName sysname = parseName( @fullTableName, 1 );

  if @dbName is null
    set @dbName = db_Name();

  if @schName is null
  or @schName = ''
    set @schName = 'dbo';

  print 'Target table: [' + @dbName + '].[' + @schName + '].[' + @tblName + ']';


  declare @schID int;
  declare @schemaSQL nVarchar(max) = N'SELECT @schIDOut = s.schema_id
          FROM [' + @dbName + N'].sys.schemas s
          WHERE s.name = @schName';

  exec sp_executesql @schemaSQL, N'@schIDOut INT OUTPUT, @schName SYSNAME', @schIDOut = @schID output, @schName = @schName;

  if @schID is null
  begin
    print 'Schema ' + @schName + ' not found in database ' + @dbName;

    return;
  end;


  declare @colFilter nVarchar(100) = N'';

  if ( @bWriteableColumnsOnly = 1 )
    set @colFilter = N' AND c.is_computed = 0 AND c.is_identity = 0 ';

  declare @hdrSelect nVarchar(max), @dataSelect nVarchar(max);


  declare @colSQL nVarchar(max)
    = N'
    WITH targetObj AS (
      SELECT object_id
      FROM [' + @dbName + N'].sys.tables
      WHERE name = ''' + @tblName + N'''
        AND schema_id = ' + cast(@schID as nVarchar(10)) + N'
    )
    SELECT
      @hdrSelectOut = STUFF((
          SELECT '', '' + CHAR(39) + c.name + CHAR(39) + '' AS '' + QUOTENAME(c.name)
          FROM [' + @dbName + N'].sys.columns c
          WHERE c.object_id = (SELECT object_id FROM targetObj)' + @colFilter
      + N'
          ORDER BY c.column_id
          FOR XML PATH(''''), TYPE
      ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, ''''),
      @dataSelectOut = STUFF((
          SELECT '', '' + ''CAST(ISNULL('' + QUOTENAME(c.name) + '','''''''') AS NVARCHAR(4000)) AS '' + QUOTENAME(c.name)
          FROM [' + @dbName + N'].sys.columns c
          WHERE c.object_id = (SELECT object_id FROM targetObj)' + @colFilter + N'
          ORDER BY c.column_id
          FOR XML PATH(''''), TYPE
      ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, '''');
    ';

  exec sp_executesql @colSQL, N'@hdrSelectOut NVARCHAR(MAX) OUTPUT, @dataSelectOut NVARCHAR(MAX) OUTPUT', @hdrSelectOut = @hdrSelect output, @dataSelectOut = @dataSelect output;

  if @hdrSelect is null
  or @dataSelect is null
  begin
    print 'Column list is NULL. Check that the table [' + @dbName + '].[' + @schName + '].[' + @tblName + '] exists and has columns.';

    return;
  end;

  declare @sql nVarchar(max) = N'SELECT ' + @hdrSelect + N' UNION ALL SELECT ' + @dataSelect + N' FROM [' + @dbName + N'].[' + @schName + N'].[' + @tblName + N']';

  print '--- Final SQL (copy & run this if needed) ---';
  print @sql;


  declare @currentDate varchar(8) = convert( varchar(8), getDate(), 112 ); -- YYYYMMDD
  declare @currentTime varchar(6) = replace( convert( varchar(8), getDate(), 108 ), ':', '' ); -- HHMMSS
  declare @exportFile nVarchar(500) = @exportPath + N'\' + @dbName + N'_' + @schName + N'_' + @tblName + N'_' + @currentDate + N'_' + @currentTime + N'.csv';


  declare @viewName sysname = 'vw_export_' + replace( cast(newId() as varchar(36)), '-', '' );
  declare @fullViewName nVarchar(500) = N'dbo.' + quoteName( @viewName );
  declare @createViewSQL nVarchar(max) = N'CREATE VIEW ' + @fullViewName + N' AS ' + @sql;
  declare @dropViewSQL nVarchar(500) = N'DROP VIEW ' + @fullViewName;

  print '--- View Name ---';
  print @fullViewName;


  declare @cmd nVarchar(4000) = N'bcp "SELECT * FROM ' + @fullViewName + N'" queryout "' + @exportFile + N'" -c -t"|" -r 0x0A -C 65001 -T -S localhost > NUL 2>&1';

  print '--- BCP Command ---';
  print @cmd;

  declare @cmdLen int = len( @cmd );

  print 'Command Length: ' + cast(@cmdLen as varchar(20));


  begin try
    exec sp_executesql @createViewSQL;

    exec master..xp_cmdshell @cmd;

    exec sp_executesql @dropViewSQL;
  end try
  begin catch
    print 'Error: ' + error_Message();

    if exists ( select * from sys.views where object_id = object_Id( @fullViewName ))
    begin
      exec sp_executesql @dropViewSQL;
    end;
  end catch;
end;
go
