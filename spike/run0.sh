#!/usr/bin/env bash
# Measurement 0: json, binary and both at 300 and both's ablation variants
# (spike/ablate.py), three rounds interleaved so drift spreads over all.
#   spike/run0.sh SCRATCH   (holds json-300, binary-300, both-300, both-300-{a..e})
set -uo pipefail
s="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"
for r in 1 2 3; do
    for v in json-300 binary-300 both-300 both-300-a both-300-b both-300-c both-300-d both-300-e; do
        "$here/spike/make.sh" "$s/$v" "rep$r $v" || exit $?
    done
done
