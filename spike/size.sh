#!/usr/bin/env bash
# One compiled program's sizes: optimized, minified (terser 5.36.0,
# --compress --mangle) and gzipped (-9) bytes.
#   spike/size.sh FILE.js LABEL
set -euo pipefail
js="$1"; label="$2"
min="${js%.js}.min.js"
npx --yes terser@5.36.0 "$js" --compress --mangle -o "$min" 2> /dev/null
gzip -9 -c "$min" > "$min.gz"
printf '%s optimized=%s minified=%s gzip=%s\n' "$label" "$(wc -c < "$js" | tr -d ' ')" "$(wc -c < "$min" | tr -d ' ')" "$(wc -c < "$min.gz" | tr -d ' ')"
