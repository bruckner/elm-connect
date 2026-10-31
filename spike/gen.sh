#!/usr/bin/env bash
# Generate the synthetic package(s) of N messages (spike/synth.py) under a
# codec option with this worktree's CLI into DIR (DIR/proto, DIR/generated,
# DIR/app), and print the package modules' sizes.
#
#   spike/gen.sh N CODEC DIR [PACKAGES]     (CODEC: json | binary | both)
set -euo pipefail
n="$1"; codec="$2"; dir="$3"; packages="${4:-1}"
here="$(cd "$(dirname "$0")/.." && pwd)"
cli_codec="$codec"; [ "$codec" = binary ] && cli_codec=proto
rm -rf "$dir"; mkdir -p "$dir"
python3 "$here/spike/synth.py" "$n" "$codec" "$dir" "$packages"
for p in "$dir"/proto/*/; do
    pkg="$(basename "$p")"
    "$here/target/debug/elm-connect" gen -I "$dir/proto" "$pkg/v1/$pkg.proto" --codec "$cli_codec" --out "$dir/generated" > /dev/null
done
for m in "$dir"/generated/*/V1.elm; do
    printf '%s: %s bytes, %s lines\n' "${m#$dir/generated/}" "$(wc -c < "$m" | tr -d ' ')" "$(wc -l < "$m" | tr -d ' ')"
done
