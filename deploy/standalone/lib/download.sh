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
