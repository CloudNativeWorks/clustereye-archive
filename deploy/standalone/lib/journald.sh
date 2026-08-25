#!/usr/bin/env bash
# journald.sh — Configure journal retention for ClusterEye

journald::configure() {
  log::step "Configuring journald retention"

  local dropin_dir="/etc/systemd/journald.conf.d"
  local dropin="${dropin_dir}/10-clustereye.conf"
  local template="${CE_SCRIPT_DIR}/templates/journald-clustereye.conf"

  mkdir -p "$dropin_dir"

  if [[ -f "$dropin" ]]; then
    log::info "Existing journald drop-in found — preserving"
    return 0
  fi

  cp "$template" "$dropin"
  chmod 0644 "$dropin"

  systemctl restart systemd-journald 2>/dev/null || true
  log::ok "journald retention configured"
}
