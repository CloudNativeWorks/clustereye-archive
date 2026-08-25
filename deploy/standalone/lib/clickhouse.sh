#!/usr/bin/env bash
# clickhouse.sh — Install local ClickHouse or configure external for
# the per-query metric store. Mirrors influxdb.sh shape.
#
# Local install: ClickHouse 24.8 LTS via official APT/RPM repo, with a
# `clustereye` user (localhost-only, sha256 password) and the per-query
# schema applied. Credentials get written to secrets.env — the API reads
# CLICKHOUSE_* env vars (config.go) at runtime.

readonly CH_VERSION_PIN="24.8"   # LTS line — leave the .x patch open
readonly CH_REPO_KEY_ID="3E4AD4719DDE9A38"
readonly CH_USER_XML="/etc/clickhouse-server/users.d/clustereye.xml"

clickhouse::setup() {
  log::step "Configuring ClickHouse"

  case "$CE_CLICKHOUSE" in
    local)    clickhouse::_install_local ;;
    external) clickhouse::_configure_external ;;
    *) die "Invalid --clickhouse value: $CE_CLICKHOUSE (expected: local|external)" ;;
  esac
}

clickhouse::_install_local() {
  log::info "Installing local ClickHouse ${CH_VERSION_PIN} LTS..."

  clickhouse::_ensure_package_installed
  clickhouse::_ensure_service_running
  clickhouse::_ensure_user_and_schema
}

# Fetch a repo signing key into /usr/share/keyrings/clickhouse-keyring.gpg in
# binary OpenPGP format. Receiving directly with --keyring on GnuPG >= 2.4
# (Ubuntu 26.04) creates a keybox-format file that apt rejects with
# "unsupported filetype" — so pull into a temp GNUPGHOME and export instead.
clickhouse::_fetch_repo_key() {
  local key_id="$1" gpgtmp fetched=0 ks
  gpgtmp=$(mktemp -d)
  chmod 700 "$gpgtmp"
  for ks in keyserver.ubuntu.com keys.openpgp.org; do
    if GNUPGHOME="$gpgtmp" gpg --batch \
        --keyserver "hkps://${ks}" --recv-keys "$key_id" 2>/dev/null; then
      fetched=1; break
    fi
  done
  if [[ "$fetched" -eq 1 ]]; then
    GNUPGHOME="$gpgtmp" gpg --batch --export "$key_id" \
      > /usr/share/keyrings/clickhouse-keyring.gpg
    chmod 644 /usr/share/keyrings/clickhouse-keyring.gpg
  fi
  rm -rf "$gpgtmp"
  [[ "$fetched" -eq 1 ]]
}

clickhouse::_ensure_package_installed() {
  if command -v clickhouse-server &>/dev/null; then
    log::info "clickhouse-server already installed: $(clickhouse-server --version 2>/dev/null | head -1)"
    return 0
  fi

  case "$CE_OS_FAMILY" in
    debian)
      apt-get install -y -qq apt-transport-https ca-certificates dirmngr curl >/dev/null

      if [[ ! -s /usr/share/keyrings/clickhouse-keyring.gpg ]]; then
        clickhouse::_fetch_repo_key "$CH_REPO_KEY_ID" \
          || die "ClickHouse repo signing key fetch failed (keyserver reachable?)"
      fi

      echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
        > /etc/apt/sources.list.d/clickhouse.list

      # NO_PUBKEY can surface when the repo rotates its key — fetch + retry once.
      if ! apt-get update -qq 2>/tmp/_ch_apt_err; then
        local missing
        missing=$(grep -oE 'NO_PUBKEY [0-9A-F]+' /tmp/_ch_apt_err | awk '{print $2}' | head -1 || true)
        if [[ -n "$missing" ]]; then
          log::warn "Missing key $missing — fetching"
          # Drop the old keyring: it may be in keybox format (unreadable by apt)
          # or simply stale after a repo key rotation.
          rm -f /usr/share/keyrings/clickhouse-keyring.gpg
          clickhouse::_fetch_repo_key "$missing" || die "ClickHouse repo key $missing fetch failed"
          apt-get update -qq
        else
          cat /tmp/_ch_apt_err >&2; die "apt-get update failed"
        fi
      fi
      rm -f /tmp/_ch_apt_err

      # Pin to the latest available 24.8.x patch.
      local ch_ver
      # NOTE: awk must consume all input (no early `exit`) — exiting early closes
      # the pipe and apt-cache dies with SIGPIPE (exit 141), which `pipefail` turns
      # into a fatal error. Keep the first (newest) match via a guard instead.
      ch_ver=$(apt-cache madison clickhouse-server 2>/dev/null | awk -v v="${CH_VERSION_PIN}" '$3 ~ v"\\." && !f{ver=$3; f=1} END{print ver}')
      [[ -n "$ch_ver" ]] || die "No ${CH_VERSION_PIN}.x version found in the ClickHouse APT repo"
      log::info "Target ClickHouse version: ${ch_ver}"

      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "clickhouse-server=${ch_ver}" \
        "clickhouse-client=${ch_ver}" \
        "clickhouse-common-static=${ch_ver}"
      ;;
    rhel)
      if ! rpm -q clickhouse-server &>/dev/null; then
        cat > /etc/yum.repos.d/clickhouse.repo <<'REPO'
