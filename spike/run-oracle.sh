#!/usr/bin/env bash
# Builds the reference FileDescriptorSets of spike/editions-corpus with buf
# (pinned by mise.toml) and protoc (PROTOC, a protoc binary), compares them with
# the vendored protox's (spike/tools/compare-descriptors), and runs each file of
# spike/editions-invalid through protoc, buf and the vendored protox. Writes
# into OUT, a scratch directory. Usage: spike/run-oracle.sh OUT
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
corpus=$root/spike/editions-corpus
googleapis=$root/examples/notes/third_party/googleapis
protoc=${PROTOC:?set PROTOC to a protoc binary}
files=(test_messages_edition2023.proto test_messages_proto3_editions.proto notes/v1/notes.proto matrix/v1/matrix.proto)

"$protoc" --version
mise exec -C "$root" -- buf --version

# buf takes a workspace of modules; link the corpus and googleapis into one.
rm -rf "$out/bufws" && mkdir -p "$out/bufws"
ln -s "$corpus" "$out/bufws/corpus"
ln -s "$googleapis" "$out/bufws/googleapis"
printf 'version: v2\nmodules:\n  - path: corpus\n  - path: googleapis\n' > "$out/bufws/buf.yaml"
mise exec -C "$root" -- buf build "$out/bufws" --exclude-source-info -o "$out/buf.binpb"
"$protoc" -I "$corpus" -I "$googleapis" --include_imports -o "$out/protoc.binpb" "${files[@]}"

mise exec -C "$root" -- cargo build -q -j4 --manifest-path spike/tools/compare-descriptors/Cargo.toml
mise exec -C "$root" -- cargo build -q -j4 --manifest-path vendor/Cargo.toml -p protox --features bin
rc=0
"$root/spike/tools/compare-descriptors/target/debug/compare-descriptors" "$corpus" "$googleapis" \
    "buf=$out/buf.binpb" "protoc=$out/protoc.binpb" | tee "$out/compare.txt" || rc=$?

invalid=$root/spike/editions-invalid
: > "$out/invalid.tsv"
for path in "$invalid"/*.proto; do
    file=$(basename "$path")
    p=$("$protoc" -I "$invalid" -o "$out/x.binpb" "$file" 2>&1 | head -1 | sed "s|$invalid/||") || true
    rm -rf "$out/ws" && mkdir -p "$out/ws" && cp "$path" "$out/ws/"
    b=$(mise exec -C "$root" -- buf build "$out/ws" -o "$out/x.binpb" 2>&1 | head -1 | sed "s|$out/ws/||") || true
    f=$(cd "$invalid" && "$root/vendor/target/debug/protox" -I . -o "$out/x.binpb" "$file" 2>&1 \
        | grep '×' | head -1 | sed 's/^ *× *//') || true
    printf '%s\t%s\t%s\t%s\n' "${file%.proto}" "${p:-accepted}" "${b:-accepted}" "${f:-accepted}" >> "$out/invalid.tsv"
done
cat "$out/invalid.tsv"
exit $rc
