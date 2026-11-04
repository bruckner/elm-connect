#!/usr/bin/env bash
# M4d's typed-value check: spike/m4/details.py's program against the notes
# example's generated bindings (google.rpc and notes.v1), on each runtime.
#   spike/m4/details.sh WORK LABEL=RUNTIME_SRC=CLIENTS...
set -euo pipefail
work="$1"; shift
here="$(cd "$(dirname "$0")/../.." && pwd)"
elm="$(cd "$here" && mise which elm)"
for spec in "$@"; do
  l="${spec%%=*}"; rest="${spec#*=}"; rt="${rest%%=*}"; clients="${rest#*=}"
  d="$work/$l"; rm -rf "$d"; mkdir -p "$d/src"
  python3 "$here/spike/m4/details.py" "$d/src/Details.elm" "$clients"
  python3 - "$d/elm.json" "$rt" "$here/examples/notes/elm/generated" <<'PY'
import json, sys
json.dump({'type': 'application', 'source-directories': ['src', sys.argv[3], sys.argv[2]], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(sys.argv[1], 'w'), indent=4)
PY
  (cd "$d" && "$elm" make src/Details.elm --optimize --output="$d/details.js" > /dev/null && rm -rf elm-stuff)
  echo "## $l"
  node -e 'const s={};new Function(require("fs").readFileSync(process.argv[1],"utf8")).call(s);const a=s.Elm.Details.init();a.ports.done.subscribe(t=>console.log(t));' "$d/details.js"
done
