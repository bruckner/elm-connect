#!/usr/bin/env bash
# Build the three measured programs with `elm make --optimize`, minify each
# with terser (--compress --mangle) and gzip it (-9), and print the bytes
# per stage and the attribution by module and per generated definition.
#
#   spike/measure.sh OUTDIR
#
# Run from the worktree root.
set -euo pipefail
out="$1"
mkdir -p "$out"
root="$(pwd)"
terser="npx --yes terser@5.36.0"

build() { # name dir main
    local name="$1" dir="$2" main="$3"
    (cd "$dir" && elm make "$main" --optimize --output="$root/$out/$name.js" > /dev/null)
    $terser "$out/$name.js" --compress --mangle -o "$out/$name.min.js" 2> /dev/null
    gzip -9 -c "$out/$name.min.js" > "$out/$name.min.js.gz"
    printf '%-8s optimized %8d  minified %8d  gzip %7d\n' "$name" \
        "$(wc -c < "$out/$name.js")" "$(wc -c < "$out/$name.min.js")" "$(wc -c < "$out/$name.min.js.gz")"
}

build notes examples/notes/elm src/Main.elm
build live conformance/live src/Live.elm
build routes spike/routes-main src/Main.elm

for name in notes live routes; do
    echo "== attribution: $name"
    python3 spike/attr.py "$out/$name.js" Notes,Routes,Google,Connectrpc 30
done
echo "== per definition: notes service"
python3 spike/fn.py "$out/notes.js" '$author$project$Notes$V1$NotesService$' 1 40
echo "== per definition: routes service (tests/Routes)"
python3 spike/fn.py "$out/routes.js" '$author$project$Routes$V1$Routes$' 1 40
echo "== per definition: runtime transcoding (routes main)"
for m in 'Rpc$Internal$Route$' 'Proto$Http$' 'Proto$Internal$' 'Rpc$Route$' 'Proto$Method$' 'Rpc$Internal$Wire$'; do
    python3 spike/fn.py "$out/routes.js" "\$author\$project\$$m" 1 0 | head -1
done
