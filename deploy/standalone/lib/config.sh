#!/usr/bin/env bash
# config.sh — Render server.yml and config.js from templates

config::render() {
  log::step "Rendering configuration files"
  config::_render_server_yml
  config::_render_config_js
  config::_create_symlink
  log::ok "Configuration files ready"
}

config::_render_server_yml() {
  local dest="/etc/clustereye/server.yml"
  local template="${CE_SCRIPT_DIR}/templates/server.yml.tmpl"

  if [[ -f "$dest" ]]; then
    log::info "Existing server.yml found — writing fresh template to ${dest}.example"
    # Render example with current values for reference
    config::_load_secrets_env
    render_template "$template" "${dest}.example" \
      '$DB_HOST $DB_PORT $DB_USER $DB_PASSWORD $DB_NAME $DB_SSLMODE $INFLUXDB_URL $INFLUXDB_TOKEN $INFLUXDB_ORG $INFLUXDB_BUCKET $INFLUXDB_ENABLED $CLICKHOUSE_ADDR $CLICKHOUSE_DATABASE $CLICKHOUSE_USERNAME $CLICKHOUSE_PASSWORD $CLICKHOUSE_ENABLED'
    return 0
  fi

  # Load DB/InfluxDB values from secrets.env to render into server.yml
  config::_load_secrets_env

  render_template "$template" "$dest" \
    '$DB_HOST $DB_PORT $DB_USER $DB_PASSWORD $DB_NAME $DB_SSLMODE $INFLUXDB_URL $INFLUXDB_TOKEN $INFLUXDB_ORG $INFLUXDB_BUCKET $INFLUXDB_ENABLED $CLICKHOUSE_ADDR $CLICKHOUSE_DATABASE $CLICKHOUSE_USERNAME $CLICKHOUSE_PASSWORD $CLICKHOUSE_ENABLED'
  chown clustereye:clustereye "$dest"
  chmod 0640 "$dest"
  log::info "Created: $dest"
}

config::_load_secrets_env() {
  # Source secrets.env to get DB/InfluxDB values for template rendering
  if [[ -f /etc/clustereye/secrets.env ]]; then
    set +u
    # shellcheck source=/dev/null
    source /etc/clustereye/secrets.env
    set -u
    export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_SSLMODE
    export INFLUXDB_URL INFLUXDB_TOKEN INFLUXDB_ORG INFLUXDB_BUCKET INFLUXDB_ENABLED
    export CLICKHOUSE_ADDR CLICKHOUSE_DATABASE CLICKHOUSE_USERNAME CLICKHOUSE_PASSWORD CLICKHOUSE_ENABLED
  fi
}

config::_render_config_js() {
  local dest="/usr/share/clustereye/web/config.js"
  local template="${CE_SCRIPT_DIR}/templates/config.js.tmpl"

  local port_suffix=""
  if [[ "${CE_PORT:-443}" != "443" ]]; then
    port_suffix=":${CE_PORT}"
  fi

  export CE_DISPLAY_HOST="${CE_DOMAIN}"
  export CE_PORT_SUFFIX="$port_suffix"
  export CE_UI_VERSION="${CE_UI_VERSION}"

  render_template "$template" "$dest" '$CE_DISPLAY_HOST $CE_PORT_SUFFIX $CE_UI_VERSION'
  chown root:root "$dest"
  chmod 0644 "$dest"
  log::info "Created: $dest"
}

config::_create_symlink() {
  # API binary reads config from WorkingDirectory/server.yml
  # WorkingDirectory is /var/lib/clustereye — create symlink
  local link="/var/lib/clustereye/server.yml"
  local target="/etc/clustereye/server.yml"

  if [[ -L "$link" ]]; then
    rm -f "$link"
  fi
  ln -sf "$target" "$link"
  log::info "Symlinked: $link -> $target"
}
