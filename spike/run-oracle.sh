#!/usr/bin/env bash
# Builds the reference FileDescriptorSets of spike/editions-corpus (edition
# 2023) and spike/editions-corpus-2024 with buf (pinned by mise.toml) and protoc
# (PROTOC, a protoc binary), compares them with the vendored protox's
# (spike/tools/compare-descriptors), and runs each file of spike/editions-invalid
# (importing from its deps/) through protoc, buf and the vendored protox. Writes
# into OUT, a scratch directory. Usage: spike/run-oracle.sh OUT
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
googleapis=$root/examples/notes/third_party/googleapis
protoc=${PROTOC:?set PROTOC to a protoc binary}
files_2023=(test_messages_edition2023.proto test_messages_proto3_editions.proto notes/v1/notes.proto matrix/v1/matrix.proto)
files_2024=(test_messages_edition2023.proto test_messages_proto3_editions.proto
    vis/v1/defaults.proto vis/v1/strict.proto vis/v1/local_all.proto vis/v1/legacy.proto
    vis/v1/use.proto opt/v1/options.proto opt/v1/use.proto naming/v1/naming.proto)

"$protoc" --version
mise exec -C "$root" -- buf --version
mise exec -C "$root" -- cargo build -q -j4 --manifest-path spike/tools/compare-descriptors/Cargo.toml
mise exec -C "$root" -- cargo build -q -j4 --manifest-path vendor/Cargo.toml -p protox --features bin
rc=0

# compare NAME CORPUS FILES...: buf's and protoc's sets of CORPUS against protox's.
# protoc keeps source-retention options (edition 2024's naming and visibility
# features) only with --retain_options; buf keeps them.
compare() {
    local name=$1 corpus=$2
    shift 2
    local dir=$out/$name
    # buf takes a workspace of modules; link the corpus and googleapis into one.
    rm -rf "$dir" && mkdir -p "$dir/bufws"
    ln -s "$corpus" "$dir/bufws/corpus"
    ln -s "$googleapis" "$dir/bufws/googleapis"
    printf 'version: v2\nmodules:\n  - path: corpus\n  - path: googleapis\n' > "$dir/bufws/buf.yaml"
    mise exec -C "$root" -- buf build "$dir/bufws" --exclude-source-info -o "$dir/buf.binpb"
    "$protoc" -I "$corpus" -I "$googleapis" --include_imports --retain_options -o "$dir/protoc.binpb" "$@"
    COMPARE_FILES="$*" "$root/spike/tools/compare-descriptors/target/debug/compare-descriptors" \
        "$corpus" "$googleapis" "buf=$dir/buf.binpb" "protoc=$dir/protoc.binpb" \
        | tee "$dir/compare.txt" || rc=$?
}
compare 2023 "$root/spike/editions-corpus" "${files_2023[@]}"
compare 2024 "$root/spike/editions-corpus-2024" "${files_2024[@]}"

invalid=$root/spike/editions-invalid
: > "$out/invalid.tsv"
for path in "$invalid"/*.proto; do
    file=$(basename "$path")
    p=$("$protoc" -I "$invalid" -o "$out/x.binpb" "$file" 2>&1 | grep -v ": warning:" | head -1 | sed "s|$invalid/||") || true
    rm -rf "$out/ws" && mkdir -p "$out/ws" && cp "$path" "$out/ws/" && cp -R "$invalid/deps" "$out/ws/"
    b=$(mise exec -C "$root" -- buf build "$out/ws" -o "$out/x.binpb" 2>&1 | head -1 | sed "s|$out/ws/||") || true
    f=$(cd "$invalid" && "$root/vendor/target/debug/protox" -I . -o "$out/x.binpb" "$file" 2>&1 \
        | grep '×' | head -1 | sed 's/^ *× *//') || true
    printf '%s\t%s\t%s\t%s\n' "${file%.proto}" "${p:-accepted}" "${b:-accepted}" "${f:-accepted}" >> "$out/invalid.tsv"
done
cat "$out/invalid.tsv"
exit $rc
