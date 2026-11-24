# PostgreSQL engine: archived notes

**Status: archived reference from an earlier experiment. Last exercised around 2025-02-14 (the newest commit that touched the Postgres-specific files; the two SQL Server export procedures were edited once more on 2025-03-31, during the port to SQL Server). It is NOT wired into this package's build and has NOT been tested with the current CommandBox image (now Ubuntu 24.04). Nothing in this directory is run by cb-localdb.**

The supported engine is SQL Server (`docker/mssql`). This directory keeps what the Postgres attempt looked like when it last worked, so the route can be revived if a team prefers it. The author's own summary: it worked, but linked-server-style access to SQL Server needed a lot of workarounds and felt fragile; the procedures that copy a table definition and its data from SQL Server to Postgres were the part worth keeping.

## How to read these notes

Every item is tagged:

- **[src]** read directly from the archived files or from the commit history of the original (private) application repository.
- **[inf]** my inference from reading that code, or general knowledge of PostgreSQL, SQL Server, FreeTDS and tds_fdw. Not observed running. Verify before relying on it.

Nothing here was re-run while writing these notes. Database, schema and bucket names in examples are neutral stand-ins.

## Files

| File | What it is | Original name |
|---|---|---|
| `Dockerfile.fragment` | Image build: Postgres 14, FreeTDS from source, tds_fdw from source, build-time data download, `initdb` | `Dockerfile` |
| `entrypoint.sh` | Container start: load env file, write FreeTDS locale config, start Postgres, create database, call the two scripts below, then start CommandBox | `docker-entrypoint.sh` |
| `fdw_setup.sh` | Creates one tds_fdw foreign server per source database and imports remote schemas as foreign tables | `fdw_setup.sh` |
| `fdw_connections.example.json` | Input for `fdw_setup.sh` | `fdw_connections.json` |
| `sync.sh` | Downloads exported CSV + JSON files from S3, recreates each table from its JSON definition, loads the CSV with `\copy` | `docker-syncPostgres.sh` |
| `sql/create_table_from_json.sql` | Postgres functions: JSON table definition to `CREATE TABLE` + indexes | `create_table_from_json.sql` |
| `sql/source-mssql/sproc_exportTableConfigToJson.sql` | Runs on the central SQL Server: table definition to JSON | `sproc_exportTableConfigToJson.sql` |
| `sql/source-mssql/sproc_exportTableToCsv.sql` | Runs on the central SQL Server: table data to a pipe-delimited CSV via `bcp` | `sproc_exportTableToCsv.sql` |

Each file's header lists what was changed for publication (variable renames, placeholders). The logic is otherwise as it was.

## Architecture

- **[src]** One container ran both CommandBox (Lucee 5.4 at the time) and a PostgreSQL 14 server. The Postgres cluster was created with `initdb` at image build time and started by the entrypoint with `pg_ctl` before CommandBox.
- **[src]** The CFML application reached the local database through a second datasource on `localhost:5432`, wrapped in a second qb QueryBuilder (`qb2`) and SchemaBuilder (`sb2`) that use the Postgres grammar. The central SQL Server stayed on the application's normal datasource and `qb`.
- **[src]** Data could reach the local database two ways:
  1. **Foreign tables.** `fdw_setup.sh` created a tds_fdw foreign server per SQL Server database and ran `IMPORT FOREIGN SCHEMA` for each mapped schema. Queries against those tables are executed live on the central server. The test handler also made local copies with `SELECT * INTO "local_table" FROM mapped_schema."RemoteTable"`.
  2. **Exported files.** Two procedures on the central SQL Server wrote a JSON table definition and a pipe-delimited CSV per table to a folder on that server. The files ended up in an S3 bucket (`syncData/csv`). The image build downloaded them, the container downloaded any missing ones at start, and `sync.sh` rebuilt each table from the JSON and loaded the CSV with `\copy`.
- **[src]** Schema mapping is `remote:local` from the Postgres point of view, one local schema per remote database + schema, all lower case, for example `dbo:salesdb_dbo,ref:salesdb_ref` for database `SalesDB`. Tables loaded from files go into `public` and are named `<db>_<schema>_<table>`.
- **[inf]** tds_fdw is read-only (its README: "does not yet support JOIN push-down, or write operations"). Results therefore cannot be written back to SQL Server through Postgres; the application has to write them through its SQL Server datasource. The archived code contains no write-back step.
- **[inf]** How the exported files got from the SQL Server host's folder to S3 is not in the archived material.

