#!/usr/bin/env bash
# M4a's attribution: loo.py on one build with the groups of definitions the
# cache and the lenient registry add or change (spike/defdiff.py lists them).
#   spike/m4a-loo.sh MAIN.js
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
payload='Proto$Internal$Any$Binary,Proto$Internal$Any$Both,Proto$Internal$Any$Json,Proto$Internal$Any$empty,Proto$Internal$Any$base64Of'
reader='Proto$Json$anyWith,Rpc$Internal$Status$connectDetail'
writer='Proto$Json$encodeAnyWith'
binary='Proto$Binary$anyInto,Proto$Binary$writeAny'
registry='Proto$Internal$Registry$has,Proto$Internal$Registry$isLenient,$elm$core$Dict$member,Proto$Internal$Registry$Registry,Proto$Internal$Registry$toBytes,Proto$Internal$Registry$toJson,Proto$Registry$empty,Proto$Registry$union,Proto$Registry$withCodecs,Proto$Registry$lenient'
python3 "$here/spike/loo.py" "$1" "payload type=$payload" "JSON reader=$reader" "JSON writer=$writer" "binary codec=$binary" "registry=$registry" \
  "all five=$payload,$reader,$writer,$binary,$registry"
