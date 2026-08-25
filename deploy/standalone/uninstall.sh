#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# ClusterEye Standalone Uninstaller
#
# Usage:
#   sudo ./uninstall.sh                              # Remove service only
#   sudo ./uninstall.sh --purge                      # Remove everything except databases
#   sudo ./uninstall.sh --purge --purge-db           # Also remove PostgreSQL
#   sudo ./uninstall.sh --purge --purge-influxdb     # Also remove InfluxDB
#   sudo ./uninstall.sh --purge --purge-clickhouse   # Also remove ClickHouse
#   sudo ./uninstall.sh --purge --purge-db --purge-influxdb --purge-clickhouse --yes-i-mean-it
# ─────────────────────────────────────────────────────────────
set -Euo pipefail

PURGE=false
PURGE_DB=false
PURGE_INFLUX=false
PURGE_CLICKHOUSE=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)             PURGE=true ;;
    --purge-db)          PURGE_DB=true ;;
    --purge-influxdb)    PURGE_INFLUX=true ;;
    --purge-clickhouse)  PURGE_CLICKHOUSE=true ;;
    --yes-i-mean-it)     FORCE=true ;;
    -h|--help)
      echo "Usage: $0 [--purge] [--purge-db] [--purge-influxdb] [--purge-clickhouse] [--yes-i-mean-it]"
      echo ""
      echo "Default:             Remove binary, systemd unit, nginx config, journald drop-in"
      echo "                     Preserves: config, secrets, TLS, databases"
      echo "--purge:             Also remove /etc/clustereye, /var/lib/clustereye, /var/log/clustereye, user/group, nginx config"
      echo "--purge-db:          Also remove local PostgreSQL packages and data"
      echo "--purge-influxdb:    Also remove local InfluxDB packages and data"
      echo "--purge-clickhouse:  Also remove local ClickHouse packages and data (per-query metric store)"
      echo "--yes-i-mean-it:     Skip confirmation prompts"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

log_info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }

# Root check
if [[ $EUID -ne 0 ]]; then
  log_err "This script must be run as root (use sudo)."
  exit 1
fi

# Confirmation
if [[ "$FORCE" != "true" ]]; then
  echo ""
  echo -e "${BOLD}ClusterEye will be uninstalled with the following options:${NC}"
  echo "  Purge config/data:  $PURGE"
  echo "  Purge PostgreSQL:   $PURGE_DB"
  echo "  Purge InfluxDB:     $PURGE_INFLUX"
  echo "  Purge ClickHouse:   $PURGE_CLICKHOUSE"
  echo ""
  read -rp "Are you sure? (y/N) " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Stop and disable ClusterEye API ────────────────────────
log_info "Stopping ClusterEye API service..."
systemctl stop clustereye-api 2>/dev/null || true
systemctl disable clustereye-api 2>/dev/null || true

# ── Remove binary ──────────────────────────────────────────
if [[ -f /usr/local/bin/clustereye-api ]]; then
  rm -f /usr/local/bin/clustereye-api
  log_info "Removed: /usr/local/bin/clustereye-api"
fi

# ── Remove systemd unit ────────────────────────────────────
if [[ -f /etc/systemd/system/clustereye-api.service ]]; then
  rm -f /etc/systemd/system/clustereye-api.service
  systemctl daemon-reload
  log_info "Removed: systemd unit"
fi

# ── Remove nginx config ────────────────────────────────────
rm -f /etc/nginx/conf.d/clustereye.conf
rm -f /etc/nginx/conf.d/clustereye.conf.example
rm -f /etc/nginx/conf.d/clustereye.conf.broken.*
if systemctl is-active --quiet nginx 2>/dev/null; then
  systemctl reload nginx 2>/dev/null || true
fi
log_info "Removed: nginx config"

# ── Remove journald drop-in ────────────────────────────────
if [[ -f /etc/systemd/journald.conf.d/10-clustereye.conf ]]; then
  rm -f /etc/systemd/journald.conf.d/10-clustereye.conf
  systemctl restart systemd-journald 2>/dev/null || true
  log_info "Removed: journald drop-in"
fi

# ── Remove server.yml symlink from WorkingDirectory ────────
rm -f /var/lib/clustereye/server.yml 2>/dev/null || true

