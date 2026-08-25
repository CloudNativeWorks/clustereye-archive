#!/usr/bin/env bash
# verify.sh — Post-install health checks and summary

verify::wait() {
  log::step "Running health checks"

  local all_ok=true

  # Check API HTTP port
  if wait_for_tcp 127.0.0.1 8080 30; then
    log::ok "API HTTP port (8080) is listening"
  else
    log::warn "API HTTP port (8080) is not responding"
    all_ok=false
  fi

  # Check API gRPC port
  if wait_for_tcp 127.0.0.1 50051 30; then
    log::ok "API gRPC port (50051) is listening"
  else
    log::warn "API gRPC port (50051) is not responding"
    all_ok=false
  fi

  # Check nginx HTTPS
  local port="${CE_PORT:-443}"
  if curl -sfk --max-time 10 "https://127.0.0.1:${port}/" -o /dev/null 2>/dev/null; then
    log::ok "nginx HTTPS (port $port) is responding"
  else
    log::warn "nginx HTTPS (port $port) is not responding"
    all_ok=false
  fi

  # Check nginx HTTP/h2c (if enabled)
  local http_port="${CE_HTTP_PORT:-80}"
  if [[ "$http_port" != "none" && "$http_port" != "0" ]]; then
    if curl -sf --max-time 10 "http://127.0.0.1:${http_port}/" -o /dev/null 2>/dev/null; then
      log::ok "nginx HTTP (port $http_port) is responding"
    else
      log::warn "nginx HTTP (port $http_port) is not responding"
      all_ok=false
    fi
  fi

  if [[ "$all_ok" == "true" ]]; then
    log::ok "All health checks passed"
  else
    log::warn "Some health checks failed — check service logs"
  fi
}

verify::print_summary() {
  local port="${CE_PORT:-443}"
  local http_port="${CE_HTTP_PORT:-80}"
  local display_host="${CE_DOMAIN:-<your-server-ip>}"

  local port_suffix=""
  if [[ "$port" != "443" ]]; then
    port_suffix=":${port}"
  fi
  local http_suffix=""
  if [[ "$http_port" != "80" ]]; then
    http_suffix=":${http_port}"
  fi

  local plain_section=""
  if [[ "$http_port" != "none" && "$http_port" != "0" ]]; then
    plain_section="
  Plain UI:   http://${display_host}${http_suffix}
  Plain API:  http://${display_host}${http_suffix}  (header: CEFE: Yes)
  Plain gRPC: http://${display_host}${http_suffix}  (h2c, no TLS)"
  fi

  cat <<EOF

${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗
║              ClusterEye Installation Complete              ║
╚═══════════════════════════════════════════════════════════╝${NC}

${BOLD}Access URLs:${NC}
  UI:    https://${display_host}${port_suffix}
  API:   https://${display_host}${port_suffix}  (header: CEFE: Yes)
  gRPC:  https://${display_host}${port_suffix}  (agent connections, same port)${plain_section}

${BOLD}Versions:${NC}
  API:   v${CE_API_VERSION}
  UI:    v${CE_UI_VERSION}

${BOLD}Components:${NC}
  PostgreSQL:  ${CE_POSTGRES}
  InfluxDB:    ${CE_INFLUXDB}

${BOLD}Configuration Files:${NC}
  API Config:    /etc/clustereye/server.yml
  Secrets:       /etc/clustereye/secrets.env
  UI Config:     /usr/share/clustereye/web/config.js
  TLS Cert:      /etc/clustereye/tls/server.crt
  TLS Key:       /etc/clustereye/tls/server.key
  nginx:         /etc/nginx/conf.d/clustereye.conf

${BOLD}DB/InfluxDB bilgilerini sonradan degistirmek icin:${NC}
  sudo nano /etc/clustereye/secrets.env
  sudo systemctl restart clustereye-api

${BOLD}Common Commands:${NC}
  Status:    sudo systemctl status clustereye-api
  Logs:      sudo journalctl -u clustereye-api -f
  Restart:   sudo systemctl restart clustereye-api
  nginx:     sudo systemctl status nginx

${BOLD}Upgrade:${NC}
  sudo ./upgrade.sh --api-version=X.Y.Z --ui-version=X.Y.Z

${BOLD}Uninstall:${NC}
  sudo ./uninstall.sh [--purge] [--purge-db] [--purge-influxdb]

EOF
}
