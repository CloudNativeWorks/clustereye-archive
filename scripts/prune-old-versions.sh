#!/usr/bin/env bash
# prune-old-versions.sh — keep only the most recent agent versions so the
# GitHub Pages artifact stays small (Pages soft limit ~1GB) and deploys fast.
#
# Usage: scripts/prune-old-versions.sh [KEEP]   (default KEEP=3)
#
# Actions:
#   - downloads/agent/v*  : keep the newest KEEP versions (per releases.json
#     order); remove the rest (incl. malformed dirs like 'vv1.0.11').
#     The 'latest/' and 'windows/' dirs are left untouched.
#   - downloads/api/v* and downloads/ui/v* : keep the newest KEEP versions
#     (semver order); remove the rest.
#   - releases.json       : truncate agent.releases to the kept versions.
#   - agents/{linux,windows/mssql}/stable : keep only files for the current
#     stable version (from agents/stable/manifest.json) + manifest.json/.gitkeep.
#   - regenerate index.html from the trimmed releases.json.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

KEEP="${1:-3}"

# Versions to keep, newest first, straight from releases.json (so releases.json
# and downloads/ can never drift out of sync).
KEEP_VERSIONS="$(node -e '
  const fs = require("fs");
  const n = parseInt(process.argv[1], 10);
  const d = JSON.parse(fs.readFileSync("releases.json", "utf8"));
  d.agent.releases.slice(0, n).forEach(r => console.log(r.version));
' "$KEEP")"

echo "Keeping agent versions:"
printf '%s\n' "$KEEP_VERSIONS" | sed 's/^/  /'

# 1) Prune downloads/agent/v* (keep 'latest' + windows/ + kept versions).
for d in downloads/agent/v*; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  if ! printf '%s\n' "$KEEP_VERSIONS" | grep -qx "$name"; then
    echo "  rm downloads/agent/$name"
    rm -rf "$d"
  fi
done

# 1b) Prune downloads/api/v* and downloads/ui/v* to the newest KEEP versions
#     (semver order; these aren't tracked in releases.json).
for base in downloads/api downloads/ui; do
  [ -d "$base" ] || continue
  ls -d "$base"/v* 2>/dev/null | sort -rV | tail -n +$((KEEP + 1)) | while read -r d; do
    echo "  rm $d"
    rm -rf "$d"
  done
done

# 2) Truncate releases.json to the kept versions.
node -e '
  const fs = require("fs");
  const n = parseInt(process.argv[1], 10);
  const d = JSON.parse(fs.readFileSync("releases.json", "utf8"));
  d.agent.releases = d.agent.releases.slice(0, n);
  fs.writeFileSync("releases.json", JSON.stringify(d, null, 2) + "\n");
' "$KEEP"

# 3) Clean stable channel dirs down to the current stable version's files.
STABLE_VER="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("agents/stable/manifest.json","utf8")).version)')"
echo "Stable channel version: $STABLE_VER"
for dir in agents/linux/stable agents/windows/mssql/stable; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      .gitkeep|manifest.json) ;;            # always keep
      *"$STABLE_VER"*) ;;                    # keep current stable files
      *) echo "  rm $dir/$base"; rm -f "$f" ;;
    esac
  done
done

# 4) Regenerate the download page from the trimmed releases.json.
node scripts/generate-index.js

# 5) Stage everything (harmless if already staged by the caller / CI).
git add -A downloads/agent downloads/api downloads/ui agents releases.json index.html 2>/dev/null || true

echo "Prune complete (kept $KEEP agent versions)."
