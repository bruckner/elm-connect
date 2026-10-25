#!/usr/bin/env bash
# Build the measured programs with `elm make --optimize`, minify each with
# terser (--compress --mangle) and gzip it (-9), and print the bytes per
# stage, the attribution by module, and the codecs' bytes (codecs.py).
#
#   spike/measure.sh OUTDIR [PROGRAM...]
#
# PROGRAM is a harness module (SizeJson, SizeNull, ...) or `notes`; the
# default is all of them. Run from the worktree root.
set -euo pipefail
out="$1"
shift
programs=("$@")
[ ${#programs[@]} -gt 0 ] || programs=(notes SizeNull SizeJson)
mkdir -p "$out"
root="$(pwd)"
terser="npx --yes terser@5.36.0"

build() { # name dir main
    local name="$1" dir="$2" main="$3"
    (cd "$dir" && elm make "$main" --optimize --output="$root/$out/$name.js" > /dev/null)
    $terser "$out/$name.js" --compress --mangle -o "$out/$name.min.js" 2> /dev/null
    gzip -9 -c "$out/$name.min.js" > "$out/$name.min.js.gz"
    printf '%-10s optimized %8d  minified %8d  gzip %7d\n' "$name" \
        "$(wc -c < "$out/$name.js")" "$(wc -c < "$out/$name.min.js")" "$(wc -c < "$out/$name.min.js.gz")"
}

for p in "${programs[@]}"; do
    case "$p" in
        notes) build notes examples/notes/elm src/Main.elm ;;
        *) build "$p" spike/codec-harness "src/$p.elm" ;;
    esac
done
for p in "${programs[@]}"; do
    echo "== attribution: $p"
    python3 spike/attr.py "$out/$p.js" Notes,Google,Routes,Generated 12
    echo "== codecs: $p"
    python3 spike/codecs.py "$out/$p.js"
done
