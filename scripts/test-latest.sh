#!/usr/bin/env bash
# test-latest.sh — checks download::resolve_latest / download::resolve_versions
# against a local HTTP server standing in for archive.clustereye.com.
# Usage: bash scripts/test-latest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/site/downloads/api" "$TMP/site/downloads/ui"
printf '1.5.53\n' > "$TMP/site/downloads/api/LATEST"
# ui/LATEST intentionally missing at first

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
(cd "$TMP/site" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV_PID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/downloads/api/LATEST" >/dev/null 2>&1 && break; sleep 0.1; done

export ARCHIVE_BASE_URL="http://127.0.0.1:$PORT"
FAIL=0
check() { # name, ok(0/1)
  if [[ "$2" == 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

# Run in a subshell with minimal stubs for the helpers download.sh expects.
run() {
  ( log::info() { :; }; log::ok() { :; }; log::step() { :; }
    log::err() { echo "ERR: $*" >&2; }; log::warn() { :; }
    die() { echo "ERR: $*" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$ROOT/deploy/standalone/lib/download.sh" || exit 99
    "$@" )
}

out="$(run download::resolve_latest api 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == "1.5.53" ]]; check "resolve_latest api -> 1.5.53 (got '$out' rc=$rc)" $?

out="$(run download::resolve_latest ui 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"could not resolve latest ui version; pass --ui-version="* ]]
check "missing ui/LATEST -> error message and non-zero (rc=$rc)" $?

# With the installer's real ERR trap (common.sh, set -Eeuo pipefail) the
# missing-LATEST path must print only the friendly message: no trap noise.
trapped() {
  ( set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$ROOT/deploy/standalone/lib/common.sh" || exit 99
    # shellcheck source=/dev/null
    source "$ROOT/deploy/standalone/lib/download.sh" || exit 99
    "$@" )
}
resolve_missing_ui() { CE_API_VERSION=""; CE_UI_VERSION=""; download::resolve_versions || exit 1; }
out="$(trapped resolve_missing_ui 2>&1)"; rc=$?
errs="$(printf '%s\n' "$out" | grep -c '\[ERR\]' || true)"
[[ $rc != 0 && "$out" == *"could not resolve latest ui version"* && "$out" != *"Command failed"* && "$errs" == 1 ]]
check "missing LATEST under the ERR trap -> only the friendly [ERR] line (rc=$rc, [ERR] lines=$errs)" $?
upgrade_missing_ui() { CE_API_VERSION=""; CE_UI_VERSION=""; CE_ASSUME_YES=1; download::plan_upgrade || exit $?; }
out="$(trapped upgrade_missing_ui 2>&1)"; rc=$?
errs="$(printf '%s\n' "$out" | grep -c '\[ERR\]' || true)"
[[ $rc == 1 && "$out" != *"Command failed"* && "$errs" == 1 ]]
check "plan_upgrade missing LATEST under the ERR trap -> rc 1, no trap noise (rc=$rc, [ERR] lines=$errs)" $?

# HTML/garbage 200 body must not be accepted as a version
printf '<html>404</html>\n' > "$TMP/site/downloads/ui/LATEST"
out="$(run download::resolve_latest ui 2>&1)"; rc=$?
[[ $rc != 0 ]]; check "garbage LATEST rejected (rc=$rc)" $?

# explicit --api-version must not trigger resolve: point at a dead server
resolve_explicit() {
  CE_API_VERSION="1.2.3"; CE_UI_VERSION="1.2.4"
  download::resolve_latest() { echo "RESOLVE CALLED" >&2; return 1; }
  download::resolve_versions
  echo "$CE_API_VERSION $CE_UI_VERSION"
}
out="$(run resolve_explicit 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == "1.2.3 1.2.4" ]]; check "explicit versions skip resolve (got '$out')" $?

# empty -> latest
printf '1.5.51\n' > "$TMP/site/downloads/ui/LATEST"
resolve_default() {
  CE_API_VERSION=""; CE_UI_VERSION="latest"
  download::resolve_versions
  echo "$CE_API_VERSION $CE_UI_VERSION"
}
out="$(run resolve_default 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == "1.5.53 1.5.51" ]]; check "empty/latest resolve (got '$out')" $?

# bare upgrade without --yes: exit 2, message, nothing changed
bare_noyes() { CE_API_VERSION=""; CE_UI_VERSION=""; CE_ASSUME_YES=0; CE_WEB_CONFIG=/nonexistent
  download::plan_upgrade; echo "rc=$?"; }
out="$(run bare_noyes 2>&1)"
[[ "$out" == *"Latest available: api 1.5.53, ui 1.5.51"* && "$out" == *"--yes"* && "$out" == *"rc=2"* ]]
check "bare upgrade without --yes -> exit 2 + message" $?

# Installed versions come from the marker, never from running the API binary.
! grep -q -- '--version 2>' "$ROOT/deploy/standalone/lib/download.sh"
check "plan_upgrade does not execute the API binary" $?
export CE_VERSIONS_FILE="$TMP/etc/installed-versions"
out="$(run bare_noyes 2>&1)"
[[ "$out" == *"Installed:        api unknown, ui unknown"* ]]; check "no marker -> installed api unknown" $?
write_marker() { download::write_installed_versions 1.5.50 1.5.49; download::installed_version api; echo -n " "; download::installed_version ui; }
out="$(run write_marker 2>&1)"
[[ "$out" == "1.5.50 1.5.49" && "$(cat "$CE_VERSIONS_FILE")" == $'api=1.5.50\nui=1.5.49' ]]
check "write/read installed-versions marker (got '$out')" $?
out="$(run bare_noyes 2>&1)"
[[ "$out" == *"Installed:        api 1.5.50, ui 1.5.49"* ]]; check "marker -> installed versions shown" $?
write_unknown() { download::write_installed_versions "" 1.5.49; echo "[$(download::installed_version api)]"; }
out="$(run write_unknown 2>&1)"
[[ "$out" == "[]" && "$(head -1 "$CE_VERSIONS_FILE")" == "api=unknown" ]]; check "empty version recorded as unknown (got '$out')" $?
unset CE_VERSIONS_FILE

bare_yes() { CE_API_VERSION=""; CE_UI_VERSION=""; CE_ASSUME_YES=1
  download::plan_upgrade; echo "rc=$? $CE_API_VERSION $CE_UI_VERSION"; }
out="$(run bare_yes 2>&1)"; [[ "$out" == "rc=0 1.5.53 1.5.51" ]]; check "bare upgrade with --yes resolves latest (got '$out')" $?

latest_flag() { CE_API_VERSION="latest"; CE_UI_VERSION=""; CE_ASSUME_YES=0
  download::plan_upgrade; echo "rc=$? $CE_API_VERSION [$CE_UI_VERSION]"; }
out="$(run latest_flag 2>&1)"; [[ "$out" == "rc=0 1.5.53 []" ]]; check "--api-version=latest proceeds without --yes (got '$out')" $?

explicit2() { CE_API_VERSION="1.2.3"; CE_UI_VERSION=""; CE_ASSUME_YES=0
  download::plan_upgrade; echo "rc=$? $CE_API_VERSION [$CE_UI_VERSION]"; }
out="$(run explicit2 2>&1)"; [[ "$out" == "rc=0 1.2.3 []" ]]; check "explicit version proceeds without --yes (got '$out')" $?

# write-latest.sh ignores pre-release dirs
mkdir -p "$TMP/w/downloads/api/v1.5.53" "$TMP/w/downloads/api/v1.5.54-rc1" "$TMP/w/downloads/api/v1.5.9" \
         "$TMP/w/downloads/ui/v1.5.51" "$TMP/w/downloads/ui/v1.6.0-rc1"
bash "$ROOT/scripts/write-latest.sh" "$TMP/w" >/dev/null
[[ "$(cat "$TMP/w/downloads/api/LATEST")" == "1.5.53" && "$(cat "$TMP/w/downloads/ui/LATEST")" == "1.5.51" ]]
check "write-latest skips rc dirs (api=$(cat "$TMP/w/downloads/api/LATEST") ui=$(cat "$TMP/w/downloads/ui/LATEST"))" $?

exit $FAIL
