#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# ClusterEye Standalone Installer
# Installs ClusterEye API + UI on bare-metal Linux servers
# Supports: Ubuntu 22.04+, RHEL 8/9, Oracle Linux 8/9
#
# One-liner:
#   curl -fsSL https://archive.clustereye.com/deploy/standalone/install.sh \
#     | sudo bash -s -- --api-version=1.1.253 --ui-version=1.1.211 --domain=clustereye.example.com --postgres=local
# ─────────────────────────────────────────────────────────────
set -Eeuo pipefail

readonly INSTALLER_VERSION="1.0.0"
# Bootstrap lib/templates from the public archive CDN (Pages) instead of raw.github,
# so the install chain stays on the archive.clustereye.com domain end-to-end.
readonly GITHUB_RAW_BASE="https://archive.clustereye.com/deploy/standalone"

# ── Defaults ────────────────────────────────────────────────
CE_API_VERSION=""
CE_UI_VERSION=""
CE_POSTGRES="local"
CE_POSTGRES_HOST=""
CE_POSTGRES_PORT="5432"
CE_POSTGRES_USER="postgres"
CE_POSTGRES_PASSWORD=""
CE_POSTGRES_DBNAME="clustereye"
CE_POSTGRES_SSLMODE="disable"
CE_INFLUXDB="local"
CE_INFLUXDB_URL=""
CE_INFLUXDB_TOKEN=""
CE_INFLUXDB_ORG="clustereye"
CE_INFLUXDB_BUCKET="clustereye"
CE_CLICKHOUSE="local"
CE_CLICKHOUSE_HOST=""
CE_CLICKHOUSE_PORT="9000"
CE_CLICKHOUSE_USER="clustereye"
CE_CLICKHOUSE_PASSWORD=""
CE_CLICKHOUSE_DATABASE="clustereye"
CE_TLS="self-signed"
CE_TLS_CERT=""
CE_TLS_KEY=""
CE_PORT="443"
CE_HTTP_PORT="80"
CE_GRPC_PORT=""
CE_DOMAIN=""
CE_BIND_HOST="0.0.0.0"
CE_EXTRA_HOSTNAMES=""
CE_NO_FIREWALL="0"

# ── Parse arguments ─────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 --api-version=<ver> --ui-version=<ver> [OPTIONS]

Required:
  --api-version=<ver>              API binary version (e.g., 1.1.253)
  --ui-version=<ver>               UI assets version (e.g., 1.1.211)
  --domain=<host|ip>               Server domain or IP (e.g., clustereye.example.com or 10.0.1.5)

PostgreSQL:
  --postgres=local|external        PostgreSQL mode (default: local)
  --postgres-host=<host>           External PG host
  --postgres-port=<port>           External PG port (default: 5432)
  --postgres-user=<user>           External PG user (default: postgres)
  --postgres-password=<pwd>        External PG password
  --postgres-dbname=<name>         Database name (default: clustereye)
  --postgres-sslmode=<mode>        SSL mode (default: disable)

InfluxDB:
  --influxdb=local|external|none   InfluxDB mode (default: local)
  --influxdb-url=<url>             External InfluxDB URL
  --influxdb-token=<token>         External InfluxDB token
  --influxdb-org=<org>             InfluxDB org (default: clustereye)
  --influxdb-bucket=<bucket>       InfluxDB bucket (default: clustereye)

ClickHouse (per-query metric store):
  --clickhouse=local|external      ClickHouse mode (default: local)
  --clickhouse-host=<host>         External ClickHouse host
  --clickhouse-port=<port>         External ClickHouse native port (default: 9000)
  --clickhouse-user=<user>         External ClickHouse user (default: clustereye)
  --clickhouse-password=<pwd>      External ClickHouse password
  --clickhouse-database=<name>     ClickHouse database name (default: clustereye)

TLS:
  --tls=self-signed|provided       TLS mode (default: self-signed)
  --cert=<path>                    Certificate file (with --tls=provided)
  --key=<path>                     Key file (with --tls=provided)

Network:
  --port=<n>                       HTTPS port (default: 443)
  --http-port=<n>|none             Plaintext HTTP/h2c port — same routing as TLS,
                                   for agents that connect over plaintext gRPC.
                                   Use 'none' to disable. (default: 80)
  --grpc-port=<n>                  (deprecated, gRPC served via main HTTPS port)
  --bind-host=<host>               Bind address (default: 0.0.0.0)
  --extra-hostnames=a,b,c          Additional TLS SANs

Other:
  --no-firewall                    Skip firewall configuration
  -h, --help                       Show this help
  --version                        Show installer version

