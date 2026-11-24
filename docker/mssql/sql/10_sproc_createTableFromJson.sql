
-- Drop and create logging table for debugging sproc_createTableFromJson
IF OBJECT_ID('dbo.sproc_createTableFromJson_log', 'U') IS NOT NULL
    DROP TABLE dbo.sproc_createTableFromJson_log;
GO

CREATE TABLE dbo.sproc_createTableFromJson_log (
    logID INT IDENTITY(1,1) PRIMARY KEY,
    logTimestamp DATETIME2 DEFAULT GETDATE(),
    targetDatabase NVARCHAR(128),
    targetSchema NVARCHAR(128),
    targetTableName NVARCHAR(256),
    inputJson NVARCHAR(MAX),
    generatedCreateSQL NVARCHAR(MAX),
    stepDescription NVARCHAR(500),
    errorMessage NVARCHAR(4000),
    errorNumber INT,
    errorSeverity INT,
    errorState INT,
    errorLine INT,
    columnCount INT,
    indexCount INT,
    success BIT DEFAULT 0,
    spid INT DEFAULT @@SPID,
    loginName NVARCHAR(128) DEFAULT SUSER_SNAME(),
    hostName NVARCHAR(128) DEFAULT HOST_NAME()
);
GO

create or ALTER procedure dbo.sproc_createTableFromJson
      @json nvarchar(max)
