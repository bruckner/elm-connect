#!/usr/bin/env bash
# M1: the synthetic package of N messages (100, 300) at depth one (chain1)
# and five (chain5), generated three ways: (a) #142's CLI under codec=json,
# (b) #142's CLI under codec=both, (c) this branch's CLI under codec=json;
# for each, the package module's size, three cold builds (spike/make.sh)
# and the program's sizes (spike/size.sh). The program reads every message
# with its JSON decoder, and under (b) with its binary decoder too.
#
#   spike/m1.sh WORK CLI_142 RUNTIME_142 CLI_BASE
set -euo pipefail
work="$1"; cli142="$2"; rt142="$3"; clibase="$4"
here="$(cd "$(dirname "$0")/.." && pwd)"
for n in 100 300; do
  for shape in chain1 chain5; do
    for v in a b c; do
      case $v in
        a) cli=$cli142; codec=json; rt=$rt142; prog=json ;;
        b) cli=$cli142; codec=both; rt=$rt142; prog=both ;;
        c) cli=$clibase; codec=json; rt=$here/src; prog=json ;;
      esac
      label="n=$n $shape ($v)"
      dir="$work/$n-$shape-$v"
      rm -rf "$dir"; mkdir -p "$dir"
      SYNTH_PARENT=$shape RUNTIME=$rt python3 "$here/spike/synth.py" "$n" "$prog" "$dir"
      "$cli" gen -I "$dir/proto" synth/v1/synth.proto --codec "$codec" --out "$dir/generated" > /dev/null
      m="$dir/generated/Synth/V1.elm"
      printf '%s module_bytes=%s module_lines=%s\n' "$label" "$(wc -c < "$m" | tr -d ' ')" "$(wc -l < "$m" | tr -d ' ')"
      for r in 1 2 3; do "$here/spike/make.sh" "$dir" "$label run$r"; done
      "$here/spike/size.sh" "$dir/app/main.js" "$label"
    done
  done
done