## What worked

- **[src]** The image built and the container started both servers. Commit messages over the two weeks read "Added postgres", "1st run", "Working build", "FDW", "fdw from git", "TDS_FDW money fields", "Fully integrated", "env variables", "Almost there", "Postgres sync".
- **[src]** The entrypoint runs a smoke test on every start: create `test_table`, insert a row, select it back, print `version()`.
- **[src]** A test handler in the application did, through `qb2`/`sb2`: insert and read on a local table; `first()` on foreign tables, including one with a `where` on a mixed-case column; `sb2.hasTable()`; `SELECT * INTO` copies of five foreign tables into local tables; a join of a local copy to two foreign tables; a `sum()` over that join. Each step printed elapsed time. No timings were recorded in the repository.
- **[src]** The file path (JSON definition, `create_table_from_json`, `\copy`, row count check) is the last thing that was worked on and is the part the author called faithful.
- **[src]** At the last commit the test handler has a stray token straight after the first local round trip, added in the same commit that introduced the file-based path. **[inf]** That stops the request before any foreign-table query, so the foreign-table half of the handler was not being exercised at the very end. Whether that was deliberate is not recorded.

## Workarounds and fragile points

### Image build (`Dockerfile.fragment`)

- **[src]** Base image is `ortussolutions/commandbox:latest`, unpinned. The first comment says Alpine but the file uses `apt-get`. **[inf]** Whatever Debian/Ubuntu release `latest` pointed to in February 2025 is not recorded; the PGDG repository line depends on `lsb_release -cs`.
- **[src]** The PGDG key is added with `apt-key add`. **[inf]** `apt-key` is deprecated; current practice is a keyring file referenced with `signed-by`.
- **[src]** Packages include `netcat` and `awscli`. **[inf]** On Ubuntu 24.04 `netcat` is only a virtual package (use `netcat-openbsd`) and `awscli` is, as far as I know, no longer in the apt archive. Check both.
- **[src]** PostgreSQL 14 is hard-coded in package names, in `PATH`, in `PG_CONFIG` and in the `pg_ctl` path in the entrypoint. **[inf]** PostgreSQL 14 reached end of life in November 2026.
- **[src]** FreeTDS is compiled from source (tag `v1.4.7`, `--with-tdsver=7.4`, prefix `/usr/local`). The distribution packages `freetds-bin` / `freetds-dev` were used first and are now commented out. A second, commented-out build pulls a personal FreeTDS fork branch named `fix-money-numeric`.
- **[src]** tds_fdw is compiled from a personal fork, branch `my-fix-branch`, not from upstream and not pinned to a commit. Upstream master was used for one day before the switch. **[inf]** The fork's changes were not inspected for these notes. From the commit sequence (see "money" below) it is the fix that made `money` columns work. This is the single most important thing to check when reviving: a branch can move or disappear.
- **[src]** The whole application directory, including the env file, is copied into the image, and S3 credentials are read out of that env file during the build to download data files into an image layer. **[inf]** Credentials and data end up in the image. The original also echoed the access key id to the build log (removed here).
- **[src]** Build-time parsing of the env file is `grep '^KEY=' | cut -d '=' -f2 | sed` to strip quotes. **[inf]** A value containing `=` is cut short.
- **[src]** `RUN [ -f file ] && dos2unix file` is used for five files. **[inf]** It looks optional but fails the build when the file is missing, because the test itself returns non-zero.
- **[src]** `dos2unix` is run on every script and config file because the sources were edited on Windows.
- **[src]** Two Postgres clusters exist in the image: the one the Debian package creates (`/etc/postgresql/14/main`) and the one made by `initdb -D /var/lib/postgresql/data`. Only the second is started. `pg_hba.conf` and `postgresql.conf` edits are written to both.
- **[src]** The build ends with the CommandBox image's own `$BUILD_DIR/run.sh` and `FINALIZE_STARTUP=true`, and the entrypoint finishes with `exec /usr/local/bin/startup-final.sh`. **[inf]** This relies on the CommandBox image generating that script at build time; it is an image-internal contract that can change between image versions.
- **[src]** A private-registry login step for ForgeBox (BuildKit secret + a CommandBox recipe) is commented out. The original readme says the credentials could not be passed in when building locally and were hard-coded in the recipe instead. None of that is carried over.

