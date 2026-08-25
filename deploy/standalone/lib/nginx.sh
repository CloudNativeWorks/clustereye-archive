#!/usr/bin/env bash
# nginx.sh — Install, configure, and manage nginx reverse proxy

readonly NGINX_CONF="/etc/nginx/conf.d/clustereye.conf"
readonly NGINX_LOCATIONS_INC="/etc/clustereye/nginx-locations.inc"
readonly NGINX_MARKER="/var/lib/clustereye/.nginx-installed-by-ce"

nginx::setup() {
  log::step "Configuring nginx"
  nginx::_install_package
  nginx::_render_locations
  nginx::_render_conf
  nginx::_disable_default_site
  nginx::_validate
  nginx::_enable_and_reload
  log::ok "nginx configured and running"
}

nginx::_install_package() {
  if command -v nginx &>/dev/null; then
    log::info "nginx already installed"
    return 0
  fi

  log::info "Installing nginx..."
  case "$CE_OS_FAMILY" in
    debian)
      apt::install nginx
      ;;
    rhel)
      dnf install -y -q nginx
      ;;
  esac

  # Mark that we installed nginx (for uninstall)
  touch "$NGINX_MARKER"
  log::info "nginx installed"
}

nginx::_render_locations() {
  local src="${CE_SCRIPT_DIR}/templates/nginx-locations.inc"
  install -m 0644 -o root -g root "$src" "$NGINX_LOCATIONS_INC"
  log::info "nginx locations: $NGINX_LOCATIONS_INC"
}

nginx::_render_conf() {
  local main_tmpl="${CE_SCRIPT_DIR}/templates/nginx.conf"
  local http_tmpl="${CE_SCRIPT_DIR}/templates/nginx-http-block.conf"

  export CE_PORT="${CE_PORT:-443}"
  export CE_HTTP_PORT="${CE_HTTP_PORT:-80}"

  # Render the new config to a temp path first so we can compare against
  # whatever is currently on disk.
  local new_conf
  new_conf=$(mktemp)
  nginx::_compose_conf "$new_conf" "$main_tmpl" "$http_tmpl"

  if [[ -f "$NGINX_CONF" ]] && cmp -s "$new_conf" "$NGINX_CONF"; then
    log::info "nginx config already up-to-date: $NGINX_CONF"
    rm -f "$new_conf"
    return 0
  fi

  if [[ -f "$NGINX_CONF" ]]; then
    local bak="${NGINX_CONF}.bak.$(date +%s)"
    cp -p "$NGINX_CONF" "$bak"
    log::info "Backed up previous nginx config to $bak"
  fi

  install -m 0644 -o root -g root "$new_conf" "$NGINX_CONF"
  rm -f "$new_conf"
  log::info "nginx config written: $NGINX_CONF (HTTPS=${CE_PORT}, HTTP=${CE_HTTP_PORT})"
}

# True when the host can actually bind an IPv6 socket. Covers both
# ipv6.disable=1 (no /proc/net/if_inet6) and the disable_ipv6 sysctl
# (file exists but [::] binds fail with EADDRNOTAVAIL).
nginx::_ipv6_available() {
  [[ -e /proc/net/if_inet6 ]] || return 1
  local v
  v=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
  [[ "$v" == "0" ]]
}

nginx::_compose_conf() {
  local dest="$1" main_tmpl="$2" http_tmpl="$3"

  if nginx::_ipv6_available; then
    export CE_LISTEN_V6_SSL="listen [::]:${CE_PORT} ssl http2;"
    export CE_LISTEN_V6_HTTP="listen [::]:${CE_HTTP_PORT} http2;"
  else
    log::info "IPv6 not available on this host — skipping [::] listeners"
    export CE_LISTEN_V6_SSL="# IPv6 disabled on host — no [::] listener"
    export CE_LISTEN_V6_HTTP="# IPv6 disabled on host — no [::] listener"
  fi

  # HSTS is only safe when there's no plaintext companion port — see the
  # comment in templates/nginx.conf for the rationale.
  if [[ "${CE_HTTP_PORT}" == "none" || "${CE_HTTP_PORT}" == "0" ]]; then
    export CE_HSTS_HEADER='add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'
  else
    export CE_HSTS_HEADER='# HSTS disabled (--http-port enabled)'
  fi

  envsubst '$CE_PORT $CE_HSTS_HEADER $CE_LISTEN_V6_SSL' < "$main_tmpl" > "${dest}.tmp"

  if [[ "${CE_HTTP_PORT}" != "none" && "${CE_HTTP_PORT}" != "0" ]]; then
    printf "\n" >> "${dest}.tmp"
    envsubst '$CE_HTTP_PORT $CE_LISTEN_V6_HTTP' < "$http_tmpl" >> "${dest}.tmp"
  fi

  mv -f "${dest}.tmp" "$dest"
}

