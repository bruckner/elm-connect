#!/usr/bin/env bash
# Extra to measurement 4: one module of 300 messages in chains of 30 and of
# 100 (SYNTH_PARENT=chainK), beside three modules of 100-message chains, to
# separate module size from type depth; three rounds interleaved.
#   spike/run7.sh SCRATCH
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for v in both-300-c30 both-300-c100 both-3x100; do
        "$here/spike/make.sh" "$s/$v" "rep$r $v" || exit $?
    done
done