# ── Purge: config, data, logs, web, user ───────────────────
if [[ "$PURGE" == "true" ]]; then
  rm -rf /usr/share/clustereye
  log_info "Removed: /usr/share/clustereye (web assets)"

  rm -rf /etc/clustereye
  log_info "Removed: /etc/clustereye (config, secrets, TLS)"

  rm -rf /var/lib/clustereye
  log_info "Removed: /var/lib/clustereye (state)"

  rm -rf /var/log/clustereye
  log_info "Removed: /var/log/clustereye (logs)"

  # Remove user and group
  if getent passwd clustereye &>/dev/null; then
    userdel clustereye 2>/dev/null || true
    log_info "Removed: user clustereye"
  fi
  if getent group clustereye &>/dev/null; then
    groupdel clustereye 2>/dev/null || true
    log_info "Removed: group clustereye"
  fi
fi

# ── Purge PostgreSQL ───────────────────────────────────────
if [[ "$PURGE_DB" == "true" ]]; then
  log_warn "Removing local PostgreSQL..."

  # Stop all PostgreSQL services
  systemctl stop 'postgresql*' 2>/dev/null || true
  systemctl disable postgresql 2>/dev/null || true

  if command -v apt-get &>/dev/null; then
    # Drop the clustereye database and user before removing package
    if command -v psql &>/dev/null && sudo -u postgres psql -c "SELECT 1" &>/dev/null 2>&1; then
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS clustereye;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP ROLE IF EXISTS clustereye;" 2>/dev/null || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq postgresql postgresql-client 'postgresql-*' 'libpq*' 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    dnf remove -y -q postgresql-server postgresql 2>/dev/null || true
  fi

  rm -rf /var/lib/postgresql
  rm -rf /var/lib/pgsql
  rm -rf /etc/postgresql
  rm -rf /var/log/postgresql
  log_info "PostgreSQL removed"
fi

