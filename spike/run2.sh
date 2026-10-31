#!/usr/bin/env bash
# Measurement 2: today's merge against the table form (spike/to_table.py)
# and the flattened case (the formatting alone), binary and both, 100 and
# 300, three rounds interleaved.
#   spike/run2.sh SCRATCH   (holds {binary,both}-{100,300}[-table|-flatcase])
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for n in 100 300; do
        for c in binary both; do
            for f in "" -table -flatcase; do
                "$here/spike/make.sh" "$s/$c-$n$f" "rep$r $c-$n${f:--today}" || exit $?
            done
        done
    done
done
