#!/usr/bin/env bash
# postgresql.sh — Install local PostgreSQL or configure external connection

readonly PG_MAJOR="16"

postgresql::setup() {
  log::step "Configuring PostgreSQL"

  case "$CE_POSTGRES" in
    local)    postgresql::_install_local ;;
    external) postgresql::_configure_external ;;
    *) die "Invalid --postgres value: $CE_POSTGRES (expected: local|external)" ;;
  esac
}

postgresql::_add_pgdg_debian() {
  local list=/etc/apt/sources.list.d/pgdg.list
  local setup_script=/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
  local codename
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  [[ -n "$codename" ]] || die "Cannot detect Debian/Ubuntu codename for PGDG repo."

  if [[ -f "$list" ]] && postgresql::_pgdg_repo_reachable; then
    return 0
  fi

  log::info "Adding PGDG apt repository via official setup script..."
  apt::install postgresql-common ca-certificates curl gnupg lsb-release

  if [[ ! -x "$setup_script" ]]; then
    die "PGDG setup script not found at $setup_script (postgresql-common install failed?)"
  fi

  # -y: non-interactive (do NOT use -i, which requires -v VERSION)
  DEBIAN_FRONTEND=noninteractive "$setup_script" -y \
    || die "PGDG repository setup failed"

  # Fallback: PGDG drops EOL distros from the main mirror (e.g. focal after
  # 2025-04). The official script still writes apt.postgresql.org, but apt-get
  # update will 404. Switch to apt-archive.postgresql.org which keeps EOL dists.
  if ! postgresql::_pgdg_repo_reachable; then
    log::warn "PGDG main mirror has no '${codename}-pgdg' (likely EOL) — switching to apt-archive"
    sed -i 's|//apt\.postgresql\.org|//apt-archive.postgresql.org|g' "$list"
    if ! postgresql::_pgdg_repo_reachable; then
      die "Neither apt.postgresql.org nor apt-archive.postgresql.org has '${codename}-pgdg'. Upgrade the OS or pin a different PG_MAJOR."
    fi
    log::ok "Using PGDG archive mirror for ${codename}-pgdg"
  fi
}

postgresql::_pgdg_repo_reachable() {
  # Refresh only the pgdg list and look for failures on the pgdg lines
  local out
  out=$(apt-get update \
          -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/pgdg.list \
          -o Dir::Etc::sourceparts=- \
          -o APT::Get::List-Cleanup=0 \
          2>&1) || return 1
  ! echo "$out" | grep -qE '^(E|Err):.*pgdg'
}

postgresql::_add_pgdg_rhel() {
  local rhel_major
  rhel_major=$(rpm -E '%{rhel}' 2>/dev/null || echo "")
  [[ -n "$rhel_major" ]] || die "Cannot detect RHEL major version for PGDG repo."

  if rpm -q pgdg-redhat-repo &>/dev/null; then
    return 0
  fi

  log::info "Adding PGDG dnf repository (rhel=$rhel_major)..."
  dnf install -y -q \
    "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${rhel_major}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
  dnf -qy module disable postgresql 2>/dev/null || true
}

