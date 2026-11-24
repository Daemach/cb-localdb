#!/usr/bin/env bash
# cb-localdb: install SQL Server + sqlcmd into a Debian/Ubuntu based image (build time, as root).
# In:  ACCEPT_EULA=Y (required, you accept Microsoft's license), MSSQL_VERSION (default 2025)
# Out: /opt/mssql/bin/sqlservr, /opt/mssql-tools18/bin/sqlcmd, user "mssql"
set -euo pipefail

[ "${ACCEPT_EULA:-}" = "Y" ] || { echo "[localdb] ACCEPT_EULA=Y is required to install SQL Server" >&2; exit 1; }
: "${MSSQL_VERSION:=2025}"
. /etc/os-release
[ "${ID}" = "ubuntu" ] || { echo "[localdb] unsupported base image: ${PRETTY_NAME} (Ubuntu only)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
repo="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}"

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg
curl -fsSL "${repo}/mssql-server-${MSSQL_VERSION}.list" -o /etc/apt/sources.list.d/mssql-server.list \
  || { echo "[localdb] Microsoft publishes no SQL Server ${MSSQL_VERSION} repository for Ubuntu ${VERSION_ID}" >&2; exit 1; }
curl -fsSL "${repo}/prod.list" -o /etc/apt/sources.list.d/mssql-prod.list
apt-get update
apt-get install -y --no-install-recommends mssql-server mssql-tools18
apt-get clean
rm -rf /var/lib/apt/lists/*

test -x /opt/mssql/bin/sqlservr && test -x /opt/mssql-tools18/bin/sqlcmd && id mssql
