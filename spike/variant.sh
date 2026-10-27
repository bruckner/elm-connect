#!/usr/bin/env bash
# Build a variant of the working tree's runtime and examples for a size
# comparison: copy src/, examples/ and the spike programs under
# spike/out-var/NAME/ and apply spike/variants/NAME.py to the copy.
#
#   spike/variant.sh NAME
set -euo pipefail
name="$1"
dir="spike/out-var/$name"
rm -rf "$dir"; mkdir -p "$dir/spike"
cp -R src examples elm.json "$dir/"
for p in min-main notes-connect; do
    mkdir -p "$dir/spike/$p"
    cp -R "spike/$p/src" "spike/$p/elm.json" "$dir/spike/$p/"
done
rm -rf "$dir"/examples/*/elm-stuff "$dir"/examples/*/*/elm-stuff
python3 "spike/variants/$name.py" "$dir"
echo "variant $name in $dir"
