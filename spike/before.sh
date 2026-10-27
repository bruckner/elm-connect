#!/usr/bin/env bash
# Extract a revision's runtime, examples and min program under
# spike/out-rev/REV/ and add the Connect-only notes variant (the toggle's
# `transcode` replaced by `connect`), so the "before" side of every size
# delta is built from the same programs:
#
#   spike/before.sh REV
#
# Programs then build with spike/measure.sh, e.g.
#   min=spike/out-rev/REV/spike/min-main:src/Main.elm
set -euo pipefail
rev="$1"
dir="spike/out-rev/$rev"
rm -rf "$dir"; mkdir -p "$dir"
git archive "$rev" src examples | tar -x -C "$dir"
mkdir -p "$dir/spike/min-main/src" "$dir/spike/notes-connect/src"
cp ../spike-perf-size/spike/min-main/elm.json "$dir/spike/min-main/"
cp ../spike-perf-size/spike/min-main/src/*.elm "$dir/spike/min-main/src/"
cp spike/notes-connect/elm.json "$dir/spike/notes-connect/"
cp "$dir/examples/notes/elm/src/Main.elm" "$dir/examples/notes/elm/src/Api.elm" "$dir/spike/notes-connect/src/"
sed -i '' 's/Rpc\.Transport\.transcode/Rpc.Transport.connect/g' "$dir/spike/notes-connect/src/Main.elm"
echo "extracted $rev to $dir"
