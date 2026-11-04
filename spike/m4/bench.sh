#!/usr/bin/env bash
# M4b and M4e: spike/m3/bench.proto generated once under codec=json, compiled
# into spike/m4/bench.py's program against each runtime given, then two of
# them timed against each other by spike/m4/bench.js, alternating, median of
# 11, and every build's sizes by spike/size.sh.
#   spike/m4/bench.sh WORK CLI LABEL=RUNTIME_SRC... -- OLD NEW [OLD NEW...]
set -euo pipefail
work="$1"; cli="$2"; shift 2
here="$(cd "$(dirname "$0")/../.." && pwd)"
elm="$(cd "$here" && mise which elm)"
rm -rf "$work/generated"; mkdir -p "$work"
"$cli" gen -I "$here/spike/m3" bench.proto --codec json --out "$work/generated" > /dev/null
while [ "$1" != "--" ]; do
  l="${1%%=*}"; rt="${1#*=}"; shift
  d="$work/$l"; rm -rf "$d"; mkdir -p "$d/src"
  python3 "$here/spike/m4/bench.py" "$d/src/Bench.elm"
  python3 - "$d/elm.json" "$rt" <<'PY'
import json, sys
json.dump({'type': 'application', 'source-directories': ['src', '../generated', sys.argv[2]], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(sys.argv[1], 'w'), indent=4)
PY
  (cd "$d" && "$elm" make src/Bench.elm --optimize --output="$work/bench-$l.js" > /dev/null && rm -rf elm-stuff)
  "$here/spike/size.sh" "$work/bench-$l.js" "bench $l"
done
shift
while [ $# -ge 2 ]; do
  echo "## $1 against $2"
  node "$here/spike/m4/bench.js" "$work/bench-$1.js" "$work/bench-$2.js" --reps 11
  shift 2
done