### tds_fdw and FreeTDS (`fdw_setup.sh`, `entrypoint.sh`)

- **[src]** Server options set: `servername`, `port`, `database`, `language 'us_english'`, `tds_version '7.4'`. Nothing else. No table options are passed to `IMPORT FOREIGN SCHEMA`.
- **[inf]** Not set, so tds_fdw defaults apply (checked against the upstream docs, November 2026):
  - `row_estimate_method` defaults to `execute`: the planner estimate is obtained by running the query on the remote server. `showplan_all` is the cheap alternative.
  - `msg_handler` defaults to `blackhole`: SQL Server messages are discarded. `notice` is more useful during bring-up.
  - Pushdown is limited to `WHERE` clauses and column lists, and only while `match_column_names` is enabled (the default, as far as I know). Joins, aggregates, `ORDER BY` and `LIMIT` are not pushed down. The test handler's join of a local table to two foreign tables, and its `first()` calls, therefore fetch remote rows and finish the work locally.
  - `character_set` has no effect on TDS 7.0 and later.
- **[src]** `tds_version` is forced to 7.4 twice: at FreeTDS compile time and in `CREATE SERVER`. An intermediate version of the script also ran `ALTER SERVER ... SET tds_version`. **[inf]** The tds_fdw README says Unicode errors from SQL Server need TDS 7.0 or higher; with the wrong protocol version `nvarchar` data breaks.
- **[src]** Money. The history is: day 1 distribution FreeTDS + upstream tds_fdw; same day FreeTDS rebuilt from source; same day a commit titled "TDS_FDW money fields" that exported `LC_MONETARY`, `LC_NUMERIC`, `LC_ALL`, `LANG` as `C` and added a `[C]` section with monetary separators to FreeTDS `locales.conf`; next day the switch to the personal tds_fdw fork plus the commented-out FreeTDS fork `fix-money-numeric`; three days later the locale exports and the extra `locales.conf` sections were removed again. **[inf]** So `money`/`smallmoney` columns did not come through tds_fdw correctly out of the box, locale settings did not fix it, and a patched tds_fdw did.
- **[src]** The entrypoint rewrites `/usr/local/etc/locales.conf` on every start with `date format = %b %e %Y %I:%M:%S.%z%p` and `charset = iso_1`. **[inf]** That date format keeps fractional seconds when FreeTDS renders `datetime` values as text for tds_fdw. The path is correct only for a FreeTDS built with prefix `/usr/local`; the distribution package reads `/etc/freetds/locales.conf` (the first version of the script wrote there).
- **[src]** No `freetds.conf` is written, so no `client charset` is set. `initdb` is run with no `--encoding` or `--locale`. **[inf]** FreeTDS then converts to its default client charset (ISO-8859-1), and the cluster encoding follows the build environment's locale, possibly `SQL_ASCII`. Characters outside Latin-1 are at risk on the foreign-table path. Check `SHOW server_encoding` and test with real non-ASCII data. Nothing in the archive addresses collation: SQL Server comparisons are normally case-insensitive, Postgres comparisons are case-sensitive.
- **[src]** Identifier case. `CREATE SERVER ${server_name}` and `CREATE SCHEMA ${local_schema}` are unquoted, so both fold to lower case; the example mappings are written in lower case already. Imported foreign tables and their columns keep SQL Server's mixed case. The test handler shows the consequence: raw SQL has to write `mapped_schema."MixedCaseTable"`, and qb (which quotes every identifier) has to be given the exact case of table and column names.
- **[src]** `IMPORT FOREIGN SCHEMA` imports the whole remote schema, with no `LIMIT TO`. **[inf]** Start-up time and failure exposure grow with the size of the remote schema, and one unsupported column type can fail a whole schema import.
- **[src]** `CREATE SERVER` and `CREATE USER MAPPING` use `IF NOT EXISTS`; `IMPORT FOREIGN SCHEMA` has no such guard. **[inf]** Restarting a container (as opposed to recreating it) re-runs the import against existing foreign tables and errors. The script has no `set -e` and always exits 0, so the error is only visible in the log.
- **[src]** The connection list is read with `for conn in $(jq -c '.connections[]' ...)`. **[inf]** Word splitting breaks on any JSON value that contains a space (a schema mapping written `"dbo:a, ref:b"`, a password with a space).
- **[src]** `fdw_setup.sh` uses the database name variable at the top and only defaults it later, inside the function.