[clickhouse]
name=ClickHouse - Stable
baseurl=https://packages.clickhouse.com/rpm/stable/
enabled=1
gpgcheck=0
REPO
        local ch_ver
        # Consume all input (no early `exit`) to avoid a SIGPIPE on dnf under pipefail.
        ch_ver=$(dnf --showduplicates list clickhouse-server 2>/dev/null \
          | awk -v v="${CH_VERSION_PIN}" '$2 ~ v"\\." && !f{ver=$2; f=1} END{print ver}')
        [[ -n "$ch_ver" ]] || die "No ${CH_VERSION_PIN}.x version found in the ClickHouse RPM repo"
        log::info "Target ClickHouse version: ${ch_ver}"

        dnf install -y -q \
          "clickhouse-server-${ch_ver}" \
          "clickhouse-client-${ch_ver}" \
          "clickhouse-common-static-${ch_ver}"
      fi
      ;;
    *) die "Unsupported OS family for ClickHouse install: $CE_OS_FAMILY" ;;
  esac

  command -v clickhouse-server >/dev/null || die "clickhouse-server install completed but binary missing"
  log::ok "ClickHouse installed ($(clickhouse-server --version 2>/dev/null | head -1))"
}

clickhouse::_ensure_service_running() {
  systemctl enable --now clickhouse-server >/dev/null 2>&1 || systemctl restart clickhouse-server

  if ! wait_for_tcp 127.0.0.1 9000 30; then
    log::err "ClickHouse did not respond on 9000 within 30s"
    log::err "$(systemctl status clickhouse-server 2>&1 | head -15)"
    die "ClickHouse failed to start. Check: journalctl -u clickhouse-server"
  fi

  log::ok "ClickHouse running on 127.0.0.1:9000"
}

clickhouse::_ensure_user_and_schema() {
  local password sha_hex
  # Re-use a previously-written password when present so re-runs stay
  # idempotent (the password lives in secrets.env after first install).
  password=$(grep '^CLICKHOUSE_PASSWORD=' /etc/clustereye/secrets.env 2>/dev/null | cut -d= -f2- || true)
  if [[ -z "$password" ]]; then
    password=$(rand_hex 16)
  fi
  sha_hex=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)

  # users.d config — localhost-only network ACL, default profile, default quota.
  cat > "$CH_USER_XML" <<XML
<clickhouse>
    <users>
        <clustereye>
            <password_sha256_hex>${sha_hex}</password_sha256_hex>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </clustereye>
    </users>
</clickhouse>
XML
  chown clickhouse:clickhouse "$CH_USER_XML" 2>/dev/null || true
  chmod 0640 "$CH_USER_XML"

  systemctl restart clickhouse-server
  wait_for_tcp 127.0.0.1 9000 30 || die "ClickHouse failed to restart after user config"

  # Verify the clustereye user authenticates before applying schema.
  local tries=0
  until clickhouse-client --user clustereye --password "$password" --query "SELECT 1" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ $tries -ge 10 ]] && die "clustereye user authentication failed"
    sleep 2
  done

  # Apply the schema (IF NOT EXISTS — idempotent re-run safe).
  local schema="${CE_SCRIPT_DIR}/templates/clickhouse-schema.sql"
  [[ -f "$schema" ]] || die "ClickHouse schema template missing: $schema"
  clickhouse-client --multiquery < "$schema" \
    || die "Failed to apply ClickHouse schema"

  local tbl_count
  tbl_count=$(clickhouse-client --query "SELECT count() FROM system.tables WHERE database='clustereye'")
  [[ "$tbl_count" -ge 8 ]] || die "ClickHouse schema incomplete (expected ≥8 tables, got $tbl_count)"
  log::ok "ClickHouse schema applied ($tbl_count tables)"

  # Persist credentials to secrets.env (API reads CLICKHOUSE_* env vars).
  secrets::write_clickhouse_fields "127.0.0.1:9000" "clustereye" "clustereye" "$password" "true"
  log::ok "Local ClickHouse configured (addr=127.0.0.1:9000, db=clustereye)"
  log::info "ClickHouse clustereye password recorded in /etc/clustereye/secrets.env"
}

clickhouse::_configure_external() {
  local addr="${CE_CLICKHOUSE_HOST:-CHANGE_ME}:${CE_CLICKHOUSE_PORT:-9000}"
  if [[ "${CE_CLICKHOUSE_HOST:-}" == "" ]]; then
    addr="CHANGE_ME:9000"
  fi
  local database="${CE_CLICKHOUSE_DATABASE:-clustereye}"
  local username="${CE_CLICKHOUSE_USER:-clustereye}"
  local password="${CE_CLICKHOUSE_PASSWORD:-CHANGE_ME}"

  secrets::write_clickhouse_fields "$addr" "$database" "$username" "$password" "true"

  if [[ "$addr" == "CHANGE_ME:9000" || "$password" == "CHANGE_ME" ]]; then
    log::warn "External ClickHouse: placeholder values written to $SECRETS_FILE"
    log::warn "Update CLICKHOUSE_ADDR and CLICKHOUSE_PASSWORD in $SECRETS_FILE before starting the service"
  else
    log::ok "External ClickHouse configured (addr=$addr)"
  fi
}
