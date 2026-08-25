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

  # Ensure clean state before starting — if no valid token exists,
  # wipe data so setup can run fresh
  local existing_token
  existing_token=$(grep '^INFLUXDB_TOKEN=' /etc/clustereye/secrets.env 2>/dev/null | cut -d= -f2 || true)
  if [[ -z "$existing_token" ]] && [[ -f /var/lib/influxdb/influxd.bolt ]]; then
    log::info "No existing token but InfluxDB data found — wiping for clean setup..."
    systemctl stop influxdb 2>/dev/null || true
    rm -rf /var/lib/influxdb/*
  fi

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

influxdb::_ensure_initial_setup() {
  local admin_password token
  admin_password=$(rand_hex 16)
  token=$(rand_hex 16)

  # Check if InfluxDB is already initialized
  local health_status
  health_status=$(curl -sf http://localhost:8086/health 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)
  log::info "InfluxDB health: ${health_status:-unknown}"

  # Check if already set up via /api/v2/setup endpoint
  local needs_setup
  needs_setup=$(curl -sf http://localhost:8086/api/v2/setup 2>/dev/null | grep -o '"allowed":[a-z]*' | cut -d: -f2 || echo "true")

  # If already initialized but no existing secrets.env token, wipe and start fresh
  if [[ "$needs_setup" != "true" ]]; then
    local existing_token
    existing_token=$(grep '^INFLUXDB_TOKEN=' /etc/clustereye/secrets.env 2>/dev/null | cut -d= -f2 || true)
    if [[ -z "$existing_token" ]] || ! curl -sf -H "Authorization: Token ${existing_token}" http://localhost:8086/api/v2/orgs &>/dev/null; then
      log::warn "InfluxDB initialized with unknown token — resetting..."
      systemctl stop influxdb 2>/dev/null || true
      rm -rf /var/lib/influxdb/*
      systemctl start influxdb 2>/dev/null || true
      if ! wait_for_tcp 127.0.0.1 8086 30; then
        die "InfluxDB failed to restart after reset"
      fi
      needs_setup="true"
    fi
  fi

  if [[ "$needs_setup" == "true" ]]; then
    log::info "InfluxDB needs initial setup..."

    # Use HTTP API directly (no influx CLI dependency)
    local setup_response
    setup_response=$(curl -sf -X POST http://localhost:8086/api/v2/setup \
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
      log::info "Token: ${token:0:8}..."
    else
      log::warn "InfluxDB setup response: $setup_response"
      # Try with influx CLI as fallback
      if command -v influx &>/dev/null; then
        influx setup --force \
          --org clustereye --bucket clustereye \
          --username admin --password "$admin_password" \
          --token "$token" --host http://localhost:8086 2>&1 || true
      fi
    fi
  else
    log::info "InfluxDB already initialized, finding existing token..."

    # Find existing token
    # Method 1: CLI config file
    if [[ -f /root/.influxdbv2/configs ]]; then
      local cfg_token
      cfg_token=$(grep -A5 '\[default\]' /root/.influxdbv2/configs 2>/dev/null | grep 'token' | head -1 | sed 's/.*= *//' | tr -d '"' || true)
      if [[ -n "$cfg_token" ]]; then
        token="$cfg_token"
        log::info "Found token from CLI config"
      fi
    fi

    # Method 2: Use influx CLI if available
    if command -v influx &>/dev/null; then
      local cli_token
      cli_token=$(influx auth list --host http://localhost:8086 --json 2>/dev/null | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      if [[ -n "$cli_token" ]]; then
        token="$cli_token"
        log::info "Found token from influx CLI"
      fi
    fi
  fi

  # Verify token works
  local verify_result
  verify_result=$(curl -sf -H "Authorization: Token ${token}" http://localhost:8086/api/v2/orgs 2>/dev/null || true)
  if echo "$verify_result" | grep -q "clustereye"; then
    log::ok "InfluxDB token verified"
  else
    log::warn "InfluxDB token could not be verified"
    log::warn "Update INFLUXDB_TOKEN in /etc/clustereye/secrets.env manually"
  fi

  secrets::write_influxdb_fields "http://localhost:8086" "$token" "clustereye" "clustereye" "true"

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
