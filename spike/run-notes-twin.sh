#!/usr/bin/env bash
# Regenerates the notes example's Elm client from its edition 2023
# translation (spike/editions-corpus/notes/v1/notes.proto) with the plugin
# under buf, as `just live-gen` generates today's from the proto3 file, and
# with the CLI, and diffs each with what the proto3 file gives: the
# committed examples/notes/elm/generated for the plugin, the CLI's own run
# for the CLI. Run `just live-gen` first (it puts the plugin in
# target/live/bin). Writes into OUT, a scratch directory.
#   spike/run-notes-twin.sh OUT
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
notes=$root/examples/notes
work=$out/notes-ed
rm -rf "$work" "$out/cli-proto3" "$out/cli-ed" && mkdir -p "$work/third_party"
# buf skips symbolic links, and routes/ is one.
cp -RL "$notes/proto" "$notes/routes" "$work/"
cp -RL "$notes/third_party/googleapis" "$work/third_party/"
cp "$notes/buf.yaml" "$notes/buf.gen.yaml" "$work/"
cp "$root/spike/editions-corpus/notes/v1/notes.proto" "$work/proto/notes/v1/notes.proto"
(cd "$work" && PATH="$root/target/live/bin:$PATH" mise exec -C "$root" -- \
    buf generate "$work" --template "$work/buf.gen.yaml" -o "$work" 2> /dev/null)
diff -r "$notes/elm/generated" "$work/elm/generated"
echo "plugin: $(find "$work/elm/generated" -name '*.elm' | wc -l | tr -d ' ') modules, identical to examples/notes/elm/generated"
for v in proto3 ed; do
    src=$notes/proto
    [[ $v == ed ]] && src=$work/proto
    "$root/target/debug/elm-connect" gen -I "$src" -I "$notes/third_party/googleapis" \
        notes/v1/notes.proto --out "$out/cli-$v" > /dev/null 2> /dev/null
done
diff -r "$out/cli-proto3" "$out/cli-ed"
echo "CLI: $(find "$out/cli-ed" -name '*.elm' | wc -l | tr -d ' ') modules, identical to the proto3 file's"