nginx::_disable_default_site() {
  # Debian/Ubuntu: remove sites-enabled/default (symlink or file).
  # Even if symlink-only, removing it stops nginx from loading the default
  # site, but if anything later re-creates the symlink (e.g. apt reinstall)
  # the underlying sites-available/default would be active again — so we
  # disable the source file too.
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    log::info "Disabled /etc/nginx/sites-enabled/default"
  fi

  if [[ -f /etc/nginx/sites-available/default ]]; then
    mv /etc/nginx/sites-available/default \
       /etc/nginx/sites-available/default.disabled-by-clustereye
    log::info "Disabled /etc/nginx/sites-available/default (renamed)"
  fi

  # Debian/Ubuntu: rename conf.d/default.conf if any nginx package shipped one
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled-by-clustereye
    log::info "Disabled /etc/nginx/conf.d/default.conf (renamed to .disabled-by-clustereye)"
  fi

  # Generic safety net: scan for any non-clustereye config that listens on
  # the plaintext HTTP port we are about to use, and disable those files so
  # they don't fight our server block over the bind. Touch only the well-
  # known default-site filenames to avoid disabling user-added sites.
  local http_port="${CE_HTTP_PORT:-80}"
  if [[ "$http_port" != "none" && "$http_port" != "0" ]]; then
    local f
    for f in \
      /etc/nginx/conf.d/default.conf \
      /etc/nginx/sites-enabled/default \
      /etc/nginx/sites-available/default; do
      [[ -e "$f" ]] || continue
      if grep -qE "^\s*listen\s+(\[::\]:)?${http_port}\b" "$f" 2>/dev/null; then
        mv "$f" "${f}.disabled-by-clustereye"
        log::info "Disabled $f (was listening on port ${http_port})"
      fi
    done
  fi

  # RHEL/Oracle: comment out default server block in nginx.conf
  if [[ "$CE_OS_FAMILY" == "rhel" ]]; then
    local main_conf="/etc/nginx/nginx.conf"
    if [[ -f "$main_conf" ]] && grep -q "listen.*80.*default_server" "$main_conf" 2>/dev/null; then
      # Backup before modifying
      cp "$main_conf" "${main_conf}.bak.$(date +%s)"
      # Comment out the server block that listens on port 80
      sed -i '/^[[:space:]]*server {/,/^[[:space:]]*}/{
        /listen.*80.*default_server/s/^/#/
      }' "$main_conf"
      log::info "Commented default server block in nginx.conf (RHEL)"
    fi
  fi
}

nginx::_validate() {
  if ! nginx -t 2>/dev/null; then
    log::err "nginx configuration test failed"
    nginx -t 2>&1 | while IFS= read -r line; do log::err "  $line"; done

    # Self-heal: move broken config aside
    if [[ -f "$NGINX_CONF" ]]; then
      local broken="${NGINX_CONF}.broken.$(date +%s)"
      mv "$NGINX_CONF" "$broken"
      log::warn "Moved broken config to $broken"
    fi
    die "Fix the nginx configuration and re-run the installer"
  fi
  log::info "nginx configuration test passed"
}

nginx::_enable_and_reload() {
  systemctl enable nginx 2>/dev/null || true

  # Restart (not reload) — graceful reload keeps old workers bound to old
  # ports, so port changes (e.g. --http-port) cause "Address already in use".
  if systemctl is-active --quiet nginx; then
    systemctl stop nginx 2>/dev/null || true
  fi

  local i
  for i in 1 2 3 4 5; do
    if systemctl start nginx 2>/dev/null; then
      log::info "nginx started"
      return 0
    fi
    log::warn "nginx start failed (attempt $i/5) — old workers may still be releasing ports, retrying in 1s..."
    sleep 1
  done

  log::err "$(systemctl status nginx --no-pager 2>&1 | head -20)"
  die "Failed to start nginx after 5 attempts. Check: journalctl -u nginx"
}
