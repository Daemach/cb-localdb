# cbLocalDB

A private scratch database inside your CommandBox container, with a qb accessor for it.

Heavy jobs often spend their time hammering a shared central database: staging rows, building temp tables, crunching, then writing a small result back. cbLocalDB moves the crunching next to the code. It installs SQL Server into a CommandBox Docker image, starts it beside your app, links it back to your central server, and gives ColdBox a second query builder (`qb2`) that points at it. Each container gets its own database. It is created empty when the container starts and is gone when the container stops.

```
        container                                   central server
 +---------------------------+
 |  CommandBox / Lucee       |  default datasource   +----------------+
 |    qb  ------------------------------------------>|  SQL Server    |
 |    qb2 --> SQL Server     |                       |  (source of    |
 |            (localdb) ---- linked server --------->|   truth)       |
 +---------------------------+   read rows in        +----------------+
```

## Status

Version 0.1.0, early. What has actually been run:

| Piece | State |
|---|---|
| SQL Server 2025 on `ortussolutions/commandbox:3.24.0` (Ubuntu 24.04) | Built and run on Docker Desktop |
| Bootstrap: database, login, linked server, SQL files | Run, including the failure paths |
| Table copy over the linked server (export, create, `INSERT ... SELECT`) | Run against a SQL Server 2019 central server: 31 tables, 210,000 rows, 28 seconds |
| AWS Fargate | Not yet run |
| Lucee datasource, `qb` QueryBuilder and SchemaBuilder against the local database | Run |
| ColdBox module (`LocalQB@cb-localdb`) | Written, not yet exercised in an app |
| PostgreSQL engine | Archived notes only, see [docker/postgres/NOTES.md](docker/postgres/NOTES.md) |

## Quick start

### 1. Dockerfile

Pass this repository to the build as a named context, so the same Dockerfile works from a local clone or straight from GitHub:

```bash
docker build --build-context localdb=https://github.com/Daemach/cb-localdb.git#v0.1.0 -t my-app .
# or, from a local clone
docker build --build-context localdb=../cb-localdb -t my-app .
```

```dockerfile
FROM ortussolutions/commandbox:3.24.0

# install.sh on its own keeps the 2 GB SQL Server layer cached
COPY --from=localdb docker/mssql/install.sh /opt/localdb/install.sh
RUN ACCEPT_EULA=Y /opt/localdb/install.sh
COPY --from=localdb docker/mssql/ /opt/localdb/

COPY ./ $APP_DIR
RUN box install --production
RUN $BUILD_DIR/util/warmup-server.sh
ENV FINALIZE_STARTUP=true
RUN $BUILD_DIR/run.sh

ENV ACCEPT_EULA=Y
ENTRYPOINT ["/__cacert_entrypoint.sh", "/opt/localdb/entrypoint.sh"]
# Setting ENTRYPOINT clears the base image's CMD, so restate it
CMD ["/bin/sh", "-c", "$BUILD_DIR/run.sh"]
```

`ACCEPT_EULA=Y` is yours to set: it accepts Microsoft's SQL Server license. Both scripts refuse to run without it.

### 2. Settings

| Setting | Default | Meaning |
|---|---|---|
| `LOCALDB_ENABLED` | `true` | `false` skips SQL Server and just starts the app |
| `LOCALDB_NAME` | `localdb` | Database to create |
| `LOCALDB_USER`, `LOCALDB_PASSWORD` | required | Login your app's datasource uses. Made `db_owner` of the database |
| `LOCALDB_EDITION` | `Developer` | `MSSQL_PID`: `Developer`, `Express`, `Standard`, `Enterprise` or a product key |
| `LOCALDB_MEMORY_MB` | 80% of the container | Memory cap for SQL Server. Set it, or it competes with the JVM heap |
| `LOCALDB_LISTEN` | `127.0.0.1` | Bind address. `0.0.0.0` lets you connect from outside to inspect a run |
| `LOCALDB_PORT` | `1433` | |
| `LOCALDB_SA_PASSWORD` | generated | Only the entrypoint uses `sa` |
| `LOCALDB_LINK_NAME` | none | Create a linked server with this name |
| `LOCALDB_LINK_HOST`, `LOCALDB_LINK_PORT` | required with a link, `1433` | Central server |
| `LOCALDB_LINK_USER`, `LOCALDB_LINK_PASSWORD` | required with a link | SQL login on the central server. Read access is enough for copying rows in |
| `LOCALDB_LINK_TRUST_CERT` | `false` | `true` encrypts the link without verifying the central server's certificate. Needed for self-signed certificates. Without it SQL Server 2025 requires a certificate it can verify |
| `LOCALDB_SQL_DIRS` | none | Extra directories of `*.sql` to run against the database, colon separated, each in name order |
| `LOCALDB_START_TIMEOUT` | `180` | Seconds to wait for SQL Server |
| `LOCALDB_CONFIG` | `$APP_DIR/localdb.conf.sh` | Optional bash file sourced before the settings are read |

**Where the settings come from.** Give them as ordinary environment variables, or put them in your app's `.env`. When the image is built with `FINALIZE_STARTUP`, CommandBox resolves `.env` at build time and writes every key into its startup script as a shell export. The entrypoint imports those exports first, so one `.env` feeds both bash and the JVM and there is no second env file to keep in step. Two consequences of that CommandBox behaviour worth knowing:

- A key that is in the build-time `.env` cannot be overridden by a container environment variable at run time.
- `.env` is parsed as a Java properties file. A backslash is an escape character, a trailing backslash joins the next line, and quotes are kept as part of the value.

