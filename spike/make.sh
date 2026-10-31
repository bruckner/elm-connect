#!/usr/bin/env bash
# Time one cold `elm make --optimize` of DIR/app (elm-stuff deleted first)
# under a 300 s limit: wall time and peak RSS from /usr/bin/time -l. Checks
# the disk floor (8,000,000 KiB) and waits, polling each minute, while a
# cargo or rustc process runs. Prints one line, prefixed with LABEL.
#
#   spike/make.sh DIR LABEL
set -euo pipefail
dir="$1"; label="$2"
here="$(cd "$(dirname "$0")/.." && pwd)"
free=$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')
if [ "$free" -lt 8000000 ]; then echo "$label: disk floor: $free KiB free, stopping"; exit 2; fi
while pgrep -fl 'cargo|rustc' > /dev/null; do echo "$label: cargo/rustc running, waiting" >&2; sleep 60; done
elm="$(cd "$here" && mise which elm)"  # the worktree's pinned Elm, whatever the cwd
cd "$dir/app"
rm -rf elm-stuff main.js
status=0
/usr/bin/time -l "$here/spike/to.sh" 300 "$elm" make src/Main.elm --optimize --output=main.js > make.log 2> time.log || status=$?
real=$(grep -E '^ +[0-9.]+ real' time.log | awk '{print $1}')
rss=$(grep 'maximum resident set size' time.log | awk '{print $1}')
js=$(wc -c < main.js 2>/dev/null | tr -d ' ' || echo 0)
printf '%s: status %s, %s s, peak RSS %.0f MB, js %s bytes, free %s KiB\n' "$label" "$status" "$real" "$(echo "$rss / 1048576" | bc -l)" "$js" "$free"
rm -rf elm-stuff
