#!/usr/bin/env bash
# Measurement 4: one package module of 300 messages against three packages
# of 100 with no references between them, binary and both, three rounds
# interleaved.
#   spike/run4.sh SCRATCH   (holds {binary,both}-300 and {binary,both}-3x100)
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for c in binary both; do
        for v in 300 3x100; do
            "$here/spike/make.sh" "$s/$c-$v" "rep$r $c-$v" || exit $?
        done
    done
done
