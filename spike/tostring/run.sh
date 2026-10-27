#!/usr/bin/env bash
# Build spike/tostring's two programs and print their output: Main
# unoptimized (Debug.toString of a client and a call), Eq with --optimize
# (== on clients).
set -euo pipefail
cd "$(dirname "$0")"
run() {
    node -e 'const s={};new Function(require("fs").readFileSync(process.argv[1],"utf8")).call(s);const a=s.Elm[process.argv[2]].init();a.ports.out.subscribe(x=>console.log(x));' "$1" "$2"
}
elm make src/Main.elm --output=elm-stuff/main.js > /dev/null
run elm-stuff/main.js Main
elm make src/Eq.elm --optimize --output=elm-stuff/eq.js > /dev/null
run elm-stuff/eq.js Eq
