#!/usr/bin/env bash
# common.sh — Shared helpers for ClusterEye standalone installer
set -Eeuo pipefail

# ── Colors ──────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ── Logging ─────────────────────────────────────────────
log::info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
log::ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
log::warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
log::err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
log::step()  { printf "\n${BOLD}${CYAN}[STEP]${NC}  ${BOLD}%s${NC}\n" "$*"; }

die() {
  log::err "$@"
  exit 1
}

# ── Guards ──────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command '$1' not found."
}

# ── Utilities ───────────────────────────────────────────
rand_hex() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes" 2>/dev/null || head -c "$bytes" /dev/urandom | od -An -vtx1 | tr -d ' \n'
}

wait_for_tcp() {
  local host="$1" port="$2" timeout="${3:-30}" elapsed=0
  while ! (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $timeout ]]; then
      return 1
    fi
  done
  return 0
}

retry() {
  local attempts="$1" delay="$2"; shift 2
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    [[ $i -lt $attempts ]] && sleep "$delay"
  done
  return 1
}

render_template() {
  local template="$1" dest="$2" allowlist="$3"
  envsubst "$allowlist" < "$template" > "${dest}.tmp"
  mv -f "${dest}.tmp" "$dest"
}

# Install Debian packages with one automatic retry after refreshing the apt
# index when the cache is stale (404/Failed-to-fetch from the archive).
apt::install() {
  local pkgs=("$@") out rc=0
  out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" 2>&1) || rc=$?

  if [[ $rc -eq 0 ]]; then
    return 0
  fi

  if echo "$out" | grep -qE '404 +Not Found|Failed to fetch'; then
    log::warn "apt cache stale — refreshing and retrying ${pkgs[*]}"
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" \
      || die "apt install failed after retry: ${pkgs[*]}"
    return 0
  fi

  echo "$out" >&2
  die "apt install failed: ${pkgs[*]}"
}

# ── ERR trap ────────────────────────────────────────────
_err_trap() {
  local exit_code=$? line_no="${BASH_LINENO[0]}" cmd="${BASH_COMMAND}"
  log::err "Command failed (exit $exit_code) at line $line_no: $cmd"
}
trap _err_trap ERR
