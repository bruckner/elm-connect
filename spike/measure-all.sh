#!/usr/bin/env bash
# Measure the four programs (min, notes-connect, eliza, notes) on the
# working tree's runtime (B) and on each variant spike/variant.sh built,
# into spike/out-final/<name>/.
#
#   spike/measure-all.sh [variant ...]
set -euo pipefail
progs() { # root
    local r="$1"
    echo "min=${r}spike/min-main:src/Main.elm" "notes-connect=${r}spike/notes-connect:src/Main.elm" \
        "eliza=${r}examples/eliza:src/Main.elm" "notes=${r}examples/notes/elm:src/Main.elm"
}
echo "== B"
# shellcheck disable=SC2046
bash spike/measure.sh spike/out-final/B $(progs "")
for v in "$@"; do
    echo "== $v"
    # shellcheck disable=SC2046
    bash spike/measure.sh "spike/out-final/$v" $(progs "spike/out-var/$v/")
done
