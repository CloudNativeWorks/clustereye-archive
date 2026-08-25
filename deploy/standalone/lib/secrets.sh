#!/usr/bin/env bash
# secrets.sh — Generate and manage secrets for ClusterEye API

readonly SECRETS_FILE="/etc/clustereye/secrets.env"

secrets::generate() {
  log::step "Managing secrets"

  if [[ -f "$SECRETS_FILE" ]]; then
    log::info "Existing secrets.env found — preserving cryptographic keys"
    # Preserve existing keys, update DB/InfluxDB fields if needed
    return 0
  fi

  log::info "Generating new cryptographic keys..."

  local jwt_secret api_secret encryption_key
  jwt_secret=$(rand_hex 16)
  api_secret=$(rand_hex 16)
  encryption_key=$(rand_hex 16)

  cat > "${SECRETS_FILE}.tmp" <<EOF
# ClusterEye API Secrets
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# WARNING: Do not share or commit this file.

# Cryptographic keys (do not change after initial setup)
JWT_SECRET_KEY=${jwt_secret}
API_SECRET_KEY=${api_secret}
ENCRYPTION_KEY=${encryption_key}

# Database connection
DB_HOST=
DB_PORT=5432
DB_USER=
DB_PASSWORD=
DB_NAME=clustereye
DB_SSLMODE=disable

# InfluxDB connection
INFLUXDB_ENABLED=false
INFLUXDB_URL=
INFLUXDB_TOKEN=
INFLUXDB_ORG=clustereye
INFLUXDB_BUCKET=clustereye

# ClickHouse connection (per-query metric store)
CLICKHOUSE_ENABLED=false
CLICKHOUSE_ADDR=
CLICKHOUSE_DATABASE=clustereye
CLICKHOUSE_USERNAME=clustereye
CLICKHOUSE_PASSWORD=
EOF

  chmod 0600 "${SECRETS_FILE}.tmp" || die "Failed to set permissions on secrets file"
  chown clustereye:clustereye "${SECRETS_FILE}.tmp" || die "Failed to set ownership on secrets file"
  mv -f "${SECRETS_FILE}.tmp" "$SECRETS_FILE" || die "Failed to install secrets file"

  log::ok "Secrets generated: $SECRETS_FILE"
}

# Update specific DB fields in secrets.env (atomic, preserves other fields)
secrets::write_db_fields() {
  local host="$1" port="$2" user="$3" password="$4" dbname="$5" sslmode="$6"

  _secrets_update_field "DB_HOST" "$host"
  _secrets_update_field "DB_PORT" "$port"
  _secrets_update_field "DB_USER" "$user"
  _secrets_update_field "DB_PASSWORD" "$password"
  _secrets_update_field "DB_NAME" "$dbname"
  _secrets_update_field "DB_SSLMODE" "$sslmode"
}

# Update InfluxDB fields in secrets.env
secrets::write_influxdb_fields() {
  local url="$1" token="$2" org="$3" bucket="$4" enabled="$5"

  _secrets_update_field "INFLUXDB_URL" "$url"
  _secrets_update_field "INFLUXDB_TOKEN" "$token"
  _secrets_update_field "INFLUXDB_ORG" "$org"
  _secrets_update_field "INFLUXDB_BUCKET" "$bucket"
  _secrets_update_field "INFLUXDB_ENABLED" "$enabled"
}

# Update ClickHouse fields in secrets.env (per-query metric store).
# CLICKHOUSE_* env vars are honoured by the API (config.go), so this is
# the source of truth at runtime — server.yml carries the same values for
# operators reading the file but the env vars win when set.
secrets::write_clickhouse_fields() {
  local addr="$1" database="$2" username="$3" password="$4" enabled="$5"

  _secrets_update_field "CLICKHOUSE_ADDR" "$addr"
  _secrets_update_field "CLICKHOUSE_DATABASE" "$database"
  _secrets_update_field "CLICKHOUSE_USERNAME" "$username"
  _secrets_update_field "CLICKHOUSE_PASSWORD" "$password"
  _secrets_update_field "CLICKHOUSE_ENABLED" "$enabled"
}

_secrets_update_field() {
  local key="$1" value="$2"
  # Escape sed special characters in value
  local escaped_value
  escaped_value=$(printf '%s' "$value" | sed -e 's/[|&/\]/\\&/g')
  if grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$SECRETS_FILE"
  else
    echo "${key}=${value}" >> "$SECRETS_FILE"
  fi
}
