#!/usr/bin/env bash
# Build the comparison's size programs (spike/compare-harness) as measure.sh
# builds the codec harness: `elm make --optimize`, terser 5.36.0 --compress
# --mangle, gzip -9; print the bytes per stage and the attribution.
#   spike/compare-size.sh OUTDIR
set -euo pipefail
out="$1"
mkdir -p "$out"
root="$(pwd)"
terser="npx --yes terser@5.36.0"
for p in SizeNull SizeNullBytes SizeOursBinary SizeEpbBinary SizeOursJson SizeEpbJson SizeOursBoth SizeEpbBoth; do
    (cd spike/compare-harness && elm make "src/$p.elm" --optimize --output="$root/$out/$p.js" > /dev/null)
    $terser "$out/$p.js" --compress --mangle -o "$out/$p.min.js" 2> /dev/null
    gzip -9 -c "$out/$p.min.js" > "$out/$p.min.js.gz"
    printf '%-16s optimized %8d  minified %8d  gzip %7d\n' "$p" \
        "$(wc -c < "$out/$p.js")" "$(wc -c < "$out/$p.min.js")" "$(wc -c < "$out/$p.min.js.gz")"
done
for p in SizeOursBinary SizeEpbBinary SizeOursJson SizeEpbJson SizeOursBoth SizeEpbBoth; do
    echo "== $p"
    python3 spike/compare-attr.py "$out/$p.js"
done
