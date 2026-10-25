#!/usr/bin/env bash
# Generate the notes example and the Connect conformance suite's Elm under
# codec=both into target/live/{notes,suite}-both, and compile the live runner
# against them into conformance/live/build/elm-both.js. Run from the worktree
# root after `cargo build -p protoc-gen-elm-connect`.
set -euo pipefail
root="$(pwd)"
plugin="$root/target/debug"
mkdir -p target/live
(cd examples/notes && PATH="$plugin:$PATH" buf generate \
    --template '{"version":"v2","inputs":[{"directory":"proto"},{"directory":"routes"}],"plugins":[{"local":"protoc-gen-elm-connect","out":"notes-both","opt":"codec=both"}]}' \
    -o "$root/target/live" 2> /dev/null)
(cd examples/notes && PATH="$plugin:$PATH" buf generate \
    --template '{"version":"v2","inputs":[{"directory":".","paths":["third_party/googleapis/google/rpc/error_details.proto"]}],"plugins":[{"local":"protoc-gen-elm-connect","out":"notes-both","opt":"codec=both"}]}' \
    -o "$root/target/live" 2> /dev/null)
(cd conformance/live/suite && PATH="$plugin:$PATH" buf generate \
    --template '{"version":"v2","inputs":[{"directory":"."}],"plugins":[{"local":"protoc-gen-elm-connect","out":"suite-both","opt":"streaming=skip,codec=both"}]}' \
    -o "$root/target/live" 2> /dev/null)
cd spike/live-both
elm make > /dev/null 2>&1 || true
elm make ../../conformance/live/src/Live.elm --output=../../conformance/live/build/elm-both.js
