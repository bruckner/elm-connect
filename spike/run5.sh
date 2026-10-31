#!/usr/bin/env bash
# Extra to measurement 0: the same 300 messages with every `parent` at Msg0
# (SYNTH_PARENT=root: no type nests past two deep) against the chain, to
# separate module size from the depth of the message types; three rounds
# interleaved.
#   spike/run5.sh SCRATCH
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for v in json-300 json-300-root binary-300 binary-300-root both-300 both-300-root both-300-root-a both-300-root-table both-3x100 both-3x100-root; do
        "$here/spike/make.sh" "$s/$v" "rep$r $v" || exit $?
    done
done
