#!/usr/bin/env bash
# preflight.sh — OS detection, requirements validation

preflight::run() {
  log::step "Preflight checks"
  require_root
  preflight::detect_os
  preflight::detect_arch
  preflight::check_systemd
  preflight::wait_for_apt
  preflight::refresh_apt
  preflight::install_tools
  preflight::check_ports
  log::ok "Preflight checks passed (OS=$CE_OS_FAMILY, DISTRO=$CE_DISTRO, ARCH=$CE_ARCH)"
}

preflight::detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release not found."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release

  CE_DISTRO="${ID:-unknown}"
  CE_DISTRO_VERSION="${VERSION_ID:-0}"
  local id_like="${ID_LIKE:-} ${ID:-}"

  if echo "$id_like" | grep -qiE 'debian|ubuntu'; then
    CE_OS_FAMILY="debian"
  elif echo "$id_like" | grep -qiE 'rhel|centos|fedora|rocky|almalinux|ol|oracle'; then
    CE_OS_FAMILY="rhel"
  else
    die "Unsupported OS: $CE_DISTRO ($id_like). Supported: Ubuntu, RHEL, Oracle Linux."
  fi
}

preflight::detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) CE_ARCH="amd64" ;;
    *) die "Unsupported architecture: $arch. Only amd64 (x86_64) is supported." ;;
  esac
}

preflight::check_systemd() {
  if ! command -v systemctl &>/dev/null; then
    die "systemd is required but not found."
  fi
  local ver
  ver=$(systemctl --version | head -1 | awk '{print $2}' | grep -oE '^[0-9]+' || echo "0")
  if [[ -z "$ver" || "$ver" -lt 236 ]]; then
    die "systemd >= 236 required, found $ver."
  fi
}

preflight::wait_for_apt() {
  [[ "$CE_OS_FAMILY" == "debian" ]] || return 0

  local waited=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock &>/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock &>/dev/null 2>&1; do
    if [[ $waited -eq 0 ]]; then
      log::info "Waiting for apt lock to be released..."
    fi
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge 120 ]]; then
      die "apt lock still held after 120s — check running apt/dpkg processes"
    fi
  done
  if [[ $waited -gt 0 ]]; then
    log::ok "apt lock released (waited ${waited}s)"
  fi

  # Fix broken influxdb2 package — its postrm calls systemctl disable
  # which fails if the service file was already removed
  if dpkg -l influxdb2 2>/dev/null | grep -qE '^(rc|iF|iU|iW)'; then
    log::warn "Broken influxdb2 package detected, force-purging..."
    # Create dummy service file so postrm succeeds
    if [[ ! -f /lib/systemd/system/influxdb.service ]] && \
       [[ ! -f /usr/lib/systemd/system/influxdb.service ]] && \
       [[ ! -f /etc/systemd/system/influxdb.service ]]; then
      cat > /etc/systemd/system/influxdb.service <<'DUMMY'
[Unit]
Description=dummy for cleanup
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
DUMMY
      systemctl daemon-reload 2>/dev/null || true
    fi
    DEBIAN_FRONTEND=noninteractive dpkg --purge influxdb2 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive dpkg --remove --force-all influxdb2 2>/dev/null || true
    rm -f /etc/systemd/system/influxdb.service
    systemctl daemon-reload 2>/dev/null || true
    log::ok "Broken influxdb2 package cleaned up"
  fi

  # Fix any other broken/half-configured packages
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -f -qq 2>/dev/null || true
}

preflight::refresh_apt() {
  [[ "$CE_OS_FAMILY" == "debian" ]] || return 0
  log::info "Refreshing apt index..."
  apt-get update -qq 2>/dev/null || log::warn "apt-get update failed (continuing with stale cache)"
}

preflight::install_tools() {
  local missing=()
  for cmd in curl openssl tar awk sed grep; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if ! command -v envsubst &>/dev/null; then
    case "$CE_OS_FAMILY" in
      debian) missing+=("gettext-base") ;;
      rhel)   missing+=("gettext") ;;
    esac
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log::info "Installing missing tools: ${missing[*]}"
    case "$CE_OS_FAMILY" in
      debian)
        apt::install "${missing[@]}"
        ;;
      rhel)
        dnf install -y -q "${missing[@]}"
        ;;
    esac
  fi
}

preflight::check_ports() {
  local -a ports=("${CE_PORT:-443}")
  local http_port="${CE_HTTP_PORT:-80}"
  if [[ "$http_port" != "none" && "$http_port" != "0" ]]; then
    ports+=("$http_port")
  fi

  for port in "${ports[@]}"; do
    local holder=""
    if command -v ss &>/dev/null; then
      holder=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)
    elif command -v netstat &>/dev/null; then
      holder=$(netstat -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)
    fi

    if [[ -n "$holder" ]]; then
      if echo "$holder" | grep -qE 'nginx|clustereye'; then
        log::warn "Port $port in use by nginx/clustereye (re-run detected, continuing)"
      else
        die "Port $port is already in use: $holder"
      fi
    fi
  done
}
