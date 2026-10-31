#!/usr/bin/env bash
# ClusterEye — add ClickHouse to an existing Kubernetes deployment.
#
# Query Intelligence (per-query metrics) now lives in ClickHouse instead of
# InfluxDB. This script stands up a single-node ClickHouse next to the
# existing clustereye-postgresql-0 / clustereye-influxdb-0 pods and points
# the API at it. Agents are untouched — they never talk to ClickHouse
# directly; the API writes on their behalf.
#
# Prerequisites:
#   * kubectl context already points at the customer's cluster and the
#     namespace holding the ClusterEye release (no -n is passed anywhere).
#   * The ClickHouse schema has been downloaded to /tmp/001_schema.sql
#     (source: clustereye-api/clickhouse/init/001_schema.sql).
#
# Usage:
#   CLICKHOUSE_PASSWORD='...' ./install-clickhouse.sh
#   ./install-clickhouse.sh            # generates a random password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$SCRIPT_DIR/clickhouse-current-ns.yaml}"
SCHEMA="${SCHEMA:-/tmp/001_schema.sql}"
API_DEPLOY="${API_DEPLOY:-deploy/clustereye-clustereye-api}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

log "ClusterEye — installing ClickHouse for Query Intelligence"

command -v kubectl >/dev/null || die "kubectl not found in PATH"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -f "$SCHEMA"   ]] || die "schema not found: $SCHEMA (download clustereye-api/clickhouse/init/001_schema.sql there first)"
grep -q 'CREATE TABLE' "$SCHEMA" || die "$SCHEMA does not look like the ClickHouse schema (no CREATE TABLE found)"

# Password: reuse the one already in the cluster on a re-run, so the
# script is idempotent and never silently rotates it out from under the API.
EXISTING_PW="$(kubectl get secret clustereye-clickhouse -o jsonpath='{.data.CLICKHOUSE_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -n "${CLICKHOUSE_PASSWORD:-}" ]]; then
  PW="$CLICKHOUSE_PASSWORD"
elif [[ -n "$EXISTING_PW" && "$EXISTING_PW" != "__CLICKHOUSE_PASSWORD__" ]]; then
  PW="$EXISTING_PW"
  log "Reusing the ClickHouse password already stored in the cluster"
else
  # Read a fixed block and trim afterwards: piping into `head -c` would
  # SIGPIPE tr, which pipefail turns into a silent set -e exit.
  PW="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9 | cut -c1-24)"
  log "Generated a new ClickHouse password"
fi

# kubectl exits non-zero here when the context pins no namespace, so keep it
# off set -e's radar — an empty NS just means "default".
NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
log "Target namespace: ${NS:-default (context pins none)}"
kubectl get "$API_DEPLOY" >/dev/null || die "$API_DEPLOY not found in this namespace — switch context/namespace or set API_DEPLOY"

log "Creating/updating the schema ConfigMap from $SCHEMA"
kubectl create configmap clustereye-clickhouse-schema \
  --from-file=001_schema.sql="$SCHEMA" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying the ClickHouse StatefulSet, Service and Secret"
sed "s|__CLICKHOUSE_PASSWORD__|${PW//|/\\|}|" "$MANIFEST" | kubectl apply -f -

log "Waiting for ClickHouse to become ready (this pulls the image on first run)"
kubectl rollout status statefulset/clustereye-clickhouse --timeout=10m

log "Pointing the API at ClickHouse (this triggers an API rollout)"
kubectl set env "$API_DEPLOY" \
  CLICKHOUSE_ENABLED=true \
  CLICKHOUSE_ADDR=clustereye-clickhouse:9000 \
  CLICKHOUSE_DATABASE=clustereye \
  CLICKHOUSE_USERNAME=clustereye \
  CLICKHOUSE_PASSWORD="$PW"

kubectl rollout status "$API_DEPLOY" --timeout=10m

log "Done. ClickHouse password (also in secret/clustereye-clickhouse): $PW"
cat <<'NOTE'

Next:
  * ./verify-clickhouse.sh    — confirm the schema landed and rows are arriving.
  * Historical per-query data is NOT migrated from InfluxDB; Query Intelligence
    screens fill in as new collection cycles land.
  * InfluxDB stays in place — low-cardinality system metrics still live there.
NOTE
