#!/usr/bin/env bash
# cb-localdb: run a private SQL Server beside the app (container start, as root).
# In:  LOCALDB_* settings (README). With a finalized CommandBox startup script, the .env
#      values CommandBox baked into it are imported first, so one .env feeds bash and Java.
# Out: SQL Server running, database + app login + optional linked server created, every
#      sql/*.sql applied; then the container command runs. Either process exiting stops both.
set -euo pipefail

started=$SECONDS
log() { echo "[localdb] $(date -u +%H:%M:%S) +$(( SECONDS - started ))s $*"; }
die() { log "FATAL: $*"; exit 1; }

final="${BIN_DIR:-/usr/local/bin}/startup-final.sh"
if [ -f "$final" ]; then
  eval "$(grep -E "^export [A-Za-z_][A-Za-z0-9_]*='.*'\$" "$final" || true)"
fi
config="${LOCALDB_CONFIG:-${APP_DIR:-/app}/localdb.conf.sh}"
if [ -f "$config" ]; then . "$config"; fi

if [ "${LOCALDB_ENABLED:-true}" != "true" ]; then
  log "LOCALDB_ENABLED=${LOCALDB_ENABLED}; starting the app without a local database"
  exec "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${LOCALDB_NAME:-localdb}"
user="${LOCALDB_USER:-}"
port="${LOCALDB_PORT:-1433}"
link="${LOCALDB_LINK_NAME:-}"

