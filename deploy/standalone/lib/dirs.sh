#!/usr/bin/env bash
# dirs.sh — Create and verify directory structure

dirs::ensure() {
  log::step "Creating directory structure"

  install -d -m 0755 -o root -g root /usr/share/clustereye/web
  install -d -m 0750 -o clustereye -g clustereye /etc/clustereye
  install -d -m 0755 -o root -g root /etc/clustereye/tls
  install -d -m 0750 -o clustereye -g clustereye /var/lib/clustereye
  install -d -m 0750 -o clustereye -g clustereye /var/log/clustereye

  log::ok "Directory structure ready"
}

dirs::verify() {
  log::step "Verifying directory permissions"

  local errors=0
  _check_dir() {
    local path="$1" owner="$2" mode="$3"
    if [[ ! -d "$path" ]]; then
      log::err "Missing directory: $path"
      errors=$((errors + 1))
      return
    fi
    local actual_owner actual_mode
    actual_owner=$(stat -c '%U:%G' "$path" 2>/dev/null)
    actual_mode=$(stat -c '%a' "$path" 2>/dev/null)
    if [[ "$actual_owner" != "$owner" ]]; then
      log::warn "Fixing ownership on $path: $actual_owner -> $owner"
      chown "$owner" "$path"
    fi
  }

  _check_dir /etc/clustereye          "clustereye:clustereye" "750"
  _check_dir /etc/clustereye/tls      "root:root"            "755"
  _check_dir /var/lib/clustereye      "clustereye:clustereye" "750"
  _check_dir /var/log/clustereye      "clustereye:clustereye" "750"
  _check_dir /usr/share/clustereye/web "root:root"            "755"

  if [[ $errors -gt 0 ]]; then
    die "Directory verification failed with $errors errors"
  fi
  log::ok "Directory permissions verified"
}
