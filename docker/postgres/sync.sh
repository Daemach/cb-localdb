#!/usr/bin/env bash
# ARCHIVED REFERENCE (cb-localdb, PostgreSQL experiment, Feb 2025). Not built or tested by this package; see NOTES.md.
# Original name: docker-syncPostgres.sh (called by the entrypoint from /app).
# Changes: the S3 bucket is now ${LOCALDB_SYNC_BUCKET} (was a fixed, environment-suffixed bucket name),
# the local database name variable is now LOCALDB_NAME.
# Input:  /tmp/s3import/<db>_<schema>_<table>_YYYYMMDD_HHMMSS.csv (pipe-delimited, header row)
#         /tmp/s3import/<db>_<schema>_<table>_YYYYMMDD_HHMMSS.json (table definition, UTF-16LE)
# Output: public.<db>_<schema>_<table> dropped, recreated and loaded, once per CSV file.
set -e

S3_PATH="s3://${LOCALDB_SYNC_BUCKET}/syncData/csv"
mkdir -p /tmp/s3import
echo "Local folder: /tmp/s3import"
echo "S3 Path: $S3_PATH"

# Download missing CSV files
localFiles=$(ls /tmp/s3import/*.csv 2>/dev/null | xargs -n1 basename 2>/dev/null || true)
remoteFiles=$(aws s3 ls "$S3_PATH/" | awk '{print $4}')
diffFiles=$(comm -13 <(echo "$localFiles" | sort) <(echo "$remoteFiles" | sort))
for file in $diffFiles; do
  echo "Downloading new file: $file"
  aws s3 cp "$S3_PATH/$file" "/tmp/s3import/$file"
done

allFilesDesc=$(ls /tmp/s3import/*.csv 2>/dev/null | sort -r || true)
allFiles=$(echo "$allFilesDesc" | tac)

echo "----------------------------------"
echo "Loading files into Postgres in chronological order..."

# Load create_table_from_json (and other helper functions) into DB
echo "Loading create_table_from_json function..."
su postgres -c "psql -d ${LOCALDB_NAME} -f /app/resources/database/sprocs/create_table_from_json.sql"

for filepath in $allFiles; do
  filename=$(basename "$filepath")
  # Remove _YYYYMMDD_HHMMSS + extension, to lowercase
  table_name=$(echo "$filename" | sed -E 's/_[0-9]{8}_[0-9]{6}\.(csv|json)$//' | tr '[:upper:]' '[:lower:]')

  echo "Ensuring table $table_name exists..."
  schema_file=$(ls /tmp/s3import/${table_name}*.[jJ][sS][oO][nN] 2>/dev/null | sort | head -n 1)
  if [ -n "$schema_file" ]; then
    # Convert from UTF-16LE to UTF-8, remove nulls, fix T-SQL double single-quotes
    set +e
    schema_json_fixed=$(
      iconv -f UTF-16LE -t UTF-8 "$schema_file" 2>/dev/null \
        | tr -d '\000' \
        | sed -E "s/''/\"/g" \
        | jq -crM '.' 2>/dev/null
    )
    rc=$?
    set -e

    if [ $rc -ne 0 ] || [ -z "$schema_json_fixed" ]; then
      echo "WARNING: Could not parse $schema_file as valid JSON after cleanup. Skipping table creation."
    else
      # Write the SQL call to a temp file
      temp_sql=$(mktemp)
      chmod 644 "$temp_sql"

      # Remove literal '$$' to avoid breaking $$ string in Postgres
      sanitized=$(echo "$schema_json_fixed" | sed 's/\$\$//g')
      echo "SELECT create_table_from_json(\$\$${sanitized}\$\$);" > "$temp_sql"

      echo "Executing table creation from: $temp_sql"
      su postgres -c "psql -d ${LOCALDB_NAME} -f \"$temp_sql\"" || {
        echo "WARNING: create_table_from_json failed. Table might not exist."
      }
      rm -f "$temp_sql"
    fi
  else
    echo "WARNING: No schema file found for $table_name. Table creation might fail."
  fi

  echo "Loading $filename into table: $table_name"

  # --- Build a dynamic COPY statement using the CSV header ---
  # Read first line (header) and remove carriage returns
  header=$(head -n 1 "$filepath" | tr -d '\r\n')
  # Remove any existing quotes from the CSV header
  header_no_quotes=$(echo "$header" | sed 's/"//g')

# Build the column list for \copy by splitting the header on '|'
copy_columns=$(echo "$header_no_quotes" | awk -F'|' '{
    for (i = 1; i <= NF; i++) {
        # Trim leading/trailing whitespace
        gsub(/^[ \t]+|[ \t]+$/, "", $i);
        # Wrap column names in quotes to preserve case and special chars
        printf "\"%s\"", $i;
        # Separate with a comma for the list
        if (i < NF) {
            printf ",";
        }
    }
}')

echo "Dynamic column list for COPY: (${copy_columns})"

# Create a temporary SQL file for the \copy command
copy_sql=$(mktemp)
chmod 644 "$copy_sql"

# \copy in psql requires the delimiter option (DELIMITER '|') to be
# specified directly, not in a WITH() clause
cat <<EOF > "$copy_sql"
\\copy public.${table_name} (${copy_columns}) \
    FROM '${filepath}' CSV HEADER DELIMITER '|'
EOF

  # If table creation failed or table doesn't exist, the copy will fail
  su postgres -c "psql -d ${LOCALDB_NAME} -f \"$copy_sql\"" || {
    echo "WARNING: COPY failed. Table or columns might not match."
  }
  rm -f "$copy_sql"

  echo "Done loading $filename"

  echo "Verifying row count in $table_name..."
  row_count=$(su postgres -c "psql -qtA -d ${LOCALDB_NAME} -c \"SELECT COUNT(*) FROM ${table_name};\" 2>/dev/null" || echo "0")
  echo "Current row count in $table_name is: $row_count"
  echo "----------------------------------"
done

echo "All CSV files processed."
exec "$@"
