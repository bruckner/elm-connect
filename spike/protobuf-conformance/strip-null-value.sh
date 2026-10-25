#!/usr/bin/env bash
# Copy test_messages_proto3.proto from the runner's include/ into OUT with
# its two google.protobuf.NullValue fields removed (optional_null_value = 307
# and the oneof member oneof_null_value = 120): the generator has no mapping
# for NullValue (types::unsupported_well_known), so the suite's cases that set
# them fail as unsupported.
#   spike/protobuf-conformance/strip-null-value.sh INCLUDE OUT
set -euo pipefail
include="$1"
out="$2"
mkdir -p "$out/google/protobuf"
grep -v -E '^\s*google\.protobuf\.NullValue (optional_null_value|oneof_null_value) = [0-9]+;' \
    "$include/google/protobuf/test_messages_proto3.proto" > "$out/google/protobuf/test_messages_proto3.proto"
diff "$include/google/protobuf/test_messages_proto3.proto" "$out/google/protobuf/test_messages_proto3.proto" || true
