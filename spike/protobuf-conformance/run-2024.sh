#!/usr/bin/env bash
# `just protobuf-conformance` with the testee generated from the edition 2024
# rewrites of the two editions test protos (spike/editions-corpus-2024/, which
# keep their packages and message names, so the runner's cases reach them) and
# the runner told to go up to edition 2024. The same subsets are taken
# (strip-editions.sh) and the same failure list applies. Run from the
# repository root: spike/protobuf-conformance/run-2024.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
target=${CARGO_TARGET_DIR:-$root/target}
cd "$root"
cargo build -p elm-connect
runner="$(conformance/protobuf/fetch-runner.sh)"
out=$target/protobuf-conformance
rm -rf "$out/elm" "$out/proto" "$out/include-2024"
mkdir -p "$out/include-2024/google/protobuf"
cp spike/editions-corpus-2024/test_messages_edition2023.proto \
    spike/editions-corpus-2024/test_messages_proto3_editions.proto "$out/include-2024/google/protobuf/"
spike/protobuf-conformance/strip-null-value.sh "$runner/include" "$out/proto" > /dev/null
spike/protobuf-conformance/strip-editions.sh "$out/include-2024" "$out/proto" > /dev/null
grep -h '^edition' "$out/proto/google/protobuf/test_messages_edition2023.proto" \
    "$out/proto/google/protobuf/test_messages_proto3_editions.proto"
"$target/debug/elm-connect" gen -I "$out/proto" google/protobuf/test_messages_proto3.proto \
    google/protobuf/test_messages_edition2023.proto \
    google/protobuf/test_messages_proto3_editions.proto --codec both --out "$out/elm"
cd conformance/protobuf
elm make > /dev/null 2>&1 || true
elm make src/Testee.elm --optimize --output=build/testee.js
mkdir -p "$out/run"
"$runner/bin/conformance_test_runner" --enforce_recommended --maximum_edition 2024 \
    --failure_list failure_list.txt --output_dir "$out/run" ./testee.sh
