#!/usr/bin/env bash
# Generate the comparison's inputs into spike/compare/ (gitignored): the codec
# corpus reduced to what protoc-gen-elm 4.0.4's output compiles (no negative
# enum value, no bool-keyed map), its Elm by protoc-gen-elm (`grpc=false,json`)
# and by elm-connect (`codec=both,bytes=bytes`), and the protobuf suite's
# test_messages_proto3.proto by protoc-gen-elm, reduced likewise. Run from the worktree root
# after `npm install --ignore-scripts protoc-gen-elm@4.0.4` in
# spike/compare/npm and `cargo build -p elm-connect`.
set -euo pipefail
protoc_dir="$HOME/.local/share/mise/installs/protoc/35.1"
protoc="$protoc_dir/bin/protoc"
inc="$protoc_dir/include"
plugin=spike/compare/npm/node_modules/.bin/protoc-gen-elm
wkt=(google/protobuf/timestamp.proto google/protobuf/duration.proto google/protobuf/struct.proto
     google/protobuf/any.proto google/protobuf/wrappers.proto google/protobuf/field_mask.proto
     google/protobuf/empty.proto)
mkdir -p spike/compare/proto
grep -v -e 'KIND_NEGATIVE = -1;' -e 'map<bool, ' conformance/codec/codec.proto > spike/compare/proto/codec.proto
cp conformance/codec/other.proto spike/compare/proto/
rm -rf spike/compare/gen spike/compare/ours spike/compare/conf-gen
mkdir -p spike/compare/gen spike/compare/conf-gen
"$protoc" -I spike/compare/proto -I "$inc" --plugin=protoc-gen-elm="$plugin" \
    --elm_out=grpc=false,json:spike/compare/gen \
    spike/compare/proto/codec.proto spike/compare/proto/other.proto "${wkt[@]}"
target/debug/elm-connect gen -I spike/compare/proto codec.proto other.proto \
    --codec both --bytes bytes --out spike/compare/ours > /dev/null
# The suite's message without what protoc-gen-elm 4.0.4's output cannot
# compile: NestedEnum's NEG = -1 (a negative literal pattern) and
# AliasedEnum's aliases MOO, moo, bAz (duplicate patterns) and so its
# allow_alias option, which protoc refuses without aliases; and the
# bool-keyed map (Dict Bool v: Bool is not comparable).
runner="$(conformance/protobuf/fetch-runner.sh)"
mkdir -p spike/compare/conf-proto/google/protobuf
grep -v -E '^\s*(NEG = -1;|MOO = 2;|moo = 2;|bAz = 2;|option allow_alias = true;|map<bool, )' \
    "$runner/include/google/protobuf/test_messages_proto3.proto" \
    > spike/compare/conf-proto/google/protobuf/test_messages_proto3.proto
"$protoc" -I spike/compare/conf-proto -I "$inc" --plugin=protoc-gen-elm="$plugin" \
    --elm_out=grpc=false,json:spike/compare/conf-gen \
    google/protobuf/test_messages_proto3.proto "${wkt[@]}"