### Authentication

- **[src]** Local Postgres: when the env file says `ENVIRONMENT=development`, the build appends `host all all 0.0.0.0/0 trust` to `pg_hba.conf`. The entrypoint starts Postgres with `listen_addresses=*` in every environment. The application connected as `postgres` with an empty password. **[inf]** Outside development it relies on `initdb`'s default `trust` for loopback connections. The database superuser is the application account.
- **[src]** A `scram-sha-256` variant (set the `postgres` password with `postgres --single` at build time) is present but commented out. The application's JDBC driver setting at the time was the PostgreSQL bundle version 9.4.1212. **[inf]** That driver predates SCRAM support in pgjdbc (42.2.0), which may be why password authentication was parked. Not confirmed.
- **[src]** SQL Server: SQL login and password, from `FDW_DEFAULT_DB_USER` / `FDW_DEFAULT_DB_PASSWORD` or per connection in the JSON file, stored in a tds_fdw user mapping. The mapping is created `FOR CURRENT_USER`, which is `postgres`. **[inf]** If the application connects as any other role, foreign tables fail for lack of a user mapping.
- **[src]** Every statement is run as `su postgres -c "psql -c \"...\""` with values interpolated by the shell. **[inf]** The SQL Server password is visible in the process list while the command runs and in `pg_user_mappings` afterwards, and a password containing a quote, `$`, backtick or backslash breaks the command. Encryption of the SQL Server connection is not configured anywhere (with tds_fdw that is a `freetds.conf` setting).

### Start-up ordering (`entrypoint.sh`, `sync.sh`)

- **[src]** Postgres is started in the background and the script then does `sleep 5`. There is no readiness loop. **[inf]** On a slow or cold host the following `psql` calls race the server. (The later SQL Server version of the same script replaced the fixed sleep with a retry loop.)
- **[src]** The entrypoint and `sync.sh` run under `set -e`; `sync.sh` begins with `aws s3 ls`. **[inf]** If S3 is unreachable or credentials are missing, the container exits before CommandBox starts. Inside the per-file loop, failures are downgraded to warnings instead, so a table can be silently missing or empty.
- **[src]** Scripts are called by relative path (`./fdw_setup.sh`, `./docker-syncPostgres.sh`), which works only because the image's `WORKDIR` is `/app`.
- **[src]** Postgres is not supervised and not stopped on shutdown; CommandBox replaces the shell as PID 1. **[inf]** Acceptable for a scratch database, but a Postgres crash leaves the application running against nothing.
- **[src]** `sync.sh` ends with `exec "$@"` although it is called with no arguments. Left over from an earlier arrangement.
- **[src]** No Postgres tuning is applied. **[inf]** Defaults (for example 128 MB `shared_buffers`, full durability) are a poor fit for a throwaway number-crunching database; unlogged tables, `fsync=off` and a larger `work_mem` are the usual levers. Not tried in the archive.

### Env files

- **[src]** The container reads `/app/.env2`, not `.env`. The Dockerfile comment explains: "bash has stringent escaping rules for .env variables that break CF". The entrypoint loads it with `set -a; source /app/.env2`.
- **[inf]** So two env files had to be kept in step: one in the properties style the CFML side reads, one that is valid bash. Anything bash treats specially (spaces, `$`, quotes, `#`) is the dividing line. A single source of truth, or passing real container environment variables, removes the problem.

### Table definition copy (`sproc_exportTableConfigToJson.sql`, `create_table_from_json.sql`, `sync.sh`)