as
begin
  set nocount on;

  declare @logID int;
  declare @stepDescription nvarchar(500);
  declare @generatedSQL nvarchar(max);

  declare @tableName sysName = json_Value( @json,'$.tableName' );
  declare @schemaName sysName = 'dbo';

  -- Initial log entry
  insert into dbo.sproc_createTableFromJson_log
    (targetDatabase, targetSchema, targetTableName, inputJson, stepDescription, columnCount, indexCount)
  values
    (db_name(), @schemaName, @tableName, @json, 'SPROC_START: Received JSON input',
     (select count(*) from openjson(@json, '$.columns')),
     (select count(*) from openjson(@json, '$.indexes')));

  set @logID = SCOPE_IDENTITY();

  if @tableName is null or @tableName = ''
    begin
      update dbo.sproc_createTableFromJson_log
      set stepDescription = 'ERROR: tableName is null or empty',
          errorMessage = 'tableName is required in JSON',
          errorNumber = 50001
      where logID = @logID;

      raiserror ('tableName is required in JSON',16,1);
      return;
    end

  update dbo.sproc_createTableFromJson_log
  set stepDescription = 'VALIDATED: tableName parsed successfully'
  where logID = @logID;

  print 'Creating table [' + @schemaName + '].[' + @tableName + '] in database [' + db_Name() + ']...';


  if object_Id( '[dbo].[' + @tableName + ']','U' ) is not null
    begin
      declare @dropTable nvarchar(max) = N'DROP TABLE [dbo].[' + @tableName + N'];';

      update dbo.sproc_createTableFromJson_log
      set stepDescription = 'DROP_TABLE: Existing table found, attempting to drop',
          generatedCreateSQL = @dropTable
      where logID = @logID;

      begin try
        exec sp_executesql @dropTable;
        print 'Existing table [dbo].[' + @tableName + '] dropped.';

        update dbo.sproc_createTableFromJson_log
        set stepDescription = 'DROP_TABLE: Successfully dropped existing table'
        where logID = @logID;
      end try
      begin catch
        declare @dropError nvarchar(4000) = error_Message();

        update dbo.sproc_createTableFromJson_log
        set stepDescription = 'DROP_TABLE: Failed to drop existing table',
            errorMessage = @dropError,
            errorNumber = ERROR_NUMBER(),
            errorSeverity = ERROR_SEVERITY(),
            errorState = ERROR_STATE(),
            errorLine = ERROR_LINE()
        where logID = @logID;

        raiserror ('Failed to drop existing table: %s',16,1,@dropError);
        return;
      end catch

    end
  else
    begin
      update dbo.sproc_createTableFromJson_log
      set stepDescription = 'DROP_TABLE: No existing table found, proceeding to create'
      where logID = @logID;
    end

  declare @columns table
            (
                ordinal            int           not null,
                columnName         sysName       not null,
                sqlType            sysName       not null,
                max_length         smallInt      null,
                precision          tinyInt       null,
                scale              tinyInt       null,
                is_nullable        bit           not null,
                is_identity        bit           not null,
                is_computed        bit           not null,
                computedDefinition nvarchar(max) null,
                is_persisted       bit           null,
                defaultValue       nvarchar(max) null,
                collation_name     sysName       null,
                is_rowguidcol      bit           not null,
                seed_value         bigInt        null,
                increment_value    bigInt        null
            );

  update dbo.sproc_createTableFromJson_log
  set stepDescription = 'PARSE_COLUMNS: Parsing column definitions from JSON'
  where logID = @logID;

  begin try
    insert into @columns
    select  ordinal,
            columnName,
            sqlType,
            max_length,
            precision,
            scale,
            is_nullable,
            is_identity,
            is_computed,
            computedDefinition,
            is_persisted,
            defaultValue,
            collation_name,
            is_rowguidcol,
            seed_value,
            increment_value
    from    opeNjSon( @json,'$.columns' )
            with (
            ordinal int '$.ordinal',
            columnName sysName '$.columnName',
            sqlType sysName '$.sqlType',
            max_length smallInt '$.max_length',
            precision tinyInt '$.precision',
            scale tinyInt '$.scale',
            is_nullable bit '$.is_nullable',
            is_identity bit '$.is_identity',
            is_computed bit '$.is_computed',
            computedDefinition nvarchar(max) '$.computedDefinition',
            is_persisted bit '$.is_persisted',
            defaultValue nvarchar(max) '$.defaultValue',
            collation_name sysName '$.collation_name',
            is_rowguidcol bit '$.is_rowguidcol',
            seed_value bigInt '$.seed_value',
            increment_value bigInt '$.increment_value'
            );

    declare @parsedColumnCount int = (select count(*) from @columns);

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'PARSE_COLUMNS: Successfully parsed ' + cast(@parsedColumnCount as nvarchar) + ' columns',
        columnCount = @parsedColumnCount
    where logID = @logID;
  end try
  begin catch
    declare @parseColError nvarchar(4000) = ERROR_MESSAGE();

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'PARSE_COLUMNS: Failed to parse column definitions',
        errorMessage = @parseColError,
        errorNumber = ERROR_NUMBER(),
        errorSeverity = ERROR_SEVERITY(),
        errorState = ERROR_STATE(),
        errorLine = ERROR_LINE()
    where logID = @logID;

    raiserror ('Failed to parse column definitions: %s',16,1,@parseColError);
    return;
  end catch


  declare @sql nvarchar(max) = N'CREATE TABLE [dbo].[' + @tableName + N'] (';


  select  @sql += char( 13 ) + N'    [' + columnName + N'] ' + case when is_computed = 1 then N'AS ' + computedDefinition + case when is_persisted = 1 then N' PERSISTED' else N'' end else

                                                                case sqlType when 'varchar' then 'VARCHAR(' + case when max_length = -1 then 'MAX' else cast( max_length as nvarchar ) end + ')' when 'nvarchar' then 'NVARCHAR(' + case when max_length = -1 then 'MAX' else cast( max_length / 2 as nvarchar ) end + ')' when 'char' then 'CHAR(' + cast( max_length as nvarchar ) + ')' when 'nchar' then 'NCHAR(' + cast( max_length / 2 as nvarchar ) + ')' when 'decimal' then 'DECIMAL(' + cast( precision as nvarchar ) + ',' + cast( scale as nvarchar ) + ')' when 'numeric' then 'NUMERIC(' + cast( precision as nvarchar ) + ',' + cast( scale as nvarchar ) + ')' when 'datetime2' then 'DATETIME2(' + cast( scale as nvarchar ) + ')' else upper( sqlType ) end +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               -- Collation
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               case when collation_name is not null then ' COLLATE ' + collation_name else '' end +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   -- Identity
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   case when is_identity = 1 then ' IDENTITY(' + cast( coalesce( seed_value,1 ) as nvarchar ) + ',' +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     cast( coalesce( increment_value,1 ) as nvarchar ) + ')' else '' end +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          -- ROWGUIDCOL
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          case when is_rowguidcol = 1 then ' ROWGUIDCOL' else '' end +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      -- Nullability
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      case when is_nullable = 1 then ' NULL' else ' NOT NULL' end +
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   -- Default
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   case when defaultValue is not null then ' DEFAULT ' + defaultValue else '' end end + ','
  from    @columns
  order by ordinal;


  set @sql = left( @sql,len( @sql ) - 1 ) + char( 13 ) + N');';

  update dbo.sproc_createTableFromJson_log
  set stepDescription = 'CREATE_TABLE: Attempting to create table',
      generatedCreateSQL = @sql
  where logID = @logID;

  begin try
    exec sp_executesql @sql;
    print 'Table [dbo].[' + @tableName + '] created successfully.';

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'CREATE_TABLE: Table created successfully'
    where logID = @logID;
  end try
  begin catch
    declare @errMsg nvarchar(4000) = error_Message();

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'CREATE_TABLE: Failed to create table',
        errorMessage = @errMsg,
        errorNumber = ERROR_NUMBER(),
        errorSeverity = ERROR_SEVERITY(),
        errorState = ERROR_STATE(),
        errorLine = ERROR_LINE()
    where logID = @logID;

    raiserror ('Failed to create table: %s',16,1,@errMsg);
    return;
  end catch


  declare @indexes table
            (
                indexName      sysName,
                is_unique      bit,
                is_primary_key bit,
                type_desc      nvarchar(60),
                indexColumns   nvarchar(max)
            );

  update dbo.sproc_createTableFromJson_log
  set stepDescription = 'PARSE_INDEXES: Parsing index definitions from JSON'
  where logID = @logID;

  begin try
    insert into @indexes
    select  indexName,
            is_unique,
            is_primary_key,
            type_desc,
            indexColumns
    from    opeNjSon( @json,'$.indexes' )
            with (
            indexName sysName '$.indexName',
            is_unique bit '$.is_unique',
            is_primary_key bit '$.is_primary_key',
            type_desc nvarchar(60) '$.type_desc',
            indexColumns nvarchar(max) '$.indexColumns' as json
            );

    declare @parsedIndexCount int = (select count(*) from @indexes);

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'PARSE_INDEXES: Successfully parsed ' + cast(@parsedIndexCount as nvarchar) + ' indexes',
        indexCount = @parsedIndexCount
    where logID = @logID;
  end try
  begin catch
    declare @parseIdxError nvarchar(4000) = ERROR_MESSAGE();

    update dbo.sproc_createTableFromJson_log
    set stepDescription = 'PARSE_INDEXES: Failed to parse index definitions (non-fatal)',
        errorMessage = @parseIdxError
    where logID = @logID;
    -- Continue anyway - indexes are optional
  end catch


  declare @indexName sysName,
          @isUnique bit,
          @isPK bit,
          @typeDesc nvarchar(60),
          @indexCols nvarchar(max);
  declare index_cursor cursor for
      select indexName,
             is_unique,
             is_primary_key,
             type_desc,
             indexColumns
      from    @indexes;

  open index_cursor;
  fetch next from index_cursor into @indexName,@isUnique,@isPK,@typeDesc,@indexCols;

  while @@fetch_Status = 0
    begin

      declare @colList nvarchar(max) = '';

      select  @colList = @colList + case when @colList = '' then '' else ', ' end +
              '[' + json_Value( value,'$.columnName' ) + ']'
      from    opeNjSon( @indexCols );


      set @sql = case when @isPK = 1 then N'ALTER TABLE [dbo].[' + @tableName +
                  N'] ADD CONSTRAINT [' + @indexName + N'] PRIMARY KEY ' +
                  @typeDesc + N' (' + @colList + N');' else N'CREATE ' + case when @isUnique = 1 then 'UNIQUE ' else '' end +
                  @typeDesc + N' INDEX [' + @indexName + N'] ON [dbo].[' +
                  @tableName + N'] (' + @colList + N');' end;

      begin try
        exec sp_executesql @sql;
        print 'Index [' + @indexName + '] created.';
      end try
      begin catch
        print 'Warning: Failed to create index [' + @indexName + ']: ' + error_Message();
      end catch

      fetch next from index_cursor into @indexName,@isUnique,@isPK,@typeDesc,@indexCols;
    end

  close index_cursor;
  deallocate index_cursor;

  update dbo.sproc_createTableFromJson_log
  set stepDescription = 'COMPLETE: Table [dbo].[' + @tableName + '] ready in [' + db_Name() + ']',
      success = 1
  where logID = @logID;

  print 'Complete: [dbo].[' + @tableName + '] ready in [' + db_Name() + '].';
end;
GO