Examples:
  # Full local install
  $0 --api-version=1.1.253 --ui-version=1.1.211 --postgres=local --influxdb=local

  # External database, no InfluxDB
  $0 --api-version=1.1.253 --ui-version=1.1.211 \\
    --postgres=external --postgres-host=db.example.com --postgres-password=secret

  # Custom port with provided TLS
  $0 --api-version=1.1.253 --ui-version=1.1.211 \\
    --port=8443 --tls=provided --cert=/path/to/cert.pem --key=/path/to/key.pem
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-version=*)       CE_API_VERSION="${1#*=}" ;;
      --ui-version=*)        CE_UI_VERSION="${1#*=}" ;;
      --postgres=*)          CE_POSTGRES="${1#*=}" ;;
      --postgres-host=*)     CE_POSTGRES_HOST="${1#*=}" ;;
      --postgres-port=*)     CE_POSTGRES_PORT="${1#*=}" ;;
      --postgres-user=*)     CE_POSTGRES_USER="${1#*=}" ;;
      --postgres-password=*) CE_POSTGRES_PASSWORD="${1#*=}" ;;
      --postgres-dbname=*)   CE_POSTGRES_DBNAME="${1#*=}" ;;
      --postgres-sslmode=*)  CE_POSTGRES_SSLMODE="${1#*=}" ;;
      --influxdb=*)          CE_INFLUXDB="${1#*=}" ;;
      --influxdb-url=*)      CE_INFLUXDB_URL="${1#*=}" ;;
      --influxdb-token=*)    CE_INFLUXDB_TOKEN="${1#*=}" ;;
      --influxdb-org=*)      CE_INFLUXDB_ORG="${1#*=}" ;;
      --influxdb-bucket=*)   CE_INFLUXDB_BUCKET="${1#*=}" ;;
      --clickhouse=*)        CE_CLICKHOUSE="${1#*=}" ;;
      --clickhouse-host=*)   CE_CLICKHOUSE_HOST="${1#*=}" ;;
      --clickhouse-port=*)   CE_CLICKHOUSE_PORT="${1#*=}" ;;
      --clickhouse-user=*)   CE_CLICKHOUSE_USER="${1#*=}" ;;
      --clickhouse-password=*) CE_CLICKHOUSE_PASSWORD="${1#*=}" ;;
      --clickhouse-database=*) CE_CLICKHOUSE_DATABASE="${1#*=}" ;;
      --tls=*)               CE_TLS="${1#*=}" ;;
      --cert=*)              CE_TLS_CERT="${1#*=}" ;;
      --key=*)               CE_TLS_KEY="${1#*=}" ;;
      --port=*)              CE_PORT="${1#*=}" ;;
      --http-port=*)         CE_HTTP_PORT="${1#*=}" ;;
      --grpc-port=*)         CE_GRPC_PORT="${1#*=}" ;;
      --domain=*)            CE_DOMAIN="${1#*=}" ;;
      --bind-host=*)         CE_BIND_HOST="${1#*=}" ;;
      --extra-hostnames=*)   CE_EXTRA_HOSTNAMES="${1#*=}" ;;
      --no-firewall)         CE_NO_FIREWALL="1" ;;
      --version)             echo "ClusterEye Standalone Installer v${INSTALLER_VERSION}"; exit 0 ;;
      -h|--help)             usage ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
  done

  # Validate required args
  [[ -n "$CE_API_VERSION" ]] || { echo "Error: --api-version is required" >&2; exit 1; }
  [[ -n "$CE_UI_VERSION" ]]  || { echo "Error: --ui-version is required" >&2; exit 1; }
  [[ -n "$CE_DOMAIN" ]]      || { echo "Error: --domain is required (e.g., --domain=clustereye.example.com or --domain=192.168.1.10)" >&2; exit 1; }
}

# ── One-liner bootstrap ─────────────────────────────────────
# When piped via curl, lib/ directory is missing. Download all
# files from GitHub and re-exec from the bundle.
bootstrap_if_needed() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -d "${script_dir}/lib" ]]; then
    CE_SCRIPT_DIR="$script_dir"
    return 0
  fi

  echo "[INFO]  Running in one-liner mode — downloading installer bundle..."

  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/lib" "$workdir/templates"

  local lib_files=(
    common.sh preflight.sh user.sh dirs.sh download.sh secrets.sh
    postgresql.sh influxdb.sh clickhouse.sh config.sh tls.sh nginx.sh systemd.sh
    firewall.sh journald.sh verify.sh
  )
  local template_files=(
    nginx.conf nginx-http-block.conf nginx-locations.inc
    clustereye-api.service server.yml.tmpl
    config.js.tmpl journald-clustereye.conf
    clickhouse-schema.sql
  )

  for f in "${lib_files[@]}"; do
    if ! curl -fsSL "${GITHUB_RAW_BASE}/lib/${f}" -o "$workdir/lib/${f}"; then
      rm -rf "$workdir"
      echo "Error: Failed to download lib/${f}" >&2
      exit 1
    fi
  done

  for f in "${template_files[@]}"; do
    if ! curl -fsSL "${GITHUB_RAW_BASE}/templates/${f}" -o "$workdir/templates/${f}"; then
      rm -rf "$workdir"
      echo "Error: Failed to download templates/${f}" >&2
      exit 1
    fi
  done

  # Copy install.sh itself to workdir
  cp "${BASH_SOURCE[0]}" "$workdir/install.sh" 2>/dev/null || \
    curl -fsSL "${GITHUB_RAW_BASE}/install.sh" -o "$workdir/install.sh"
  echo "[INFO]  Bundle downloaded to $workdir"

  # Re-exec via bash so this works even when /tmp is mounted noexec
  exec bash "$workdir/install.sh" "$@"
}

