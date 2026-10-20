#!/usr/bin/env bash
# Run the Elm tests, the runtime package's and the notes example's, with
# elm-test-rs and the Elm compiler given as the first argument. The
# example is an application pinned to the development compiler, so its
# tests run from a copy of its elm.json set to that compiler's version,
# with the same sources. `just check` runs them with the pinned compiler;
# this script checks another, such as 0.19.1 in CI (design section 8).
# The codec round trips' modules under tests/Generated must exist first:
# `just codec-gen` (cargo test -p elm-connect-gen --test codec) writes them.
#
#   conformance/test-with.sh path/to/elm
set -euo pipefail

elm="${1:?usage: $0 path/to/elm}"
elm="$(command -v "$elm")"
version="$("$elm" --version)"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== Elm $version: the runtime package's tests"
(cd "$root" && elm-test-rs --compiler "$elm")

echo "== Elm $version: the notes example's tests"
example="$root/examples/notes/elm"
jq --arg version "$version" --arg example "$example" --arg src "$root/src" \
  '.["elm-version"] = $version
   | .["source-directories"] = [$example + "/src", $example + "/generated", $src]' \
  "$example/elm.json" >"$work/elm.json"
cp -R "$example/tests" "$work/tests"
(cd "$work" && elm-test-rs --compiler "$elm")
