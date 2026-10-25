#!/usr/bin/env bash
# Build the three measured programs with `elm make --optimize`, minify each
# with terser (--compress --mangle) and gzip it (-9), and print the bytes
# per stage and the attribution by runtime module.
#
#   spike/measure.sh OUTDIR
#
# Run from the worktree root. Programs: the smallest honest program
# (spike/min-main, one unary call over Connect), the notes example and the
# Eliza example.
set -euo pipefail
out="$1"
mkdir -p "$out"
root="$(pwd)"
terser="npx --yes terser@5.36.0"

build() { # name dir main
    local name="$1" dir="$2" main="$3"
    (cd "$dir" && "$root/spike/to.sh" 300 elm make "$main" --optimize --output="$root/$out/$name.js" > /dev/null)
    $terser "$out/$name.js" --compress --mangle -o "$out/$name.min.js" 2> /dev/null
    gzip -9 -c "$out/$name.min.js" > "$out/$name.min.js.gz"
    printf '%-8s optimized %8d  minified %8d  gzip %7d\n' "$name" \
        "$(wc -c < "$out/$name.js")" "$(wc -c < "$out/$name.min.js")" "$(wc -c < "$out/$name.min.js.gz")"
}

build min spike/min-main src/Main.elm
build notes examples/notes/elm src/Main.elm
build eliza examples/eliza src/Main.elm

for name in min notes eliza; do
    echo "== attribution: $name"
    python3 spike/attr.py "$out/$name.js" Notes,Routes,Google,Connectrpc 60 full
done
