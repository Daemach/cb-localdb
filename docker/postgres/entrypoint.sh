#!/usr/bin/env bash
# ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment, Feb 2025). Not built or tested by this package; see NOTES.md.
# Original name: docker-entrypoint.sh (installed as /usr/local/bin/docker-entrypoint.sh, WORKDIR /app).
# Changes: local database variables renamed to LOCALDB_NAME / LOCALDB_USER / LOCALDB_PASSWORD,
# the echo of the AWS access key id was dropped, example host/login values replaced with placeholders.
set -e

if [ -f /app/.env2 ]; then
    echo "loading environment variables from /app/.env2"
    set -a
    source /app/.env2
    set +a
fi

if [ -n "$S3_ACCESS_KEY" ]; then
  export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
fi
if [ -n "$S3_SECRET_KEY" ]; then
  export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
fi
if [ -n "$S3_REGION" ]; then
  export AWS_DEFAULT_REGION="$S3_REGION"
fi
echo "Using AWS_SECRET_ACCESS_KEY: (hidden)"
echo "Using AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"

cat <<'EOF' > /usr/local/etc/locales.conf
[default]
  date format = %b %e %Y %I:%M:%S.%z%p

[en_US]
  date format = %b %e %Y %I:%M:%S.%z%p
  language = us_english
  charset = iso_1
EOF

echo "starting Postgres"
su postgres -c "/usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/data \
  -o '-c listen_addresses=*' -l /var/lib/postgresql/logfile start" &

sleep 5

: ${LOCALDB_NAME:='postgres'}
: ${LOCALDB_USER:='postgres'}
: ${LOCALDB_PASSWORD:=''}

echo "creating default DB, user, and test table"

echo "------------------------------------------------------------"
echo "Configuring main database '${LOCALDB_NAME}'"
echo "User:   ${LOCALDB_USER}"
echo "------------------------------------------------------------"

# 1. Create the database user if it doesn't already exist.
su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${LOCALDB_USER}'\" | grep -q 1 \
  || psql -c \"CREATE USER ${LOCALDB_USER} WITH ENCRYPTED PASSWORD '${LOCALDB_PASSWORD}';\""

# 2. Create the database if it doesn't already exist.
su postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${LOCALDB_NAME}'\" | grep -q 1 \
  || psql -c \"CREATE DATABASE ${LOCALDB_NAME} OWNER ${LOCALDB_USER};\""

# 3. Create the test table in the public schema if it doesn't already exist.
su postgres -c "psql -d ${LOCALDB_NAME} -c \"CREATE TABLE IF NOT EXISTS test_table (id SERIAL PRIMARY KEY, data TEXT);\""

# 4. Insert a test row into test_table.
su postgres -c "psql -d ${LOCALDB_NAME} -c \"INSERT INTO test_table (data) VALUES ('Test data inserted on ' || current_timestamp);\""

# 5. Select from test_table and display the results.
echo "------------------------------------------------------------"
echo "Data in test_table:"
su postgres -c "psql -d ${LOCALDB_NAME} -c \"SELECT * FROM test_table;\""
echo "------------------------------------------------------------"

# 6. Additional check: Display the PostgreSQL version.
echo "PostgreSQL version:"
su postgres -c "psql -d ${LOCALDB_NAME} -c \"SELECT version();\""
echo "------------------------------------------------------------"


# schema mappings are remote:local from the perspective of postgres
# in fdw_connections.json you can override the default values for any server
# "db_host": "<central-sql-host>",
# "db_port": "1433",
# "db_user": "<sql-login>",
# "db_password": "<sql-password>"

if [ -n "${FDW_CONNECTIONS_FILE}" ] && [ -f "${FDW_CONNECTIONS_FILE}" ]; then
    echo "FDW configuration file found at ${FDW_CONNECTIONS_FILE}. executing FDW setup..."
    ./fdw_setup.sh
else
    echo "no FDW configuration file found. Skipping FDW setup."
fi

./docker-syncPostgres.sh

exec "/usr/local/bin/startup-final.sh"