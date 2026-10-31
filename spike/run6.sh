#!/usr/bin/env bash
# Extra to measurements 0 and 2: 300 messages in chains of ten
# (SYNTH_PARENT=chain10), today's merge, the merge stubbed and the table
# form; and json at 600 with every parent at Msg0. Three rounds interleaved.
#   spike/run6.sh SCRATCH
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for v in json-300-c10 binary-300-c10 binary-300-c10-table both-300-c10 both-300-c10-a both-300-c10-table json-600-root; do
        "$here/spike/make.sh" "$s/$v" "rep$r $v" || exit $?
    done
done
