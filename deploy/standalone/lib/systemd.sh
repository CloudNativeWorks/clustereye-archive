#!/usr/bin/env bash
# systemd.sh — Install and manage clustereye-api systemd service

readonly SERVICE_NAME="clustereye-api"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

systemd::install() {
  log::step "Installing systemd service"

  local template="${CE_SCRIPT_DIR}/templates/clustereye-api.service"
  local unit_content
  unit_content=$(cat "$template")

  # Strip postgresql.service from After= if external
  if [[ "${CE_POSTGRES}" == "external" ]]; then
    unit_content=$(echo "$unit_content" | sed 's/ postgresql\.service//')
  fi

  # Strip influxdb.service from After= if not local
  if [[ "${CE_INFLUXDB}" != "local" ]]; then
    unit_content=$(echo "$unit_content" | sed 's/ influxdb\.service//')
  fi

  echo "$unit_content" > "$SERVICE_FILE"
  chmod 0644 "$SERVICE_FILE"
  chown root:root "$SERVICE_FILE"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  # Wait for the service to start
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log::ok "Service $SERVICE_NAME started successfully"
  else
    log::warn "Service $SERVICE_NAME may not have started cleanly — check: journalctl -u $SERVICE_NAME"
  fi
}
