#!/usr/bin/env bash
# Compile the runtime package and every case's expected Elm modules with
# the Elm compiler given as the first argument, against a copy of the
# harness whose `elm-version` is that compiler's. The conformance test
# (`cargo test --test conformance`) does the same with the pinned
# compiler; this script checks another one, such as 0.19.1 in CI
# (design section 8).
#
#   conformance/compile-with.sh path/to/elm
set -euo pipefail

elm="${1:?usage: $0 path/to/elm}"
elm="$(command -v "$elm")"
version="$("$elm" --version)"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A bare `elm make` first resolves and writes the dependencies, avoiding
# the first-build d.dat race the Justfile describes; it fails for want of
# input files, which is expected.
echo "== Elm $version: the runtime package"
(cd "$root" && "$elm" make --output=/dev/null >/dev/null 2>&1) || true
(cd "$root" && "$elm" make --docs="$work/docs.json")

echo "== Elm $version: the conformance corpus"
jq --arg version "$version" --arg src "$root/src" \
  '.["elm-version"] = $version | .["source-directories"] = [$src, "generated"]' \
  "$root/conformance/harness/elm.json" >"$work/elm.json"
mkdir -p "$work/generated"
(cd "$work" && "$elm" make >/dev/null 2>&1) || true

status=0
for case in "$root"/conformance/cases/*/; do
  name="$(basename "$case")"
  [ -d "$case/expected" ] || continue
  modules="$(cd "$case/expected" && find . -name '*.elm' | sed 's|^\./||' | sort)"
  [ -n "$modules" ] || continue
  # Cases compile one at a time: two may define the same module.
  rm -rf "$work/generated"
  mkdir -p "$work/generated"
  (cd "$case/expected" && cp -R . "$work/generated/")
  # shellcheck disable=SC2086 # one argument per module path
  if (cd "$work" && "$elm" make $(printf 'generated/%s ' $modules) --output=/dev/null >"$work/log" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"
    cat "$work/log"
    status=1
  fi
done
exit "$status"
