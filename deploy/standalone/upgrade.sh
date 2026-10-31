#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# ClusterEye Standalone Upgrade Script
# Upgrades API binary and/or UI assets in-place
#
# Usage:
#   sudo ./upgrade.sh --yes                    # API + UI to the latest published versions
#   sudo ./upgrade.sh                          # only shows latest vs installed, exits 2
#   sudo ./upgrade.sh --api-version=1.1.254
#   sudo ./upgrade.sh --ui-version=1.1.212
#   sudo ./upgrade.sh --api-version=1.1.254 --ui-version=1.1.212
#
# One-liner:
#   curl -fsSL https://archive.clustereye.com/deploy/standalone/upgrade.sh \
#     | sudo bash -s --
# ─────────────────────────────────────────────────────────────
set -Euo pipefail

# Bootstrap lib/templates from the public archive CDN (Pages) instead of raw.github,
# so the install chain stays on the archive.clustereye.com domain end-to-end.
readonly GITHUB_RAW_BASE="https://archive.clustereye.com/deploy/standalone"

CE_API_VERSION=""
CE_UI_VERSION=""
CE_ASSUME_YES=0

# ── Parse arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-version=*) CE_API_VERSION="${1#*=}" ;;
    --ui-version=*)  CE_UI_VERSION="${1#*=}" ;;
    -y|--yes)        CE_ASSUME_YES=1 ;;
    -h|--help)
      echo "Usage: $0 [--api-version=<ver>] [--ui-version=<ver>] [--yes]"
      echo ""
      echo "With no version flag, the latest published versions are shown and nothing is changed"
      echo "until you re-run with --yes (then both API and UI are upgraded to latest)."
      echo "With one flag, only that component is upgraded (use --api-version=latest to pick the newest)."
      echo "Config, secrets, TLS, and databases are preserved."
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

  local lib_files=(common.sh download.sh verify.sh config.sh nginx.sh)
  for f in "${lib_files[@]}"; do
    if ! curl -fsSL "${GITHUB_RAW_BASE}/lib/${f}" -o "$workdir/lib/${f}"; then
      rm -rf "$workdir"
      echo "[ERR]  Failed to download lib/${f}" >&2
      exit 1
    fi
  done

  # Every upgrade re-renders config.js and the nginx files (security headers).
  local template_files=(config.js.tmpl nginx.conf nginx-http-block.conf nginx-locations.inc nginx-security-headers.inc)
  for f in "${template_files[@]}"; do
    if ! curl -fsSL "${GITHUB_RAW_BASE}/templates/${f}" -o "$workdir/templates/${f}"; then
      rm -rf "$workdir"
      echo "[ERR]  Failed to download templates/${f}" >&2
      exit 1
    fi
  done

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

# Bare run: show latest vs installed and require --yes. Explicit versions or
# "latest" proceed. Resolved before anything is changed on the host.
download::plan_upgrade || exit $?
export CE_API_VERSION CE_UI_VERSION

if [[ ! -f /etc/systemd/system/clustereye-api.service ]]; then
  die "ClusterEye does not appear to be installed. Run install.sh first."
fi

# Read the install's domain and UI version BEFORE anything is replaced: a UI
# upgrade overwrites /usr/share/clustereye/web, config.js included. Older
# config.js files carry the domain in API_URL, newer ones in a comment.
CE_WEB_CONFIG=/usr/share/clustereye/web/config.js
CE_DOMAIN=$(grep -oP "(API_URL:\s*'|Installed for )https?://\K[^':/\s]*" "$CE_WEB_CONFIG" 2>/dev/null | head -1 || true)
CE_DOMAIN="${CE_DOMAIN:-localhost}"
CE_INSTALLED_UI_VERSION=$(grep -oP "VERSION:\s*'\K[^']*" "$CE_WEB_CONFIG" 2>/dev/null | head -1 || true)

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

  # Download before stopping: a missing release or network failure must not
  # leave the API down (the service is not restarted when the script dies).
  download::_stage_api

  log::info "Stopping clustereye-api service..."
  systemctl stop clustereye-api

  download::_install_staged_api

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
  download::_fetch_ui
fi

# ── Configuration refresh (every upgrade) ───────────────────
# config.js: same-origin API_URL, so the UI works under any host name and the
# API needs no cross-origin CORS. nginx: security headers on every response
# and no CORS headers of its own (pentest 2026-09). Both are safe to re-render
# on any install: ports come from the existing nginx config.
ce::_detect_ports
[[ -n "$CE_PORT" ]] || CE_PORT=443
[[ -n "$CE_HTTP_PORT" ]] || CE_HTTP_PORT=none
CE_UI_VERSION="${CE_UI_VERSION:-${CE_INSTALLED_UI_VERSION:-unknown}}"
source "${CE_SCRIPT_DIR}/lib/config.sh"
source "${CE_SCRIPT_DIR}/lib/nginx.sh"
export CE_PORT CE_HTTP_PORT CE_DOMAIN CE_UI_VERSION
config::_render_config_js
log::info "config.js: same-origin API (installed domain ${CE_DOMAIN})"
nginx::refresh

# ── Verify ──────────────────────────────────────────────────
ce::_detect_ports
export CE_PORT CE_HTTP_PORT
verify::wait

# Record the versions now installed (an API left alone keeps its recorded one).
download::write_installed_versions "${CE_API_VERSION:-$(download::installed_version api)}" "$CE_UI_VERSION"

log::ok "Upgrade complete"
if [[ -n "$CE_API_VERSION" ]]; then
  log::info "  API: v${CE_API_VERSION}"
fi
if [[ -n "$CE_UI_VERSION" ]]; then
  log::info "  UI:  v${CE_UI_VERSION}"
fi