ident() { [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$1 must be a plain identifier, got '$2'"; }
lit() { printf "%s" "${1//\'/\'\'}"; }

[ "${ACCEPT_EULA:-}" = "Y" ] || die "ACCEPT_EULA=Y is required to run SQL Server"
ident LOCALDB_NAME "$name"
[ -n "$user" ] && [ -n "${LOCALDB_PASSWORD:-}" ] || die "LOCALDB_USER and LOCALDB_PASSWORD are required"
ident LOCALDB_USER "$user"

export ACCEPT_EULA
# sa is only used by this script; SQL Server applies the password on first start only, so a
# generated one is kept beside the data for restarts of the same container
saFile=/var/opt/mssql/.localdb-sa
mkdir -p /var/opt/mssql
if [ -n "${LOCALDB_SA_PASSWORD:-}" ]; then
  MSSQL_SA_PASSWORD="$LOCALDB_SA_PASSWORD"
else
  [ -f "$saFile" ] || ( umask 077; echo "Aa1_$(openssl rand -hex 16)" > "$saFile" )
  MSSQL_SA_PASSWORD="$(cat "$saFile")"
fi
export MSSQL_SA_PASSWORD
export MSSQL_PID="${LOCALDB_EDITION:-Developer}"
export MSSQL_TCP_PORT="$port"
export MSSQL_IP_ADDRESS="${LOCALDB_LISTEN:-127.0.0.1}"
if [ -n "${LOCALDB_MEMORY_MB:-}" ]; then export MSSQL_MEMORY_LIMIT_MB="$LOCALDB_MEMORY_MB"; fi

sql() { SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S "127.0.0.1,${port}" -U sa -C -b -I -x "$@"; }
appSql() { SQLCMDPASSWORD="$LOCALDB_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S "127.0.0.1,${port}" -U "$user" -d "$name" -C -b -I -x "$@"; }

log "starting SQL Server (${MSSQL_PID}) on ${MSSQL_IP_ADDRESS}:${port}"
chown -R mssql /var/opt/mssql
if [ -f "$saFile" ]; then chown root "$saFile"; fi
HOME=/var/opt/mssql setpriv --reuid=mssql --regid=mssql --init-groups /opt/mssql/bin/sqlservr </dev/null &
dbPid=$!

timeout="${LOCALDB_START_TIMEOUT:-180}"
until sql -l 2 -Q "set nocount on; select 1" >/dev/null 2>&1; do
  kill -0 "$dbPid" 2>/dev/null || die "SQL Server exited during startup"
  [ $(( SECONDS - started )) -lt "$timeout" ] || die "SQL Server not accepting connections after ${timeout}s"
  sleep 1
done
log "SQL Server accepting connections"

sql <<SQL || die "could not create database '${name}' and login '${user}'"
if db_id( N'${name}' ) is null create database [${name}];
go
alter database [${name}] set recovery simple;
go
if suser_id( N'${user}' ) is null
  create login [${user}] with password = N'$(lit "$LOCALDB_PASSWORD")', check_policy = off, default_database = [${name}];
else
  alter login [${user}] with password = N'$(lit "$LOCALDB_PASSWORD")', check_policy = off, default_database = [${name}];
go
use [${name}];
if database_principal_id( N'${user}' ) is null create user [${user}] for login [${user}];
alter role db_owner add member [${user}];
go
SQL
log "database '${name}' ready, login '${user}' is db_owner"

if [ -n "$link" ]; then
  ident LOCALDB_LINK_NAME "$link"
  [ -n "${LOCALDB_LINK_HOST:-}" ] && [ -n "${LOCALDB_LINK_USER:-}" ] && [ -n "${LOCALDB_LINK_PASSWORD:-}" ] \
    || die "LOCALDB_LINK_NAME is set, so LOCALDB_LINK_HOST, LOCALDB_LINK_USER and LOCALDB_LINK_PASSWORD are required"
  # SQL Server 2025 linked servers verify the remote certificate unless told otherwise. With a
  # provider string, a login that is not sysadmin is refused (Msg 7416) unless it names the remote user.
  provstr=""
  if [ "${LOCALDB_LINK_TRUST_CERT:-false}" = "true" ]; then
    [[ "$LOCALDB_LINK_USER" != *";"* ]] || die "LOCALDB_LINK_USER must not contain ';'"
    provstr="Encrypt=yes;TrustServerCertificate=yes;User ID=$(lit "$LOCALDB_LINK_USER");"
  fi
  sql <<SQL || die "could not define linked server '${link}' -> ${LOCALDB_LINK_HOST}"
if exists ( select 1 from sys.servers where name = N'${link}' ) exec sp_dropserver N'${link}', 'droplogins';
exec sp_addlinkedserver @server = N'${link}', @srvproduct = N'', @provider = N'MSOLEDBSQL',
  @datasrc = N'$(lit "${LOCALDB_LINK_HOST},${LOCALDB_LINK_PORT:-1433}")', @provstr = N'${provstr}';
exec sp_addlinkedsrvlogin @rmtsrvname = N'${link}', @useself = 'False', @locallogin = null,
  @rmtuser = N'$(lit "$LOCALDB_LINK_USER")', @rmtpassword = N'$(lit "$LOCALDB_LINK_PASSWORD")';
exec sp_serveroption N'${link}', 'rpc', 'true';
exec sp_serveroption N'${link}', 'rpc out', 'true';
exec sp_serveroption N'${link}', 'remote proc transaction promotion', 'false';
go
SQL
  # as the app login: it is the one that has to get through
  appSql <<SQL || die "linked server '${link}' -> ${LOCALDB_LINK_HOST} is not usable by '${user}' (see error above; a self-signed certificate needs LOCALDB_LINK_TRUST_CERT=true)"
set nocount on;
select 'linked server ${link} reaches ' + name + ' (' + version + ')'
from openquery( [${link}], 'select @@servername as name, cast( serverproperty( ''ProductVersion'' ) as varchar( 32 ) ) as version' );
go
SQL
  log "linked server '${link}' -> ${LOCALDB_LINK_HOST} verified as '${user}'"
fi

applied=0
IFS=':' read -ra sqlDirs <<< "${here}/sql${LOCALDB_SQL_DIRS:+:${LOCALDB_SQL_DIRS}}"
for dir in "${sqlDirs[@]}"; do
  [ -d "$dir" ] || die "sql directory not found: $dir"
  for file in "$dir"/*.sql; do
    [ -f "$file" ] || continue
    sql -d "$name" -i "$file" >/dev/null || die "failed applying $file"
    applied=$(( applied + 1 ))
  done
done
log "local database ready: ${applied} sql file(s) applied; starting the app"

stopping=false
stop() { stopping=true; kill -TERM -- "-$appPid" "$dbPid" 2>/dev/null || true; }
trap stop TERM INT

setsid "$@" &
appPid=$!

set +e
wait -n "$appPid" "$dbPid"
rc=$?
if [ "$stopping" = false ]; then
  if kill -0 "$dbPid" 2>/dev/null; then log "the app exited (rc=${rc}); stopping SQL Server"; else log "SQL Server exited (rc=${rc}); stopping the app"; fi
  [ "$rc" -ne 0 ] || rc=1
  stop
fi
wait
exit "$rc"