- **[src]** The export procedure reads `sys.columns`, `sys.types`, `sys.computed_columns`, `sys.default_constraints`, `sys.identity_columns`, `sys.indexes` and constraints, and returns one JSON document: `tableName` (`<db>_<schema>_<table>`), `columns`, `indexes`, `constraints`. With an export path it also writes the file through `sp_OACreate 'Scripting.FileSystemObject'`. **[inf]** That needs "Ole Automation Procedures" enabled on the central server and write access for the SQL Server service account.
- **[src]** The file is written as Unicode. `sync.sh` converts it from UTF-16LE with `iconv`, strips NUL bytes, replaces every doubled single quote `''` with a double quote, validates with `jq`, removes any `$$`, and passes the result to the function inside a `$$...$$` literal.
- **[inf]** The `''` replacement corrupts the JSON for any column whose default is an empty string (`('')` becomes `(")`), and `jq` then rejects the file. The script prints a warning and skips table creation.
- **[src]** Type mapping in `map_sqlserver_type`: `int` to `integer`; `tinyint` to `smallint`; `bit` to `boolean`; `float` with precision 53 to `double precision`; `money` to `numeric(19,4)`; `smallmoney` to `numeric(10,4)`; `datetime2` to `timestamp`; `date` to `date`; `varchar` and `nvarchar` to `varchar(max_length)`; **everything else to `text`**.
- **[inf]** "Everything else" includes `bigint`, `smallint`, `decimal`/`numeric`, `datetime`, `smalldatetime`, `real`, `char`/`nchar`, `uniqueidentifier`, `varbinary`, `time` and `datetimeoffset`. Numeric and date columns of those types arrive as text, so comparisons, sorting and arithmetic on them are wrong or fail until the map is completed.
- **[inf]** `max_length` in `sys.columns` is in bytes. An `nvarchar(50)` becomes `varchar(100)` (harmless), but `varchar(max)` / `nvarchar(max)` report `-1` and produce `varchar(-1)`, which fails. The code comment acknowledges that large lengths should map to `text`.
- **[src]** Defaults: outer parentheses are stripped in a loop, `getdate()` becomes `now()`, and `0`/`1` become `false`/`true` for `bit`. Everything else is passed through unchanged. **[inf]** Any other T-SQL default (`newid()`, `sysdatetime()`, `getutcdate()`, expressions) fails the `CREATE TABLE`. The parenthesis loop only checks the first and last character, so `(a)+(b)` is mangled.
- **[src]** Identity columns become `GENERATED ALWAYS AS IDENTITY` with seed and increment. **[inf]** `COPY` can still load explicit values into such a column, but the sequence is not advanced afterwards, so later inserts collide unless the sequence is reset.
- **[src]** Computed columns become `GENERATED ALWAYS AS (...) STORED`. The T-SQL expression is reused with `[` and `]` replaced by `"`, followed by a pass that re-quotes lower-cased column references in their original case. **[inf]** Only expressions that happen to be valid in both dialects survive (plain arithmetic, `coalesce`, `case`). `isnull`, `iif`, `convert`, `datediff`, string `+` and similar fail the `CREATE TABLE`. `COPY` also refuses to load a file that lists a generated column.
- **[src]** Indexes are recreated by name and column list; the primary key becomes `<table>_pkey`; if no primary key came through and a column named `id` exists, a primary key on `id` is added. The `constraints` array (check constraints, foreign keys, defaults) is exported but ignored by the Postgres function.
- **[inf]** Index names are unique per table in SQL Server but per schema in Postgres. Two tables with an index of the same name collide, and `CREATE INDEX IF NOT EXISTS` skips the second one without an error. Included columns are treated as key columns, key order uses `index_column_id`, and filters, descending keys and columnstore indexes are not represented.
- **[src]** Table name case. `sync.sh` derives the table name from the file name and lower-cases it for `\copy` and the row count, while the function creates the table from the JSON `tableName` exactly as exported, and its primary-key check casts that name to `regclass` unquoted. The original usage examples call both export procedures with the full table name typed in lower case. **[inf]** That is what made it line up: the exported name must already be all lower case (which works on the SQL Server side only because its catalog comparison is case-insensitive). Export with the real mixed-case name and the load fails. Column names keep their original case and are quoted throughout.
- **[src]** The table is dropped (`DROP TABLE IF EXISTS ... CASCADE`) and rebuilt for every CSV file, in file-name order. **[inf]** With several dated exports of the same table, each one is loaded in turn and only the last survives; `CASCADE` silently removes dependent views.
- **[src]** The JSON file for a table is found with the glob `<table_name>*.json`, sorted ascending, first match. **[inf]** That picks the oldest definition, and a table whose name is a prefix of another table's name can pick up the wrong file. The file-name glob is case-sensitive on Linux, another reason the lower-case export names mattered.

### Data copy (`sproc_exportTableToCsv.sql`, `sync.sh`)