# ── Purge InfluxDB ─────────────────────────────────────────
if [[ "$PURGE_INFLUX" == "true" ]]; then
  log_warn "Removing local InfluxDB..."

  # STEP 1: Create dummy service file FIRST — influxdb2 postrm script
  # calls "systemctl disable influxdb" which fails if unit doesn't exist.
  # This must happen before any dpkg/apt operation.
  if [[ ! -f /lib/systemd/system/influxdb.service ]] && \
     [[ ! -f /usr/lib/systemd/system/influxdb.service ]] && \
     [[ ! -f /etc/systemd/system/influxdb.service ]]; then
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/influxdb.service <<'DUMMY'
[Unit]
Description=dummy for cleanup
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
DUMMY
    systemctl daemon-reload 2>/dev/null || true
  fi

  # STEP 2: Stop and disable services
  systemctl stop influxdb 2>/dev/null || true
  systemctl stop influxdb2 2>/dev/null || true
  systemctl stop influxd 2>/dev/null || true
  systemctl disable influxdb 2>/dev/null || true
  systemctl disable influxdb2 2>/dev/null || true
  systemctl reset-failed influxdb 2>/dev/null || true
  systemctl reset-failed influxdb2 2>/dev/null || true

  # STEP 3: Remove the package
  if command -v dpkg &>/dev/null; then
    # Try normal purge first (dummy service ensures postrm succeeds)
    DEBIAN_FRONTEND=noninteractive dpkg --purge influxdb2 2>/dev/null || true

    # If still present, nuke the postrm script and force remove
    if dpkg -s influxdb2 &>/dev/null 2>&1; then
      log_warn "Normal purge failed, force-removing influxdb2..."
      rm -f /var/lib/dpkg/info/influxdb2.postrm
      rm -f /var/lib/dpkg/info/influxdb2.prerm
      DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all influxdb2 2>/dev/null || true
    fi

    DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -f -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    dnf remove -y -q 'influxdb*' 2>/dev/null || true
  fi

  # STEP 4: Remove ALL files — data, config, binaries, service units, CLI, logs
  # Data directories
  rm -rf /var/lib/influxdb
  rm -rf /var/lib/influxdb2
  rm -rf /var/log/influxdb
  rm -rf /var/log/influxdb2
  # CLI config and credentials (all users)
  rm -rf /root/.influxdbv2
  for homedir in /home/*/; do
    rm -rf "${homedir}.influxdbv2" 2>/dev/null || true
  done
  # System config
  rm -rf /etc/influxdb
  rm -rf /etc/influxdb2
  rm -f /etc/default/influxdb2
  rm -f /etc/default/influxdb
  rm -f /etc/logrotate.d/influxdb
  rm -f /etc/logrotate.d/influxdb2
  # Binaries and libraries
  rm -rf /usr/lib/influxdb
  rm -f /usr/bin/influxd /usr/bin/influx
  rm -f /usr/local/bin/influxd /usr/local/bin/influx
  rm -f /usr/share/man/man1/influx*.1.gz
  # Service units (all locations)
  rm -f /etc/systemd/system/influxdb.service /etc/systemd/system/influxdb2.service /etc/systemd/system/influxd.service
  rm -f /lib/systemd/system/influxdb.service /lib/systemd/system/influxdb2.service
  rm -f /usr/lib/systemd/system/influxdb.service /usr/lib/systemd/system/influxdb2.service
  # dpkg info (prevents ghost broken package)
  rm -f /var/lib/dpkg/info/influxdb2.*
  # influxdb user
  if getent passwd influxdb &>/dev/null; then
    userdel influxdb 2>/dev/null || true
  fi
  if getent group influxdb &>/dev/null; then
    groupdel influxdb 2>/dev/null || true
  fi

  # STEP 5: Remove repo and keys
  rm -f /etc/apt/sources.list.d/influxdata.list
  rm -f /etc/apt/keyrings/influxdata-archive*.gpg
  rm -f /etc/apt/trusted.gpg.d/influxdata-archive*.gpg
  rm -f /etc/yum.repos.d/influxdata.repo

  # STEP 6: Clean dpkg state and reload
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  log_info "InfluxDB removed (packages, data, config, CLI, user, repo, keys)"
fi

# ── Purge ClickHouse ───────────────────────────────────────
if [[ "$PURGE_CLICKHOUSE" == "true" ]]; then
  log_warn "Removing local ClickHouse..."

  # Stop and disable. ClickHouse packages ship a clean systemd unit
  # (no postrm-disable hack needed, unlike InfluxDB).
  systemctl stop clickhouse-server 2>/dev/null || true
  systemctl disable clickhouse-server 2>/dev/null || true
  systemctl reset-failed clickhouse-server 2>/dev/null || true

  if command -v dpkg &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
      clickhouse-server clickhouse-client clickhouse-common-static 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    dnf remove -y -q 'clickhouse-*' 2>/dev/null || true
  fi

  # Data + config + logs
  rm -rf /var/lib/clickhouse
  rm -rf /var/log/clickhouse-server
  rm -rf /etc/clickhouse-server
  rm -rf /etc/clickhouse-client

  # Service unit (in case the package didn't clean it up)
  rm -f /etc/systemd/system/clickhouse-server.service
  rm -f /lib/systemd/system/clickhouse-server.service
  rm -f /usr/lib/systemd/system/clickhouse-server.service

  # User + group
  if getent passwd clickhouse &>/dev/null; then
    userdel clickhouse 2>/dev/null || true
  fi
  if getent group clickhouse &>/dev/null; then
    groupdel clickhouse 2>/dev/null || true
  fi

  # Repo + keys
  rm -f /etc/apt/sources.list.d/clickhouse.list
  rm -f /usr/share/keyrings/clickhouse-keyring.gpg
  rm -f /etc/yum.repos.d/clickhouse.repo

  systemctl daemon-reload 2>/dev/null || true
  log_info "ClickHouse removed (packages, data, config, user, repo, keys)"
fi

# ── Final dpkg cleanup ─────────────────────────────────────
if command -v dpkg &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
fi

echo ""
log_info "ClusterEye has been uninstalled."
if [[ "$PURGE" != "true" ]]; then
  log_info "Config and data preserved in /etc/clustereye and /var/lib/clustereye"
  log_info "To remove all data, re-run with: $0 --purge --yes-i-mean-it"
fi
