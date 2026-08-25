#!/usr/bin/env bash
# firewall.sh — Open ports in active firewall (if any)
# Does nothing if no firewall is active or detected.

firewall::open() {
  if [[ "${CE_NO_FIREWALL:-0}" == "1" ]]; then
    log::info "Skipping firewall configuration (--no-firewall)"
    return 0
  fi

  local -a ports=("${CE_PORT:-443}")
  local http_port="${CE_HTTP_PORT:-80}"
  if [[ "$http_port" != "none" && "$http_port" != "0" ]]; then
    ports+=("$http_port")
  fi

  # Only touch firewall if it's actively running — never enable or start it
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    log::step "Configuring firewall"
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}/tcp" 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    log::ok "firewalld: opened ports ${ports[*]}/tcp"
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    log::step "Configuring firewall"
    for p in "${ports[@]}"; do
      ufw allow "${p}/tcp" 2>/dev/null || true
    done
    log::ok "ufw: opened ports ${ports[*]}/tcp"
  fi
  # No firewall active — do nothing, don't even log
}