- **[src]** The export builds `SELECT 'col' AS [col], ... UNION ALL SELECT CAST(ISNULL([col],'') AS NVARCHAR(4000)), ... FROM table`, wraps it in a temporary view, and shells out through `xp_cmdshell` to `bcp ... queryout -c -t"|" -r 0x0A -C 65001 -T -S localhost`. **[inf]** It needs `xp_cmdshell` enabled, `bcp` installed on the SQL Server host and a trusted connection there, and it creates and drops a view in the database it runs in.
- **[src]** The temporary view is the newer version. The older version put the whole `SELECT` on the `bcp` command line. **[inf]** That ran into the command length limit on wide tables.
- **[inf]** Fidelity problems that follow from `CAST(ISNULL(col,'') AS NVARCHAR(4000))`. These are the main reason to distrust the file path until it has been compared against source data:
  - `ISNULL` returns the type of its first argument, so for non-string columns the `''` is converted to that type: NULL integers and floats are exported as `0`, NULL dates as `1900-01-01`. `decimal`/`numeric` and `uniqueidentifier` columns may raise a conversion error instead.
  - Default string conversion keeps about six significant digits of a `float`, two decimals of `money`, and no seconds for `datetime` (`Feb 14 2025  3:04PM`).
  - Values longer than 4000 characters are truncated.
  - `bcp -c` does no quoting or escaping, so a `|`, a double quote or a line break inside a value corrupts the row for the CSV parser.
  - `UNION ALL` without `ORDER BY` does not guarantee the header row comes first. It does in practice.
- **[src]** Loading is `\copy public.<table> ("Col1","Col2",...) FROM file CSV HEADER DELIMITER '|'`, with the column list taken from the file's header row and quoted to keep case.
- **[inf]** In CSV mode an unquoted empty field is NULL. NULL strings therefore round-trip, but genuinely empty strings also become NULL, and a `NOT NULL` text column that contains empty strings fails the whole `\copy`.
- **[src]** After each load the script prints the local row count. Nothing compares it with the source.
- **[src]** Files are downloaded when missing locally, by file name, but only local `.csv` names are compared, so the JSON files are fetched again on every start. Nothing removes old files or old tables.

### Two generations of the export procedures

Where a file exists in both generations, the newer one is archived here. Differences that matter:

- **[src]** Names: `sp_exportTableConfigToJSON` / `sp_exportTableToCsv` (the first one created in `master`) became `dbo.sproc_exportTableConfigToJSON` / `dbo.sproc_exportTableToCSV` in the working database. The original usage examples still use the `sp_` names.
- **[src]** `@bWriteableColumnsOnly` defaulted to `1` in the Postgres-era versions (computed and identity columns left out of both the definition and the data) and to `0` in the newer versions. **[inf]** The Postgres loader was last run with the old default. With the new default, tables with computed columns will hit the generated-column problems above; with the old one, identity columns such as `id` are absent locally, and the index list is not filtered to match, so an index or primary key on a left-out column fails the function. Decide this per table and test it.
- **[src]** The JSON procedure gained `is_persisted` per column and an empty `@exportPath` default that skips the file and just returns the JSON as a result set. **[inf]** That makes it callable from application code with no file system or OLE access on the SQL Server.
- **[src]** The CSV procedure gained the temporary view and a `try/catch` that drops it.
- **[src]** The connections file later gained a top-level `linkedServer` key for the SQL Server engine. `fdw_setup.sh` ignores it.

## What a CFML application needs on its side

- **[src]** WireBox mappings (datasource name replaced with `localdb`):

  ```cfml
  map( "PostgresQB" )
    .to( "qb.models.Query.QueryBuilder" )
    .initArg( name = "grammar", ref = "PostgresGrammar@qb" )
    .initArg( name = "defaultOptions", value = { "datasource" : "localdb" } );

  map( "PostgresSB" )
    .to( "qb.models.Schema.SchemaBuilder" )
    .initArg( name = "grammar", ref = "PostgresGrammar@qb" )
    .initArg( name = "defaultOptions", value = { "datasource" : "localdb" } )
    .initArg( name = "defaultSchema", value = "public" );
  ```

  injected as `property name="qb2" inject="provider:PostgresQB";` and `property name="sb2" inject="provider:PostgresSB";`. qb was at 9.5 then; not tried with later qb versions.
