#!/usr/bin/env bash
# ClusterEye — verify the ClickHouse addition on an existing K8s deployment.
# Uses the current kubectl context/namespace, same as install-clickhouse.sh.
set -uo pipefail

API_DEPLOY="${API_DEPLOY:-deploy/clustereye-clustereye-api}"
CH_STS="${CH_STS:-statefulset/clustereye-clickhouse}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*"; }

PW="$(kubectl get secret clustereye-clickhouse -o jsonpath='{.data.CLICKHOUSE_PASSWORD}' 2>/dev/null | base64 -d)"
[[ -z "$PW" ]] && { echo "secret/clustereye-clickhouse not found — run install-clickhouse.sh first"; exit 1; }

ch() { kubectl exec "$CH_STS" -- clickhouse-client -u clustereye --password "$PW" -q "$1"; }

log "Pod status"
kubectl get pods -l app=clustereye-clickhouse

log "Tables created in the clustereye database"
ch "SELECT name FROM system.tables WHERE database='clustereye' ORDER BY name"

log "Row counts per table (0 everywhere right after install is expected)"
ch "SELECT table, sum(rows) AS rows, formatReadableSize(sum(bytes_on_disk)) AS size
    FROM system.parts WHERE database='clustereye' AND active
    GROUP BY table ORDER BY rows DESC"

log "Newest row per table (proves the API is writing)"
ch "SELECT name FROM system.tables WHERE database='clustereye' AND engine LIKE '%MergeTree'" \
  | while read -r t; do
      [[ -z "$t" ]] && continue
      ts="$(ch "SELECT max(time) FROM clustereye.\`$t\`" 2>/dev/null)"
      printf '  %-40s %s\n' "$t" "${ts:-<no time column>}"
    done

log "API-side ClickHouse config"
kubectl set env "$API_DEPLOY" --list | grep -i clickhouse | sed 's/\(CLICKHOUSE_PASSWORD=\).*/\1<redacted>/'

log "API logs mentioning ClickHouse (last 200 lines)"
kubectl logs "$API_DEPLOY" --tail=200 | grep -i clickhouse || warn "no ClickHouse lines in the last 200 log lines"
