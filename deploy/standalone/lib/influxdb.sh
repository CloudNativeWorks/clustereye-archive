#!/usr/bin/env bash
# influxdb.sh — Install local InfluxDB, configure external, or disable

influxdb::setup() {
  log::step "Configuring InfluxDB"

  case "$CE_INFLUXDB" in
    local)    influxdb::_install_local ;;
    external) influxdb::_configure_external ;;
    none)
      secrets::write_influxdb_fields "" "" "clustereye" "clustereye" "false"
      log::ok "InfluxDB disabled"
      ;;
    *) die "Invalid --influxdb value: $CE_INFLUXDB (expected: local|external|none)" ;;
  esac
}

influxdb::_install_local() {
  log::info "Installing local InfluxDB 2.x..."

  influxdb::_ensure_package_installed
  influxdb::_ensure_service_running
  influxdb::_ensure_initial_setup
}

influxdb::_ensure_package_installed() {
  # Check if influxd binary actually exists (not just package metadata)
  local needs_install=false

  if ! command -v influxd &>/dev/null; then
    needs_install=true
  fi

  if [[ "$needs_install" == "false" ]]; then
    log::info "influxd binary found: $(command -v influxd)"
    return 0
  fi

  log::info "influxd binary not found, installing package..."

  case "$CE_OS_FAMILY" in
    debian)
      # Purge broken leftover package state first
      if dpkg -s influxdb2 &>/dev/null 2>&1; then
        log::info "Cleaning up previous influxdb2 package state..."
        DEBIAN_FRONTEND=noninteractive dpkg --remove --force-remove-reinstreq influxdb2 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -f -qq 2>/dev/null || true
      fi

      # Clean up stale repo/key files
      rm -f /etc/apt/trusted.gpg.d/influxdata-archive*.gpg
      rm -f /etc/apt/keyrings/influxdata-archive*.gpg
      rm -f /etc/apt/sources.list.d/influxdata.list

      # Import GPG key (official InfluxData method)
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://repos.influxdata.com/influxdata-archive.key \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/influxdata-archive.gpg 2>/dev/null

      # Official unified repo — works for all Ubuntu/Debian versions
      echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" \
        > /etc/apt/sources.list.d/influxdata.list

      apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/influxdata.list \
        -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
      apt::install influxdb2 influxdb2-cli

      # Verify install succeeded
      if ! command -v influxd &>/dev/null; then
        # Check where the package put it
        local pkg_binary
        pkg_binary=$(dpkg -L influxdb2 2>/dev/null | grep -E '(influxd$|influxd-systemd-start)' | head -1 || true)
        if [[ -n "$pkg_binary" ]]; then
          log::info "influxd found via dpkg -L: $pkg_binary"
        else
          die "InfluxDB package installed but influxd binary not found. Check: dpkg -L influxdb2"
        fi
      fi
      ;;
    rhel)
      if ! rpm -q influxdb2 &>/dev/null; then
        cat > /etc/yum.repos.d/influxdata.repo <<'REPO'
[influxdata]
name=InfluxData Repository - Stable
baseurl=https://repos.influxdata.com/stable/$basearch/main
enabled=1
gpgcheck=1
gpgkey=https://repos.influxdata.com/influxdata-archive.key
REPO
        dnf install -y -q influxdb2 influxdb2-cli
      fi

      if ! command -v influxd &>/dev/null; then
        die "InfluxDB package installed but influxd binary not found"
      fi
      ;;
  esac

  log::ok "InfluxDB package installed"
}

