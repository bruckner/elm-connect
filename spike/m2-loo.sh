#!/usr/bin/env bash
# M2's attribution: loo.py on a built program, the groups found by name in
# its optimized output. PREFIX is the generated package's compiled prefix
# (Codec or Synth).
# With FLOOR.js, every group holds only definitions FLOOR.js lacks, and
# those in none of the five groups are two more: the package's other generated code
# (its JSON codecs, which the table's entries reach too), and the rest.
#   spike/m2-loo.sh MAIN.js PREFIX [FLOOR.js]
set -euo pipefail
js="$1"; p="$2"; floor="${3:-}"
here="$(cd "$(dirname "$0")/.." && pwd)"
names=$(grep -oE '^(var|function) [A-Za-z0-9_$]+' "$js" | awk '{print $2}' | sort)
if [ -n "$floor" ]; then
  # Only what the floor does not have.
  names=$(comm -23 <(echo "$names") <(grep -oE '^(var|function) [A-Za-z0-9_$]+' "$floor" | awk '{print $2}' | sort))
fi
pick() { echo "$names" | grep -E "$1" | tr '\n' ',' | sed 's/,$//'; }
entries=$(pick "^\\\$author\\\$project\\\$${p}\\\$(.*\\\$)?registry\$|^\\\$author\\\$project\\\$Proto\\\$Registry\\\$wellKnown\$")
registry=$(pick '^\$author\$project\$Proto\$(Internal\$)?Registry\$' | tr ',' '\n' | grep -v 'wellKnown$' | tr '\n' ',' | sed 's/,$//')
binary=$(pick "^\\\$author\\\$project\\\$${p}\\\$.*\\\$(encode|decode|merge)[A-Za-z0-9_]*Bytes\$")
pbinary=$(pick '^\$author\$project\$Proto\$(Internal\$)?Binary\$')
ebytes=$(pick '^(\$elm\$bytes\$|_Bytes_)')
args=("table entries=$entries" "Proto.Registry=$registry" "binary codecs=$binary" "Proto.Binary=$pbinary" "elm/bytes=$ebytes")
args+=("all five=$entries,$registry,$binary,$pbinary,$ebytes")
if [ -n "$floor" ]; then
  grouped=$(echo "$entries,$registry,$binary,$pbinary,$ebytes" | tr ',' '\n' | sort)
  extra=$(comm -23 <(echo "$names") <(echo "$grouped"))
  gen=$(echo "$extra" | grep -E "^\\\$author\\\$project\\\$${p}\\\$" | tr '\n' ',' | sed 's/,$//')
  rest=$(echo "$extra" | grep -vE "^\\\$author\\\$project\\\$${p}\\\$" | grep . | tr '\n' ',' | sed 's/,$//')
  args+=("other generated=$gen" "other runtime/kernel=$rest" "everything over floor=$(echo "$entries,$registry,$binary,$pbinary,$ebytes,$gen,$rest" | sed 's/,,*/,/g; s/,$//')")
fi
python3 "$here/spike/loo.py" "$js" "${args[@]}"
for a in "${args[@]}"; do n=$(echo "${a#*=}" | tr ',' '\n' | grep -c . || true); echo "  ${a%%=*}: $n definitions"; done
