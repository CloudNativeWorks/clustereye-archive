#!/usr/bin/env bash
# user.sh — Create clustereye system user and group

user::ensure() {
  log::step "Ensuring clustereye system user"

  if ! getent group clustereye &>/dev/null; then
    groupadd --system clustereye
    log::info "Created group: clustereye"
  fi

  if ! getent passwd clustereye &>/dev/null; then
    useradd \
      --system \
      --gid clustereye \
      --home-dir /var/lib/clustereye \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --comment "ClusterEye service account" \
      clustereye
    log::info "Created user: clustereye"
  fi

  log::ok "System user ready"
}
