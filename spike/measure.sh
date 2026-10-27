#!/usr/bin/env bash
# Build programs with `elm make --optimize`, minify each with terser
# (--compress --mangle) and gzip it (-9), and print the bytes per stage.
#
#   spike/measure.sh OUTDIR [name=dir:main ...]
#
# Run from the worktree root. Without programs: min (spike/min-main, one
# unary call over Connect), the notes example and the Eliza example.
set -euo pipefail
out="$1"; shift
mkdir -p "$out"
root="$(pwd)"
terser="npx --yes terser@5.36.0"

build() { # name dir main
    local name="$1" dir="$2" main="$3"
    (cd "$dir" && "$root/spike/to.sh" 300 elm make "$main" --optimize --output="$root/$out/$name.js" > /dev/null)
    $terser "$out/$name.js" --compress --mangle -o "$out/$name.min.js" 2> /dev/null
    gzip -9 -c "$out/$name.min.js" > "$out/$name.min.js.gz"
    printf '%-14s optimized %8d  minified %8d  gzip %7d\n' "$name" \
        "$(wc -c < "$out/$name.js")" "$(wc -c < "$out/$name.min.js")" "$(wc -c < "$out/$name.min.js.gz")"
}

if [ $# -eq 0 ]; then
    set -- min=spike/min-main:src/Main.elm notes=examples/notes/elm:src/Main.elm eliza=examples/eliza:src/Main.elm
fi
for spec in "$@"; do
    name="${spec%%=*}"; rest="${spec#*=}"
    build "$name" "${rest%%:*}" "${rest#*:}"
done
