#!/usr/bin/env bash
# H5: generate the synthetic package (spike/synth.py) of N messages under a
# codec option with the CLI, then time a cold `elm make --optimize` of a
# program reaching every decoder: wall time and peak RSS (/usr/bin/time -l),
# under a 300 s limit, elm-stuff deleted first, the disk floor checked first.
#
#   spike/h5.sh N CODEC     (CODEC: json | binary | both)
set -euo pipefail
n="$1"; codec="$2"
dir="spike/out-h5/$codec-$n"
free=$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')
if [ "$free" -lt 8000000 ]; then echo "disk floor: $free KiB free, stopping"; exit 2; fi
rm -rf "$dir"; mkdir -p "$dir"
python3 spike/synth.py "$n" "$codec" "$dir"
./target/debug/elm-connect gen -I "$dir/proto" synth/v1/synth.proto --codec "$codec" --out "$dir/generated" > /dev/null
pkg="$dir/generated/Synth/V1.elm"
printf 'package module %s bytes, %s lines; descriptor modules %s bytes\n' "$(wc -c < "$pkg" | tr -d ' ')" "$(wc -l < "$pkg" | tr -d ' ')" \
    "$(find "$dir/generated/Synth/V1" -name '*.elm' -exec cat {} + | wc -c | tr -d ' ')"
rm -rf "$dir/app/elm-stuff"
cd "$dir/app"
status=0
/usr/bin/time -l ../../../../spike/to.sh 300 elm make src/Main.elm --optimize --output=main.js > make.log 2> time.log || status=$?
real=$(grep -E '^ +[0-9.]+ real' time.log | awk '{print $1}')
rss=$(grep 'maximum resident set size' time.log | awk '{print $1}')
printf '%s n=%s: status %s, %s s, peak RSS %.0f MB, js %s bytes\n' "$codec" "$n" "$status" "$real" "$(echo "$rss / 1048576" | bc -l)" "$(wc -c < main.js 2>/dev/null | tr -d ' ' || echo 0)"
rm -rf elm-stuff