If your app already has keys for these values under other names, map them in `localdb.conf.sh` instead of duplicating them:

```bash
LOCALDB_NAME="${MYAPP_SCRATCH_DATABASE}"
LOCALDB_USER="${MYAPP_SCRATCH_USER}"
LOCALDB_PASSWORD="${MYAPP_SCRATCH_PASSWORD}"
LOCALDB_LINK_NAME=central
LOCALDB_LINK_HOST="${MYAPP_DB_HOST}"
```

### 3. Datasource

Define a datasource for `127.0.0.1` with `LOCALDB_NAME`, `LOCALDB_USER` and `LOCALDB_PASSWORD`, the same way you define your others (`.cfconfig.json` or `Application.cfc`). With CommandBox, `.cfconfig.json` placeholders are also resolved at build time, so the password the datasource was built with and the one the entrypoint creates the login with must come from the same `.env` key.

### 4. ColdBox

```bash
box install cb-localdb
```

```js
// config/ColdBox.cfc
moduleSettings = { "cb-localdb" : { datasource : "localdb" } };
```

```js
component {

	property name="qb"  inject="provider:QueryBuilder@qb";
	property name="qb2" inject="provider:LocalQB@cb-localdb";
	property name="sb2" inject="provider:LocalSB@cb-localdb";

	function crunch( required array accountIDs ) {
		// pull the rows this job needs across the linked server, once
		qb2.table( "trades" ).insertUsing( ( q ) => {
			q.from( "central.Sales.dbo.trades" ).whereIn( "accountID", accountIDs );
		} );

		// hammer the local copy as hard as you like
		var totals = qb2.from( "trades" ).selectRaw( "accountID, sum( qty * price ) as total" ).groupBy( "accountID" ).get();

		// write the small result back to the central server
		qb.table( "Sales.dbo.accountTotals" ).insert( totals );
	}

}
```

## What the entrypoint does

1. Imports settings (see above). Stops with a clear message if a required one is missing.
2. Starts SQL Server as the `mssql` user and waits until it accepts connections.
3. Creates the database in simple recovery, and the login as `db_owner`.
4. If `LOCALDB_LINK_NAME` is set, creates the linked server and runs a query through it as your app's login, not as `sa`. A link the app cannot use stops the container.
5. Runs every `*.sql` in `docker/mssql/sql`, then in each `LOCALDB_SQL_DIRS` directory. A failing script stops the container.
6. Starts the container command (CommandBox) and supervises both. If either SQL Server or the app exits, the other is stopped and the container exits non-zero, so your orchestrator replaces it. An app never keeps running against a dead database.

Every step logs with elapsed time, prefixed `[localdb]`. On a laptop the database is ready about 20 seconds after the container starts.

Everything is idempotent: restarting the same container re-applies the bootstrap over the existing data.

## Copying tables

`docker/mssql/sql` ships `sproc_createTableFromJson`. Paired with `sp_exportTableConfigToJSON` on the central server (install [docker/mssql/source/sp_exportTableConfigToJSON.sql](docker/mssql/source/sp_exportTableConfigToJSON.sql) there, in `master`), it recreates a central table locally with its columns, identity, computed columns, defaults and indexes:

```sql
declare @t table ( jsonOutput nvarchar( max ) );
insert @t exec ( 'exec master.dbo.sp_exportTableConfigToJSON @fullTableName = ''Sales.dbo.trades''' ) at central;
declare @json nvarchar( max ) = ( select top 1 jsonOutput from @t );
exec dbo.sproc_createTableFromJson @json = @json;   -- creates dbo.Sales_dbo_trades

insert into dbo.Sales_dbo_trades ( accountID, tradeDate, qty, price )
select accountID, tradeDate, qty, price from central.Sales.dbo.trades where accountID in ( 1, 2, 3 );
```

`sproc_createTableFromJson` drops the table first if it already exists. If two threads can create the same table, serialize them (a named `cflock` around "check, then create" is enough inside one container).

## Things to know before you rely on it

- **The database is disposable.** Nothing in it survives the container. Treat it as a cache of the central server plus working space, and write results back.
- **It is private.** Two containers do not see each other's tables. Anything a job needs must be loaded in the container that runs it.
- **Editions and licensing.** `Developer` is licensed for development and test only. `Express` is free for production but capped (database size, about 1.4 GB of buffer pool, 4 cores). Production use of other editions needs a license from Microsoft.
- **Linked servers are SQL Server to SQL Server only** on Linux, with SQL logins. Distributed transactions are not available: plain `INSERT ... SELECT` from the link works, a remote write inside a local transaction does not.
- **Image size.** SQL Server adds about 2 GB.
- **Base image.** Tested on `ortussolutions/commandbox:3.24.0`. Microsoft publishes SQL Server 2025 packages for Ubuntu 22.04 and 24.04 only, so pin the tag. `install.sh` stops with a clear message on anything else.
- **Secrets.** CommandBox writes `.env` values into the image's startup script in plain text. That is CommandBox behaviour, not this module's, but it means the image itself is a secret.

## PostgreSQL

An earlier version of this idea ran PostgreSQL with `tds_fdw` in place of linked servers. It worked and was fragile. The scripts and an honest account of the workarounds are archived in [docker/postgres](docker/postgres/NOTES.md). They are not wired into the build. The ColdBox side already allows for it: set `grammar : "PostgresGrammar@qb"` in the module settings.

## License

MIT
