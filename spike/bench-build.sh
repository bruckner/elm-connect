#!/usr/bin/env bash
# Measurement 3's two programs: conformance/codec generated with codec=both
# by this worktree's CLI (module prefix Generated.Codec.Both, as the codec
# spike's harness imports it), once as generated and once with its merges
# rewritten by spike/to_table.py, each compiled with spike/codec-harness's
# Bench (elm make --optimize) into SCRATCH/bench-{today,table}.js. The corpus
# is the codec spike's samples module, copied read-only into SCRATCH/data.
#   spike/bench-build.sh SCRATCH
set -euo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
free=$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')
if [ "$free" -lt 8000000 ]; then echo "disk floor: $free KiB free, stopping"; exit 2; fi
while pgrep -fl 'cargo|rustc' > /dev/null; do echo "cargo/rustc running, waiting" >&2; sleep 60; done
mkdir -p "$s/data/Generated/Codec" "$s/gen-today" "$s/gen-table"
cp "$HOME/Documents/elm-connect-wt/spike-binary-codec/tests/Generated/Codec/Data.elm" "$s/data/Generated/Codec/Data.elm"
"$here/target/debug/elm-connect" gen -I "$here/conformance/codec" codec.proto other.proto --codec both --module-prefix Generated.Codec.Both --out "$s/gen-today" > /dev/null
cp -R "$s/gen-today/." "$s/gen-table/"
m=Generated/Codec/Both/Codec/V1.elm
python3 "$here/spike/to_table.py" table "$s/gen-today/$m" "$s/gen-table/$m"
(cd "$here" && mise exec -- elm-format --yes "$s/gen-table/$m" > /dev/null)
elm="$(cd "$here" && mise which elm)"
cd "$here/spike/codec-harness"
for v in today table; do
    sed -e "s|@GEN@|$s/gen-$v|" -e "s|@DATA@|$s/data|" elm.json.in > elm.json
    rm -rf elm-stuff
    "$elm" make src/Bench.elm --optimize --output="$s/bench-$v.js" | tail -1
done
rm -rf elm-stuff elm.json
