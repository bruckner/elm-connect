#!/usr/bin/env bash
# M3: spike/m3/bench.proto generated under codec=json by #142's CLI and by
# this branch's, each compiled with its runtime into a Bench program
# (spike/m3/bench.py), then timed by spike/m3/bench.js, the two builds
# alternating, median of 11.
#   spike/m3.sh WORK CLI_142 RUNTIME_142 CLI_BASE
set -euo pipefail
work="$1"; cli142="$2"; rt142="$3"; clibase="$4"
here="$(cd "$(dirname "$0")/.." && pwd)"
elm="$(cd "$here" && mise which elm)"
for v in 142 base; do
  d="$work/$v"; rm -rf "$d"; mkdir -p "$d/app/src"
  if [ $v = 142 ]; then cli=$cli142; rt=$rt142; else cli=$clibase; rt=$here/src; fi
  "$cli" gen -I "$here/spike/m3" bench.proto --codec json --out "$d/generated" > /dev/null
  python3 "$here/spike/m3/bench.py" $v "$d/app/src/Bench.elm"
  python3 - "$d/app/elm.json" "$rt" <<'PY'
import json, sys
json.dump({'type': 'application', 'source-directories': ['src', '../generated', sys.argv[2]], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(sys.argv[1], 'w'), indent=4)
PY
  (cd "$d/app" && "$elm" make src/Bench.elm --optimize --output="$work/bench-$v.js" > /dev/null)
done
node "$here/spike/m3/bench.js" "$work/bench-142.js" "$work/bench-base.js" --reps 11
