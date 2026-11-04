#!/usr/bin/env bash
# M4a and M4c: the floor program (spike/floor) and M2's program
# (spike/m2/Main.elm.in) built against several runtimes, sizes by
# spike/size.sh. The generated code is the same for every runtime (the
# cache and the lenient registry change only the runtime), so it comes from
# one CLI.
#
#   spike/m4.sh a WORK CLI LABEL=RUNTIME_SRC...   M4a: floor, codec_both (b),
#                                                 synth60 (b) per runtime
#   spike/m4.sh c WORK CLI RUNTIME_SRC            M4c: bindings (i), (ii),
#                                                 (iii) on codec_both and synth60,
#                                                 and M2's floor (c) on the runtime
set -euo pipefail
mode="$1"; work="$2"; cli="$3"; shift 3
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$work"

app() { # dir generated runtime module type registry decoder client
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/app/src"; ln -s "$2" "$d/generated"
  python3 - "$d/app" "$3" "$here/spike/m2/Main.elm.in" "$4" "$5" "$6" "$7" "$8" <<'PY'
import json, sys
out, rt, tmpl, mod, ty, reg, dec, cl = sys.argv[1:]
json.dump({'type': 'application', 'source-directories': ['src', '../generated', rt], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(out + '/elm.json', 'w'), indent=4)
s = open(tmpl).read().replace('@MODULE@', mod).replace('@TYPE@', ty).replace('@REGISTRY@', reg).replace('@DECODER@', dec).replace('@CLIENT@', cl)
open(out + '/src/Main.elm', 'w').write(s)
PY
}
floor() { # dir runtime
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/app/src" "$d/generated"
  (cd "$here" && git archive HEAD conformance/cases/services/expected) | tar -x -C "$d"
  cp -R "$d/conformance/cases/services/expected/." "$d/generated/"
  cp "$here/spike/floor/Main.elm" "$d/app/src/"
  python3 - "$d/app/elm.json" "$2" <<'PY'
import json, sys
json.dump({'type': 'application', 'source-directories': ['src', '../generated', sys.argv[2]], 'elm-version': '0.19.2',
           'dependencies': {'direct': {'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/http': '2.0.0', 'elm/json': '1.1.4', 'elm/time': '1.0.0'},
                            'indirect': {'elm/file': '1.0.5'}},
           'test-dependencies': {'direct': {}, 'indirect': {}}}, open(sys.argv[1], 'w'), indent=4)
PY
}
measure() { "$here/spike/make.sh" "$1" "$2"; "$here/spike/size.sh" "$1/app/main.js" "$2"; }
with() { printf '\n        |> Rpc.withRegistry (%s)' "$1"; }

rm -rf "$work/gen-one" "$work/synth-any"
"$cli" gen -I "$here/spike/m2/one" codec.proto other.proto --codec json --out "$work/gen-one" > /dev/null
SYNTH_PARENT=chain1 SYNTH_ANY=1 python3 "$here/spike/synth.py" 60 json "$work/synth-any"
"$cli" gen -I "$work/synth-any/proto" synth/v1/synth.proto --codec json --out "$work/synth-any/generated" > /dev/null

case $mode in
  a)
    for pair in "$@"; do
      l="${pair%%=*}"; rt="${pair#*=}"
      floor "$work/floor-$l" "$rt"; measure "$work/floor-$l" "floor $l"
      app "$work/codec-b-$l" "$work/gen-one" "$rt" Codec.V1 WellKnown Proto.Registry.empty Codec.V1.decodeWellKnownWith "$(with Codec.V1.registry)"
      measure "$work/codec-b-$l" "codec_both (b) $l"
      app "$work/synth-b-$l" "$work/synth-any/generated" "$rt" Synth.V1 Msg0 Proto.Registry.empty Synth.V1.decodeMsg0With "$(with Synth.V1.registry)"
      measure "$work/synth-b-$l" "synth60 (b) $l"
    done ;;
  c)
    rt="$1"
    app "$work/codec-i" "$work/gen-one" "$rt" Codec.V1 WellKnown Codec.V1.registry Codec.V1.decodeWellKnownWith ""
    app "$work/codec-ii" "$work/gen-one" "$rt" Codec.V1 WellKnown Proto.Registry.empty Codec.V1.decodeWellKnownWith "$(with 'Proto.Registry.lenient Codec.V1.registry')"
    app "$work/codec-iii" "$work/gen-one" "$rt" Codec.V1 WellKnown Proto.Registry.empty Codec.V1.decodeWellKnownWith "$(with 'Proto.Registry.lenient Proto.Registry.empty')"
    app "$work/synth-i" "$work/synth-any/generated" "$rt" Synth.V1 Msg0 Synth.V1.registry Synth.V1.decodeMsg0With ""
    app "$work/synth-ii" "$work/synth-any/generated" "$rt" Synth.V1 Msg0 Proto.Registry.empty Synth.V1.decodeMsg0With "$(with 'Proto.Registry.lenient Synth.V1.registry')"
    app "$work/synth-iii" "$work/synth-any/generated" "$rt" Synth.V1 Msg0 Proto.Registry.empty Synth.V1.decodeMsg0With "$(with 'Proto.Registry.lenient Proto.Registry.empty')"
    # The floor on this runtime: M2's (c), the message without its Any.
    rm -rf "$work/gen-none" "$work/synth-none"
    "$cli" gen -I "$here/spike/m2/none" codec.proto other.proto --codec json --out "$work/gen-none" > /dev/null
    SYNTH_PARENT=chain1 SYNTH_ANY=0 python3 "$here/spike/synth.py" 60 json "$work/synth-none"
    "$cli" gen -I "$work/synth-none/proto" synth/v1/synth.proto --codec json --out "$work/synth-none/generated" > /dev/null
    app "$work/codec-c" "$work/gen-none" "$rt" Codec.V1 WellKnown Proto.Registry.empty '(\_ -> Codec.V1.decodeWellKnown)' ""
    app "$work/synth-c" "$work/synth-none/generated" "$rt" Synth.V1 Msg0 Proto.Registry.empty '(\_ -> Synth.V1.decodeMsg0)' ""
    for v in i ii iii c; do measure "$work/codec-$v" "codec_both ($v)"; measure "$work/synth-$v" "synth60 ($v)"; done ;;
esac
