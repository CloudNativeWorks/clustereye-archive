#!/usr/bin/env bash
# write-latest.sh [ROOT] — write ROOT/downloads/{api,ui}/LATEST with the highest
# stable version directory (strictly vMAJOR.MINOR.PATCH; pre-releases such as
# v1.5.54-rc1 are skipped). Content is the bare version plus a newline.
set -Eeuo pipefail
ROOT="${1:-.}"
for comp in api ui; do
  base="$ROOT/downloads/$comp"
  [ -d "$base" ] || continue
  newest="$(find "$base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -rV | head -n 1 || true)"
  if [ -n "$newest" ]; then
    printf '%s\n' "$newest" > "$base/LATEST"
    echo "  downloads/$comp/LATEST -> $newest"
  fi
done