postgresql::_install_local() {
  log::info "Installing local PostgreSQL ${PG_MAJOR}..."

  case "$CE_OS_FAMILY" in
    debian)
      postgresql::_add_pgdg_debian
      apt::install "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}"
      # Ensure a cluster exists (e.g. after purge+reinstall)
      if [[ ! -d "/var/lib/postgresql/${PG_MAJOR}/main" ]]; then
        log::info "Creating PostgreSQL ${PG_MAJOR} cluster..."
        pg_createcluster "$PG_MAJOR" main --start 2>/dev/null || true
      fi
      CE_PG_SERVICE="postgresql"
      ;;
    rhel)
      postgresql::_add_pgdg_rhel
      dnf install -y -q "postgresql${PG_MAJOR}-server" "postgresql${PG_MAJOR}"
      if [[ ! -f "/var/lib/pgsql/${PG_MAJOR}/data/PG_VERSION" ]]; then
        "/usr/pgsql-${PG_MAJOR}/bin/postgresql-${PG_MAJOR}-setup" initdb 2>/dev/null || true
      fi
      CE_PG_SERVICE="postgresql-${PG_MAJOR}"
      ;;
  esac

  systemctl enable "$CE_PG_SERVICE" 2>/dev/null
  systemctl start "$CE_PG_SERVICE" 2>/dev/null

  # Wait for PostgreSQL to be ready
  local retries=0
  while ! sudo -u postgres pg_isready -q 2>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 60 ]]; then
      log::err "PostgreSQL failed to start after 60s"
      log::err "$(systemctl status "${CE_PG_SERVICE:-postgresql}" 2>&1 | head -20)"
      die "PostgreSQL failed to start — check: journalctl -u ${CE_PG_SERVICE:-postgresql}"
    fi
    sleep 1
  done
  log::info "PostgreSQL is ready (waited ${retries}s)"

  # Generate password
  local db_password
  db_password=$(rand_hex 16)

  # Escape single quotes for SQL safety
  local escaped_password="${db_password//\'/\'\'}"

  # Create user and database (idempotent)
  sudo -u postgres psql -v ON_ERROR_STOP=0 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'clustereye') THEN
    CREATE ROLE clustereye WITH LOGIN SUPERUSER PASSWORD '${escaped_password}';
  ELSE
    ALTER ROLE clustereye WITH LOGIN SUPERUSER PASSWORD '${escaped_password}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE clustereye OWNER clustereye'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'clustereye')\gexec
SQL

  # Ensure pg_hba.conf allows md5 auth for clustereye user
  postgresql::_configure_hba

  # Reload PostgreSQL to apply pg_hba changes
  systemctl reload "${CE_PG_SERVICE:-postgresql}"

  # Write credentials to secrets.env
  secrets::write_db_fields "localhost" "5432" "clustereye" "$db_password" "clustereye" "disable"

  log::ok "Local PostgreSQL configured (user=clustereye, db=clustereye)"
}

postgresql::_configure_hba() {
  local hba_file=""

  # Find pg_hba.conf location (varies by distro)
  if [[ "$CE_OS_FAMILY" == "debian" ]]; then
    hba_file="/etc/postgresql/${PG_MAJOR}/main/pg_hba.conf"
    [[ -f "$hba_file" ]] || hba_file=$(find /etc/postgresql -name pg_hba.conf -type f 2>/dev/null | head -1)
  else
    hba_file="/var/lib/pgsql/${PG_MAJOR}/data/pg_hba.conf"
  fi

  if [[ -z "$hba_file" || ! -f "$hba_file" ]]; then
    log::warn "Could not locate pg_hba.conf, skipping HBA configuration"
    return 0
  fi

  # Add md5 auth for clustereye user if not already present
  if ! grep -q "clustereye" "$hba_file" 2>/dev/null; then
    # Insert before the first existing rule
    sed -i "/^# IPv4 local connections/a host    clustereye      clustereye      127.0.0.1/32            md5" "$hba_file" 2>/dev/null || \
      echo "host    clustereye      clustereye      127.0.0.1/32            md5" >> "$hba_file"
    log::info "Added pg_hba.conf entry for clustereye"
  fi
}

postgresql::_configure_external() {
  local host="${CE_POSTGRES_HOST:-CHANGE_ME}"
  local port="${CE_POSTGRES_PORT:-5432}"
  local user="${CE_POSTGRES_USER:-postgres}"
  local password="${CE_POSTGRES_PASSWORD:-CHANGE_ME}"
  local dbname="${CE_POSTGRES_DBNAME:-clustereye}"
  local sslmode="${CE_POSTGRES_SSLMODE:-disable}"

  secrets::write_db_fields "$host" "$port" "$user" "$password" "$dbname" "$sslmode"

  if [[ "$host" == "CHANGE_ME" || "$password" == "CHANGE_ME" ]]; then
    log::warn "External PostgreSQL: placeholder values written to $SECRETS_FILE"
    log::warn "Update DB_HOST and DB_PASSWORD in $SECRETS_FILE before starting the service"
  else
    log::ok "External PostgreSQL configured (host=$host, db=$dbname)"
  fi
}
