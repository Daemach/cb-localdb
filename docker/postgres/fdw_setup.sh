#!/bin/bash
# ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment, Feb 2025). Not built or tested by this package; see NOTES.md.
# Original name: fdw_setup.sh. Only change: the local database name variable is now LOCALDB_NAME.
#
# fdw_setup.sh
# This script configures FDW connections based on a related JSON configuration file.
# It expects the following environment variables to be set:
#   - FDW_CONNECTIONS_FILE (path to the JSON file)
#   - FDW_DEFAULT_DB_HOST, FDW_DEFAULT_DB_PORT, FDW_DEFAULT_DB_USER, FDW_DEFAULT_DB_PASSWORD
#   - LOCALDB_NAME

if [ -z "${FDW_CONNECTIONS_FILE}" ]; then
    echo "FDW_CONNECTIONS_FILE is not set. Exiting."
    exit 0
fi

if [ ! -f "${FDW_CONNECTIONS_FILE}" ]; then
    echo "FDW configuration file not found at ${FDW_CONNECTIONS_FILE}. Exiting."
    exit 0
fi


if ! command -v jq &> /dev/null; then
  echo "jq is required but not installed. Exiting."
  exit 0
fi

connection_count=$(jq '.connections | length' "${FDW_CONNECTIONS_FILE}")
if [ "$connection_count" -eq "0" ]; then
    echo "No FDW connections defined in ${FDW_CONNECTIONS_FILE}. Nothing to do."
    exit 0
fi

echo "Creating foreign data wrapper connections to mssql"

su postgres -c "psql -d ${LOCALDB_NAME} -c \"CREATE EXTENSION IF NOT EXISTS tds_fdw;\""

create_fdw_and_import() {
  local db_name="$1"
  local schema_mappings="$2"
  local server_name="${3:-$db_name}"
  local db_host="${4:-$FDW_DEFAULT_DB_HOST}"
  local db_port="${5:-$FDW_DEFAULT_DB_PORT}"
  local db_user="${6:-$FDW_DEFAULT_DB_USER}"
  local db_password="${7:-$FDW_DEFAULT_DB_PASSWORD}"

  echo "------------------------------------------------------------"
  echo "Configuring FDW mappings for server '${server_name}'"
  echo "DB:     ${db_name}"
  echo "Host:   ${db_host}"
  echo "Port:   ${db_port}"
  echo "User:   ${db_user}"
  echo "------------------------------------------------------------"

: ${LOCALDB_NAME:='postgres'}


su postgres -c "psql -d ${LOCALDB_NAME} -c \"\
  CREATE SERVER IF NOT EXISTS ${server_name}
  FOREIGN DATA WRAPPER tds_fdw
  OPTIONS (
    servername '${db_host}',
    port       '${db_port}',
    database   '${db_name}',
    language   'us_english',
    tds_version '7.4'
  );\""

  su postgres -c "psql -d ${LOCALDB_NAME} -c \"\
    CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER
    SERVER ${server_name}
    OPTIONS (
      username '${db_user}',
      password '${db_password}'
    );\""

  if [ -n "${schema_mappings}" ]; then
    IFS=',' read -ra SCHEMA_MAPS <<< "${schema_mappings}"
    for mapping in "${SCHEMA_MAPS[@]}"; do
        remote_schema="$(echo $mapping | cut -d':' -f1)"
        local_schema="$(echo $mapping | cut -d':' -f2)"
        echo "Importing remote schema '${remote_schema}' into local schema '${local_schema}'..."

        su postgres -c "psql -d ${LOCALDB_NAME} -c \"CREATE SCHEMA IF NOT EXISTS ${local_schema};\""
        su postgres -c "psql -d ${LOCALDB_NAME} -c \"\
          IMPORT FOREIGN SCHEMA ${remote_schema}
          FROM SERVER ${server_name}
          INTO ${local_schema};\""
    done
  else
    echo "No schema mappings provided for '${server_name}'. Skipping schema import."
  fi
}

connections=$(jq -c '.connections[]' "${FDW_CONNECTIONS_FILE}")

for conn in $connections; do
    db_name=$(echo "$conn" | jq -r '.db_name')
    schema_mappings=$(echo "$conn" | jq -r '.schema_mappings // ""')
    server_name=$(echo "$conn" | jq -r '.server_name // empty')
    server_name=${server_name:-$db_name}
    db_host=$(echo "$conn" | jq -r '.db_host // empty')
    db_host=${db_host:-$FDW_DEFAULT_DB_HOST}
    db_port=$(echo "$conn" | jq -r '.db_port // empty')
    db_port=${db_port:-$FDW_DEFAULT_DB_PORT}
    db_user=$(echo "$conn" | jq -r '.db_user // empty')
    db_user=${db_user:-$FDW_DEFAULT_DB_USER}
    db_password=$(echo "$conn" | jq -r '.db_password // empty')
    db_password=${db_password:-$FDW_DEFAULT_DB_PASSWORD}

    create_fdw_and_import "$db_name" "$schema_mappings" "$server_name" "$db_host" "$db_port" "$db_user" "$db_password"
done