influxdb::_ensure_service_running() {
  systemctl daemon-reload

  # Find the service — check files on disk, not just systemctl list
  local svc_name=""
  local svc_locations=(
    /lib/systemd/system/influxdb.service
    /usr/lib/systemd/system/influxdb.service
    /etc/systemd/system/influxdb.service
    /lib/systemd/system/influxdb2.service
    /usr/lib/systemd/system/influxdb2.service
  )

  for loc in "${svc_locations[@]}"; do
    if [[ -f "$loc" ]]; then
      svc_name=$(basename "$loc" .service)
      log::info "Found service file: $loc"
      break
    fi
  done

  # No service file found — create one
  if [[ -z "$svc_name" ]]; then
    log::warn "No InfluxDB service file found, creating one..."

    local influxd_exec=""
    local svc_type="simple"

    # Search for the executable in order of preference
    local search_paths=(
      /usr/lib/influxdb/scripts/influxd-systemd-start.sh
      /usr/bin/influxd
      /usr/local/bin/influxd
    )

    for p in "${search_paths[@]}"; do
      if [[ -x "$p" ]]; then
        influxd_exec="$p"
        break
      fi
    done

    # Last resort: find from dpkg
    if [[ -z "$influxd_exec" ]]; then
      influxd_exec=$(dpkg -L influxdb2 2>/dev/null | grep -E 'influxd-systemd-start\.sh$' | head -1 || true)
      if [[ -z "$influxd_exec" ]]; then
        influxd_exec=$(dpkg -L influxdb2 2>/dev/null | grep -E '/influxd$' | head -1 || true)
      fi
    fi

    if [[ -z "$influxd_exec" ]]; then
      die "Cannot locate influxd executable. Check: dpkg -L influxdb2 | grep influxd"
    fi

    if [[ "$influxd_exec" == *"systemd-start.sh"* ]]; then
      svc_type="forking"
    fi

    # Ensure influxdb user exists
    if ! getent passwd influxdb &>/dev/null; then
      useradd --system --home-dir /var/lib/influxdb --no-create-home --shell /usr/sbin/nologin influxdb 2>/dev/null || true
    fi

    cat > /etc/systemd/system/influxdb.service <<UNIT
[Unit]
Description=InfluxDB 2.x
After=network-online.target
Wants=network-online.target

[Service]
Type=${svc_type}
User=influxdb
Group=influxdb
EnvironmentFile=-/etc/default/influxdb2
ExecStart=${influxd_exec}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    svc_name="influxdb"
    log::info "Created service file with ExecStart=${influxd_exec} (Type=${svc_type})"
  fi

  # Ensure data directory exists with correct ownership
  mkdir -p /var/lib/influxdb
  chown influxdb:influxdb /var/lib/influxdb 2>/dev/null || true

  systemctl enable "$svc_name" 2>/dev/null || true
  systemctl start "$svc_name" || die "Failed to start InfluxDB ($svc_name). Check: journalctl -u $svc_name"

  # Wait for InfluxDB to be ready
  if ! wait_for_tcp 127.0.0.1 8086 30; then
    log::err "InfluxDB did not respond on port 8086 within 30s"
    log::err "$(systemctl status "$svc_name" 2>&1 | head -15)"
    die "InfluxDB failed to start. Check: journalctl -u $svc_name"
  fi

  log::ok "InfluxDB is running ($svc_name)"
}

readonly INFLUX_LOCAL_URL="http://localhost:8086"
readonly INFLUX_DATA_DIR="/var/lib/influxdb"
# Same resolution as the influx CLI: $INFLUX_CONFIGS_PATH, else ~/.influxdbv2/configs.
readonly INFLUX_CLI_CONFIGS="${INFLUX_CONFIGS_PATH:-${HOME:-/root}/.influxdbv2/configs}"

# influxdb::_token_valid <token> — true if the token can read the clustereye org.
influxdb::_token_valid() {
  [[ -n "$1" ]] || return 1
  curl -sf -H "Authorization: Token $1" "${INFLUX_LOCAL_URL}/api/v2/orgs" 2>/dev/null \
    | grep -q '"clustereye"'
}

