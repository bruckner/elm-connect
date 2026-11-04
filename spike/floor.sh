#!/usr/bin/env bash
# The no-Any floor: spike/floor/Main.elm against the services corpus case's
# expected output, #142's (023fa5d4) with #142's runtime and this branch's
# with this branch's runtime, each built and measured.
#   spike/floor.sh WORK RUNTIME_142
set -euo pipefail
work="$1"; rt142="$2"
here="$(cd "$(dirname "$0")/.." && pwd)"
for v in 142 base; do
  d="$work/$v"; rm -rf "$d"; mkdir -p "$d/app/src" "$d/generated"
  if [ $v = 142 ]; then
    rt=$rt142
    (cd "$here" && git archive 023fa5d4 conformance/cases/services/expected) | tar -x -C "$d"
  else
    rt=$here/src
    (cd "$here" && git archive HEAD conformance/cases/services/expected) | tar -x -C "$d"
  fi
  cp -R "$d/conformance/cases/services/expected/." "$d/generated/"
  cp "$here/spike/floor/Main.elm" "$d/app/src/"
  python3 - "$d/app/elm.json" "$rt" <<'PY'
import json, sys
json.dump({'type': 'application', 'source-directories': ['src', '../generated', sys.argv[2]], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(sys.argv[1], 'w'), indent=4)
PY
  "$here/spike/make.sh" "$d" "floor $v"
  "$here/spike/size.sh" "$d/app/main.js" "floor $v"
done
