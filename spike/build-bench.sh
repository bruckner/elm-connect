#!/usr/bin/env bash
# Compile spike/bench-main's Bench.elm (the working tree's) against the
# runtime `src/` of a git revision, so any two revisions can be timed with
# the same harness:
#
#   spike/build-bench.sh REV OUT.js
#
# The revision's src/ is extracted under spike/out-rev/<rev>/ (gitignored);
# the generated example and corpus modules are the working tree's.
set -euo pipefail
rev="$1"; out="$2"
root="$(pwd)"
dir="$root/spike/out-rev/$rev"
rm -rf "$dir"; mkdir -p "$dir"
git archive "$rev" src | tar -x -C "$dir"
sed -e "s#\"src\",#\"$root/spike/bench-main/src\",#" \
    -e "s#\"../../src\"#\"$dir/src\"#" \
    -e "s#\"../../#\"$root/#g" spike/bench-main/elm.json > "$dir/elm.json"
(cd "$dir" && "$root/spike/to.sh" 300 elm make "$root/spike/bench-main/src/Bench.elm" --optimize --output="$root/$out" > /dev/null)
echo "built $out from $rev"