# Token saved in root's influx CLI config (default profile), if any. With
# token hashing enabled this is the only place a raw token can still be read
# back — `influx auth list` returns REDACTED.
influxdb::_cli_config_token() {
  [[ -f "$INFLUX_CLI_CONFIGS" ]] || return 0
  # Prefer the active profile's token; fall back to the first token in the file.
  awk '
    function flush() { if (tok != "") { if (first == "") first = tok; if (act && best == "") best = tok } }
    /^\[/ { flush(); tok = ""; act = 0; next }
    /^[ \t]*token[ \t]*=/ { t = $0; sub(/^[^=]*=[ \t]*/, "", t); gsub(/"/, "", t); tok = t }
    /^[ \t]*active[ \t]*=[ \t]*true/ { act = 1 }
    END { flush(); print (best != "" ? best : first) }
  ' "$INFLUX_CLI_CONFIGS" 2>/dev/null || true
}

# Move the existing data directory aside (never delete) so a fresh setup can run.
influxdb::_reset_data_dir() {
  local backup
  backup="${INFLUX_DATA_DIR}.reset-$(date -u +%Y%m%dT%H%M%SZ)"
  log::warn "--influxdb-reset: moving existing InfluxDB data to ${backup}"
  systemctl stop influxdb 2>/dev/null || true
  mkdir -p "$backup"
  find "$INFLUX_DATA_DIR" -mindepth 1 -maxdepth 1 -exec mv -t "$backup" {} + \
    || die "Failed to move InfluxDB data aside"
  systemctl start influxdb 2>/dev/null || true
  wait_for_tcp 127.0.0.1 8086 30 || die "InfluxDB failed to restart after reset"
}

# Point root's influx CLI at the local instance so `influx ...` works right
# after install (setup runs over the HTTP API and never writes a CLI config).
influxdb::_configure_cli() {
  local token="$1"
  command -v influx &>/dev/null || return 0
  influx config rm clustereye >/dev/null 2>&1 || true
  if influx config create --config-name clustereye --host-url "$INFLUX_LOCAL_URL" \
      --org clustereye --token "$token" --active >/dev/null 2>&1; then
    chmod 600 "$INFLUX_CLI_CONFIGS" 2>/dev/null || true
    log::info "influx CLI configured (profile: clustereye)"
  else
    log::warn "Could not configure influx CLI profile — run 'influx config create' manually"
  fi
}

influxdb::_ensure_initial_setup() {
  local admin_password token="" existing_token cli_token needs_setup health_status
  admin_password=$(rand_hex 16)

  health_status=$(curl -sf "${INFLUX_LOCAL_URL}/health" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)
  log::info "InfluxDB health: ${health_status:-unknown}"

  # The response is pretty-printed ("allowed": true) — allow whitespace.
  local setup_status
  setup_status=$(curl -sf "${INFLUX_LOCAL_URL}/api/v2/setup" 2>/dev/null || true)
  if grep -qE '"allowed": *true' <<<"$setup_status"; then
    needs_setup="true"
  elif grep -qE '"allowed": *false' <<<"$setup_status"; then
    needs_setup="false"
  else
    die "Could not read InfluxDB setup status from ${INFLUX_LOCAL_URL}/api/v2/setup"
  fi

  if [[ "$needs_setup" != "true" ]]; then
    log::info "InfluxDB already initialized, looking for a working token..."
    existing_token=$(grep '^INFLUXDB_TOKEN=' "$SECRETS_FILE" 2>/dev/null | cut -d= -f2- || true)
    cli_token=$(influxdb::_cli_config_token)

    if influxdb::_token_valid "$existing_token"; then
      token="$existing_token"
      log::info "Using token from ${SECRETS_FILE}"
    elif influxdb::_token_valid "$cli_token"; then
      token="$cli_token"
      log::info "Using token from influx CLI config"
    elif [[ "${CE_INFLUXDB_RESET:-0}" == "1" ]]; then
      influxdb::_reset_data_dir
      needs_setup="true"
    else
      log::err "InfluxDB is already initialized but no working token was found"
      log::err "(checked INFLUXDB_TOKEN in ${SECRETS_FILE} and the influx CLI config)."
      log::err "Existing data was left untouched. To recover without data loss:"
      log::err "  systemctl stop influxdb"
      log::err "  sudo -u influxdb influxd recovery auth create-operator \\"
      log::err "    --bolt-path ${INFLUX_DATA_DIR}/influxd.bolt --org clustereye --username admin"
      log::err "  systemctl start influxdb"
      log::err "then put the printed token into INFLUXDB_TOKEN in ${SECRETS_FILE} and re-run."
      log::err "To discard the data instead (moved aside, not deleted), re-run with --influxdb-reset."
      die "InfluxDB token recovery required"
    fi
  fi

  if [[ "$needs_setup" == "true" ]]; then
    log::info "InfluxDB needs initial setup..."
    token=$(rand_hex 16)

    # Use HTTP API directly (no influx CLI dependency)
    local setup_response
    setup_response=$(curl -sf -X POST "${INFLUX_LOCAL_URL}/api/v2/setup" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"admin\",
        \"password\": \"${admin_password}\",
        \"org\": \"clustereye\",
        \"bucket\": \"clustereye\",
        \"retentionPeriodSeconds\": 259200,
        \"token\": \"${token}\"
      }" 2>&1) || true

    if echo "$setup_response" | grep -q '"auth"'; then
      log::ok "InfluxDB initial setup completed via API"
    else
      log::warn "InfluxDB setup response: $setup_response"
      # Try with influx CLI as fallback
      if command -v influx &>/dev/null; then
        influx setup --force \
          --org clustereye --bucket clustereye \
          --username admin --password "$admin_password" \
          --token "$token" --host "$INFLUX_LOCAL_URL" 2>&1 || true
      fi
    fi
  fi

  influxdb::_token_valid "$token" || die "InfluxDB token could not be verified after setup"
  log::ok "InfluxDB token verified"

  secrets::write_influxdb_fields "$INFLUX_LOCAL_URL" "$token" "clustereye" "clustereye" "true"
  influxdb::_configure_cli "$token"

  log::ok "Local InfluxDB configured (org=clustereye, bucket=clustereye)"
}

influxdb::_configure_external() {
  local url="${CE_INFLUXDB_URL:-CHANGE_ME}"
  local token="${CE_INFLUXDB_TOKEN:-CHANGE_ME}"
  local org="${CE_INFLUXDB_ORG:-clustereye}"
  local bucket="${CE_INFLUXDB_BUCKET:-clustereye}"

  secrets::write_influxdb_fields "$url" "$token" "$org" "$bucket" "true"

  if [[ "$url" == "CHANGE_ME" || "$token" == "CHANGE_ME" ]]; then
    log::warn "External InfluxDB: placeholder values written to $SECRETS_FILE"
    log::warn "Update INFLUXDB_URL and INFLUXDB_TOKEN in $SECRETS_FILE before starting the service"
  else
    log::ok "External InfluxDB configured (url=$url)"
  fi
}