- **[src]** JDBC settings recorded in the env file: driver class `org.postgresql.Driver`, OSGi bundle `org.postgresql.jdbc42` version `9.4.1212`, URL `jdbc:postgresql://localhost:5432/`, user `postgres`, empty password. **[inf]** That is the PostgreSQL extension Lucee 5 shipped with. The datasource definition that consumed these values was in a server config file kept out of version control, so its exact shape is not recoverable. A current pgjdbc is needed for SCRAM authentication.
- **[src]** Raw SQL against the local database in the test handler is written in Postgres dialect by hand, with double-quoted mixed-case identifiers.
- **[inf]** SQL that will not port from a SQL Server codebase. qb's builder methods translate most of this; everything inside `raw()`, `queryExecute()` and stored procedures has to be audited:
  - Temp tables: `#name`, `SELECT ... INTO #name`, table variables. Use `CREATE TEMP TABLE`.
  - Locking hints: `WITH (NOLOCK)` and the other table hints. Remove them.
  - `TOP n`. Use `LIMIT` (qb's `limit()` / `first()` do this).
  - Bracket quoting `[name]`. Use double quotes.
  - Three- and four-part names (`db.schema.table`, `server.db.schema.table`, `OPENQUERY`). A foreign table is addressed as `local_schema."Table"`.
  - `MERGE`: absent in PostgreSQL 14; from 15 on the syntax differs (no `OUTPUT $action`; `WHEN NOT MATCHED BY SOURCE` only from 17). `INSERT ... ON CONFLICT` is the usual replacement.
  - Identifier case: unquoted names fold to lower case, quoted names are exact. Tables made by `create_table_from_json` and imported foreign tables keep mixed-case column names, so `accountID` and `accountid` are different columns once quoted, which qb always does.
  - String comparison is case-sensitive; SQL Server's usual collation is not. Equality joins and filters on text can return fewer rows.
  - `bit` becomes `boolean`: `where flag = 1` is a type error.
  - Functions and operators: `ISNULL`, `GETDATE`, `DATEADD`, `DATEDIFF`, `CONVERT`, `IIF`, `LEN`, string `+`, `OUTPUT inserted.*` (use `RETURNING`), `EXEC proc` (use `CALL` or `SELECT fn()`), `sp_executesql`.

## To revive this

1. Decide which data path is wanted: live foreign tables, exported files, or an application-level copy (read with `qb`, insert with `qb2`). The file path has the most known fidelity gaps; the foreign-table path has the most moving parts.
2. Rebase `Dockerfile.fragment` on the current CommandBox image: pick a supported PostgreSQL major and update every hard-coded `14`; replace `apt-key`; fix `netcat` and `awscli`; pin the base image.
3. tds_fdw: diff the fork branch against upstream, then try a pinned upstream release with the distribution's FreeTDS first. Test `money`, `smallmoney`, `decimal`, `datetime` with fractional seconds, and `nvarchar` with non-Latin-1 text before anything else. Keep the fork only if those fail.
4. Write `freetds.conf` (client charset, encryption) and create the cluster with an explicit UTF-8 encoding.
5. Replace `sleep 5` with a `pg_isready` loop and decide what should stop the container (missing S3 access currently does; a failed table load does not).
6. Authentication: stop copying the env file into the image and reading secrets at build time; pass real environment variables at run time; give the application its own role and a user mapping for it; use a current pgjdbc.
7. Set `row_estimate_method 'showplan_all'` and, during bring-up, `msg_handler 'notice'`. Limit `IMPORT FOREIGN SCHEMA` to the tables actually needed.
8. Complete `map_sqlserver_type` (integers, `decimal`, `datetime`, `char`, `uniqueidentifier`, binary, `max` lengths) and decide what to do with computed columns and T-SQL defaults.
9. Fix or drop the CSV export: remove the `ISNULL`/`CAST` wrapping in favour of explicit per-type formatting, handle delimiters inside values, and stop requiring lower-case export names.
10. Add a check that compares row counts and a per-column checksum between source and local copy.
11. Port the application side: datasource, the two WireBox mappings, and an audit of raw SQL against the list above.
12. Align environment variable names with the SQL Server engine, wire the engine into the package build, and add a smoke test (local round trip, one foreign select, one table copy) before describing it as supported.

## Not known

- What the tds_fdw fork branch changes.
- Which base OS release the image was built on.
- How export files were moved from the SQL Server host to S3.
- The datasource definition the application used, and any performance numbers from the test handler.
- Whether the last working runs exported with or without computed and identity columns.
