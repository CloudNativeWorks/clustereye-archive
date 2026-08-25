#!/usr/bin/env bash
# download.sh — Download API binary and UI assets from the public ClusterEye archive
# Source repos (clustereye-api, clustereye) are private; artifacts are mirrored to
# archive.clustereye.com by the archive's pull workflow (update-standalone-artifacts.yml).

readonly API_RELEASE_BASE="https://archive.clustereye.com/downloads/api"
readonly UI_RELEASE_BASE="https://archive.clustereye.com/downloads/ui"
readonly BINARY_DEST="/usr/local/bin/clustereye-api"
readonly FRONTEND_DEST="/usr/share/clustereye/web"

download::fetch() {
  log::step "Downloading ClusterEye artifacts"
  download::_fetch_api
  download::_fetch_ui
  log::ok "All artifacts downloaded"
}

download::_fetch_api() {
  local url="${API_RELEASE_BASE}/v${CE_API_VERSION}/clustereye-api"
  log::info "Downloading API binary v${CE_API_VERSION}..."

  if ! curl -fL --retry 3 --retry-delay 2 -o "${BINARY_DEST}.new" "$url"; then
    die "Failed to download API binary from $url"
  fi

  chmod 0755 "${BINARY_DEST}.new"
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