# ── Main ────────────────────────────────────────────────────
main() {
  parse_args "$@"
  bootstrap_if_needed "$@"

  # Export all CE_ variables for lib modules
  export CE_API_VERSION CE_UI_VERSION
  export CE_POSTGRES CE_POSTGRES_HOST CE_POSTGRES_PORT CE_POSTGRES_USER
  export CE_POSTGRES_PASSWORD CE_POSTGRES_DBNAME CE_POSTGRES_SSLMODE
  export CE_INFLUXDB CE_INFLUXDB_URL CE_INFLUXDB_TOKEN CE_INFLUXDB_ORG CE_INFLUXDB_BUCKET
  export CE_CLICKHOUSE CE_CLICKHOUSE_HOST CE_CLICKHOUSE_PORT CE_CLICKHOUSE_USER CE_CLICKHOUSE_PASSWORD CE_CLICKHOUSE_DATABASE
  export CE_TLS CE_TLS_CERT CE_TLS_KEY
  export CE_DOMAIN CE_PORT CE_HTTP_PORT CE_GRPC_PORT CE_BIND_HOST CE_EXTRA_HOSTNAMES CE_NO_FIREWALL
  export CE_SCRIPT_DIR

  # Source all library modules
  # shellcheck source=lib/common.sh
  source "${CE_SCRIPT_DIR}/lib/common.sh"
  source "${CE_SCRIPT_DIR}/lib/preflight.sh"
  source "${CE_SCRIPT_DIR}/lib/user.sh"
  source "${CE_SCRIPT_DIR}/lib/dirs.sh"
  source "${CE_SCRIPT_DIR}/lib/download.sh"
  source "${CE_SCRIPT_DIR}/lib/secrets.sh"
  source "${CE_SCRIPT_DIR}/lib/postgresql.sh"
  source "${CE_SCRIPT_DIR}/lib/influxdb.sh"
  source "${CE_SCRIPT_DIR}/lib/clickhouse.sh"
  source "${CE_SCRIPT_DIR}/lib/config.sh"
  source "${CE_SCRIPT_DIR}/lib/tls.sh"
  source "${CE_SCRIPT_DIR}/lib/nginx.sh"
  source "${CE_SCRIPT_DIR}/lib/systemd.sh"
  source "${CE_SCRIPT_DIR}/lib/firewall.sh"
  source "${CE_SCRIPT_DIR}/lib/journald.sh"
  source "${CE_SCRIPT_DIR}/lib/verify.sh"

  echo ""
  echo "  ╔═══════════════════════════════════════════════╗"
  echo "  ║     ClusterEye Standalone Installer v${INSTALLER_VERSION}     ║"
  echo "  ╠═══════════════════════════════════════════════╣"
  echo "  ║  API Version:  v${CE_API_VERSION}"
  echo "  ║  UI Version:   v${CE_UI_VERSION}"
  echo "  ║  PostgreSQL:   ${CE_POSTGRES}"
  echo "  ║  InfluxDB:     ${CE_INFLUXDB}"
  echo "  ║  ClickHouse:   ${CE_CLICKHOUSE}"
  echo "  ║  Domain:       ${CE_DOMAIN}"
  echo "  ║  TLS:          ${CE_TLS}"
  echo "  ║  HTTPS Port:   ${CE_PORT}"
  echo "  ║  HTTP Port:    ${CE_HTTP_PORT}"
  echo "  ╚═══════════════════════════════════════════════╝"
  echo ""

  # ── Installation pipeline ──
  preflight::run
  user::ensure
  dirs::ensure
  download::fetch
  secrets::generate
  postgresql::setup
  influxdb::setup
  clickhouse::setup
  config::render
  tls::setup
  nginx::setup
  journald::configure
  systemd::install
  firewall::open
  dirs::verify
  verify::wait
  verify::print_summary
}

main "$@"
