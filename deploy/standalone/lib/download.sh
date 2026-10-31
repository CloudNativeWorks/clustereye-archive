#!/usr/bin/env bash
# download.sh — Download API binary and UI assets from the public ClusterEye archive
# Source repos (clustereye-api, clustereye) are private; artifacts are mirrored to
# archive.clustereye.com by the archive's pull workflow (update-standalone-artifacts.yml).

# ARCHIVE_BASE_URL can be overridden (tests, mirrors); default is the public archive.
ARCHIVE_BASE_URL="${ARCHIVE_BASE_URL:-https://archive.clustereye.com}"
readonly API_RELEASE_BASE="${ARCHIVE_BASE_URL}/downloads/api"
readonly UI_RELEASE_BASE="${ARCHIVE_BASE_URL}/downloads/ui"
readonly BINARY_DEST="/usr/local/bin/clustereye-api"
readonly FRONTEND_DEST="/usr/share/clustereye/web"

# Prints the newest published version (bare, no "v") of <api|ui>, read from the
# single-line LATEST file the archive publishes next to the version directories.
# On failure prints a friendly error to stderr, nothing to stdout, and returns 1.
# The body runs in a subshell with the ERR trap cleared, so the installer's
# "Command failed" trap does not add noise around the friendly message; call it
# as $(download::resolve_latest <comp> || :) and treat empty output as failure
# (a bare failing call inside $(...) would still trip the inherited trap).
download::resolve_latest() (
  trap - ERR
  local comp="$1" url out version=""
  url="${ARCHIVE_BASE_URL}/downloads/${comp}/LATEST"
  if out=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "$url" 2>/dev/null); then
    version=$(printf '%s\n' "$out" | head -n 1 | tr -d '[:space:]')
  fi
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]+)?$ ]]; then
    echo "[ERR]  could not resolve latest ${comp} version; pass --${comp}-version=<ver> (looked at ${url})" >&2
    return 1
  fi
  printf '%s\n' "$version"
)

# Path of the marker install.sh / upgrade.sh write after a successful run
# (lines "api=<ver>" and "ui=<ver>"). Overridable for tests.
download::_versions_file() { printf '%s\n' "${CE_VERSIONS_FILE:-/etc/clustereye/installed-versions}"; }

# Prints the recorded installed version of <api|ui>, or nothing when unknown.
download::installed_version() {
  local f v
  f=$(download::_versions_file)
  [[ -r "$f" ]] || return 0
  v=$(grep -E "^$1=" "$f" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)
  [[ "$v" == "unknown" ]] && v=""
  printf '%s' "$v"
}

# Records the installed versions: download::write_installed_versions <api> <ui>.
# An empty value is written as "unknown".
download::write_installed_versions() {
  local f tmp
  f=$(download::_versions_file)
  mkdir -p "$(dirname "$f")"
  tmp="${f}.tmp.$$"
  printf 'api=%s\nui=%s\n' "${1:-unknown}" "${2:-unknown}" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$f"
}

# Replaces an empty or "latest" CE_API_VERSION / CE_UI_VERSION with the
# resolved latest version. Explicit versions are left alone (no network call).
download::resolve_versions() {
  if [[ -z "${CE_API_VERSION:-}" || "${CE_API_VERSION}" == "latest" ]]; then
    CE_API_VERSION=$(download::resolve_latest api || :)
    [[ -n "$CE_API_VERSION" ]] || return 1
  fi
  if [[ -z "${CE_UI_VERSION:-}" || "${CE_UI_VERSION}" == "latest" ]]; then
    CE_UI_VERSION=$(download::resolve_latest ui || :)
    [[ -n "$CE_UI_VERSION" ]] || return 1
  fi
}

