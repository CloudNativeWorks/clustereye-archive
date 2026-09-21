#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# ClusterEye Standalone Upgrade Script
# Upgrades API binary and/or UI assets in-place
#
# Usage:
#   sudo ./upgrade.sh --api-version=1.1.254
#   sudo ./upgrade.sh --ui-version=1.1.212
#   sudo ./upgrade.sh --api-version=1.1.254 --ui-version=1.1.212
#
# One-liner:
#   curl -fsSL https://archive.clustereye.com/deploy/standalone/upgrade.sh \
#     | sudo bash -s -- --api-version=1.1.254
# ─────────────────────────────────────────────────────────────
set -Euo pipefail

# Bootstrap lib/templates from the public archive CDN (Pages) instead of raw.github,
# so the install chain stays on the archive.clustereye.com domain end-to-end.
readonly GITHUB_RAW_BASE="https://archive.clustereye.com/deploy/standalone"

CE_API_VERSION=""
CE_UI_VERSION=""

# ── Parse arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-version=*) CE_API_VERSION="${1#*=}" ;;
    --ui-version=*)  CE_UI_VERSION="${1#*=}" ;;
    -h|--help)
      echo "Usage: $0 [--api-version=<ver>] [--ui-version=<ver>]"
      echo ""
      echo "At least one of --api-version or --ui-version must be specified."
      echo "Only specified components will be upgraded. Config, secrets, TLS, and databases are preserved."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Bootstrap: download lib files if running via pipe ───────
bootstrap() {
  local script_dir=""

  # Try to find local lib directory
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi

  if [[ -n "$script_dir" && -d "${script_dir}/lib" ]]; then
    CE_SCRIPT_DIR="$script_dir"
    return 0
  fi

  # Running via pipe — download required lib files
  echo "[INFO]  Downloading upgrade dependencies..."
  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/lib" "$workdir/templates"

  local lib_files=(common.sh download.sh verify.sh config.sh)
  for f in "${lib_files[@]}"; do
    if ! curl -fsSL "${GITHUB_RAW_BASE}/lib/${f}" -o "$workdir/lib/${f}"; then
      rm -rf "$workdir"
      echo "[ERR]  Failed to download lib/${f}" >&2
      exit 1
    fi
  done

  # Download config.js template for UI upgrades
  curl -fsSL "${GITHUB_RAW_BASE}/templates/config.js.tmpl" -o "$workdir/templates/config.js.tmpl" 2>/dev/null || true

  CE_SCRIPT_DIR="$workdir"
}

bootstrap

export CE_API_VERSION CE_UI_VERSION CE_SCRIPT_DIR

# Source libraries
source "${CE_SCRIPT_DIR}/lib/common.sh"
source "${CE_SCRIPT_DIR}/lib/download.sh"
source "${CE_SCRIPT_DIR}/lib/verify.sh"

# ── Validate ────────────────────────────────────────────────
require_root

if [[ -z "$CE_API_VERSION" && -z "$CE_UI_VERSION" ]]; then
  die "At least one of --api-version or --ui-version must be specified"
fi

if [[ ! -f /etc/systemd/system/clustereye-api.service ]]; then
  die "ClusterEye does not appear to be installed. Run install.sh first."
fi

# ── Upgrade ─────────────────────────────────────────────────
log::step "Upgrading ClusterEye"

# Upgrade API binary
if [[ -n "$CE_API_VERSION" ]]; then
  # The API refuses to start without a strong JWT_SECRET_KEY; check before
  # stopping it so a server with legacy keys is not left half-upgraded.
  secrets_file=/etc/clustereye/secrets.env
  [[ -f "$secrets_file" ]] || die "$secrets_file not found — see the ENCRYPTION_KEY rotation steps before upgrading"
  jwt=$(grep '^JWT_SECRET_KEY=' "$secrets_file" | cut -d= -f2- || true)
  if [[ ${#jwt} -lt 32 || "$jwt" == "clustereye-default-secret-key-change-this-in-production-2024" ]]; then
    log::warn "JWT_SECRET_KEY missing or weak — generating a new one (users will need to log in again)"
    new_jwt=$(rand_hex 32)
    if grep -q '^JWT_SECRET_KEY=' "$secrets_file"; then
      sed -i "s|^JWT_SECRET_KEY=.*|JWT_SECRET_KEY=${new_jwt}|" "$secrets_file"
    else
      printf '\nJWT_SECRET_KEY=%s\n' "$new_jwt" >> "$secrets_file"
    fi
  fi
  enc=$(grep '^ENCRYPTION_KEY=' "$secrets_file" | cut -d= -f2- || true)
  if [[ -z "$enc" || "$enc" == 'clustereye-default-32byte-key!!!' ]]; then
    log::warn "ENCRYPTION_KEY is missing or the public default — stored credentials are not protected."
    log::warn "After the upgrade: stop the API, set a new 32-char ENCRYPTION_KEY in $secrets_file, then run"
    log::warn "  ENCRYPTION_KEY_OLD='clustereye-default-32byte-key!!!' ENCRYPTION_KEY=<new> clustereye-api rotate-encryption-key --apply"
  fi

  log::info "Stopping clustereye-api service..."
  systemctl stop clustereye-api

  download::_fetch_api

  log::info "Starting clustereye-api service..."
  systemctl start clustereye-api
fi

# Detect ports from existing nginx config (HTTPS = ssl line, HTTP = the other)
ce::_detect_ports() {
  local conf=/etc/nginx/conf.d/clustereye.conf
  CE_PORT=$(grep -E 'listen [0-9]+ .*ssl' "$conf" 2>/dev/null | grep -oP 'listen \K[0-9]+' | head -1 || echo "443")
  CE_HTTP_PORT=$(grep -E 'listen [0-9]+' "$conf" 2>/dev/null | grep -v ssl | grep -oP 'listen \K[0-9]+' | head -1 || echo "none")
}

# Upgrade UI assets
if [[ -n "$CE_UI_VERSION" ]]; then
  # Read domain and port BEFORE overwriting files
  ce::_detect_ports
  CE_DOMAIN=$(grep -oP "API_URL:\s*'https?://\K[^':]*" /usr/share/clustereye/web/config.js 2>/dev/null || echo "localhost")

  download::_fetch_ui

  # Re-render config.js with correct domain
  source "${CE_SCRIPT_DIR}/lib/config.sh"
  export CE_PORT CE_HTTP_PORT CE_DOMAIN CE_UI_VERSION
  config::_render_config_js
  log::info "config.js domain: ${CE_DOMAIN}"
fi

# ── Verify ──────────────────────────────────────────────────
ce::_detect_ports
export CE_PORT CE_HTTP_PORT
verify::wait

log::ok "Upgrade complete"
if [[ -n "$CE_API_VERSION" ]]; then
  log::info "  API: v${CE_API_VERSION}"
fi
if [[ -n "$CE_UI_VERSION" ]]; then
  log::info "  UI:  v${CE_UI_VERSION}"
fi