# Decides what upgrade.sh will do from CE_API_VERSION / CE_UI_VERSION /
# CE_ASSUME_YES. A bare run (neither version given) resolves latest, prints
# what is available next to what is installed, and returns 2 unless --yes was
# given, so production is never upgraded by accident. Explicit versions and
# "latest" proceed without --yes. Returns 1 if latest cannot be resolved.
download::plan_upgrade() {
  local bare=0
  if [[ -z "${CE_API_VERSION:-}" && -z "${CE_UI_VERSION:-}" ]]; then
    bare=1
    CE_API_VERSION=latest
    CE_UI_VERSION=latest
  fi
  if [[ "$CE_API_VERSION" == "latest" ]]; then
    CE_API_VERSION=$(download::resolve_latest api || :)
    [[ -n "$CE_API_VERSION" ]] || return 1
  fi
  if [[ "$CE_UI_VERSION" == "latest" ]]; then
    CE_UI_VERSION=$(download::resolve_latest ui || :)
    [[ -n "$CE_UI_VERSION" ]] || return 1
  fi
  if [[ $bare == 1 && "${CE_ASSUME_YES:-0}" != 1 ]]; then
    # Installed versions come from the marker written by install.sh/upgrade.sh;
    # the API binary is never executed here. Without a marker the API version
    # is "unknown" (the UI falls back to config.js).
    local cfg="${CE_WEB_CONFIG:-/usr/share/clustereye/web/config.js}" ui_inst="" api_inst=""
    api_inst=$(download::installed_version api)
    ui_inst=$(download::installed_version ui)
    [[ -n "$ui_inst" ]] || ui_inst=$(grep -oP "VERSION:\s*'\K[^']*" "$cfg" 2>/dev/null | head -1 || true)
    echo "Latest available: api ${CE_API_VERSION}, ui ${CE_UI_VERSION}" >&2
    echo "Installed:        api ${api_inst:-unknown}, ui ${ui_inst:-unknown}" >&2
    echo "Nothing was changed. Re-run with --yes to upgrade to these versions, or pass --api-version=<ver> / --ui-version=<ver>." >&2
    return 2
  fi
}

download::fetch() {
  log::step "Downloading ClusterEye artifacts"
  download::_fetch_api
  download::_fetch_ui
  log::ok "All artifacts downloaded"
}

# Verify a downloaded file against a published .sha256 sidecar.
# A missing sidecar is not fatal — older mirrored versions may not have one.
download::_verify_sha256() {
  local file="$1" sum_url="$2" expected actual
  expected=$(curl -fsSL --retry 2 "$sum_url" 2>/dev/null | awk '{print $1}') || return 0
  [[ -n "$expected" ]] || return 0
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]]
}

download::_fetch_api() {
  download::_stage_api
  download::_install_staged_api
}

# Downloads and verifies the API binary to ${BINARY_DEST}.new without touching
# the running binary, so upgrade.sh can fetch before it stops the service.
download::_stage_api() {
  local base="${API_RELEASE_BASE}/v${CE_API_VERSION}"
  log::info "Downloading API binary v${CE_API_VERSION}..."

  # Preferred: gzipped binary. The raw binary exceeds GitHub's 100MB per-file
  # limit and can no longer be mirrored, so newer versions ship only as .gz.
  # Fall back to the plain binary for versions mirrored before that change.
  local workdir
  workdir=$(mktemp -d)

  if curl -fL --retry 3 --retry-delay 2 -o "$workdir/clustereye-api.gz" "${base}/clustereye-api.gz"; then
    download::_verify_sha256 "$workdir/clustereye-api.gz" "${base}/clustereye-api.gz.sha256" || {
      rm -rf "$workdir"; die "Checksum mismatch for clustereye-api.gz"; }

    if ! gzip -dc "$workdir/clustereye-api.gz" > "${BINARY_DEST}.new"; then
      rm -rf "$workdir"
      die "Failed to decompress API binary"
    fi

    download::_verify_sha256 "${BINARY_DEST}.new" "${base}/clustereye-api.sha256" || {
      rm -f "${BINARY_DEST}.new"; rm -rf "$workdir"; die "Checksum mismatch for clustereye-api"; }
  elif ! curl -fL --retry 3 --retry-delay 2 -o "${BINARY_DEST}.new" "${base}/clustereye-api"; then
    rm -rf "$workdir"
    die "Failed to download API binary from ${base}/clustereye-api[.gz]"
  fi

  rm -rf "$workdir"

  chmod 0755 "${BINARY_DEST}.new"
  log::ok "API binary v${CE_API_VERSION} downloaded and verified"
}

download::_install_staged_api() {
  mv -f "${BINARY_DEST}.new" "$BINARY_DEST"
  chown root:root "$BINARY_DEST"
  log::ok "API binary installed: $BINARY_DEST (v${CE_API_VERSION})"
}

download::_fetch_ui() {
  local url="${UI_RELEASE_BASE}/v${CE_UI_VERSION}/clustereye.tar.gz"
  local workdir
  workdir=$(mktemp -d)
  log::info "Downloading UI assets v${CE_UI_VERSION}..."

  if ! curl -fL --retry 3 --retry-delay 2 -o "$workdir/clustereye.tar.gz" "$url"; then
    rm -rf "$workdir"
    die "Failed to download UI assets from $url"
  fi

  # Clean previous contents
  find "$FRONTEND_DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  if ! tar -xzf "$workdir/clustereye.tar.gz" -C "$FRONTEND_DEST" --strip-components=0; then
    rm -rf "$workdir"
    die "Failed to extract UI assets"
  fi
  chown -R root:root "$FRONTEND_DEST"
  rm -rf "$workdir"
  log::ok "UI assets installed: $FRONTEND_DEST (v${CE_UI_VERSION})"
}
