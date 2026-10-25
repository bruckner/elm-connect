#!/usr/bin/env bash
# Copy the runner's two edition 2023 test protos from its include/ into OUT
# without what elm-connect refuses, so that the rest generates under
# codec=both. From test_messages_edition2023.proto
# (input::unsupported_feature, input::extensions): the two
# delimited message fields (groupliketype = 201 and delimited_field = 202,
# which the file-wide `message_encoding = DELIMITED` reaches), the extension
# range and the two `extend` blocks (extension_int32 = 120, groupliketype =
# 121, delimited_ext = 122), and the fourteen EXPANDED repeated fields
# (unpacked_* = 89 to 102), which the binary codecs refuse. From
# test_messages_proto3_editions.proto, proto3's test message written in
# edition 2023: its fourteen EXPANDED fields (unpacked_* = 89 to 102, proto3's
# `[packed = false]`), and its two google.protobuf.NullValue fields
# (optional_null_value = 307, oneof_null_value = 120), as
# strip-null-value.sh drops them from the proto3 file. The suite's cases that
# set them fail or are reported as such; the diffs are printed.
#   spike/protobuf-conformance/strip-editions.sh INCLUDE OUT
set -euo pipefail
include="$1"
out="$2"
mkdir -p "$out/google/protobuf"
perl -0pe '
    s/\n *GroupLikeType (groupliketype|delimited_field) = 20[12];//g;
    s/\n *\/\/ extensions\n *extensions 120 to 200;//;
    s/\nextend TestAllTypesEdition2023 \{.*?\n\}\n//gs;
    s/\n *repeated \S+ unpacked_\w+ = \d+\n *\[features\.repeated_field_encoding = EXPANDED\];//g;
' "$include/google/protobuf/test_messages_edition2023.proto" \
    > "$out/google/protobuf/test_messages_edition2023.proto"
diff "$include/google/protobuf/test_messages_edition2023.proto" "$out/google/protobuf/test_messages_edition2023.proto" || true
perl -0pe '
    s/\n *repeated \S+ unpacked_\w+ = \d+ \[\n *features\.repeated_field_encoding = EXPANDED\n *\];\n//g;
    s/\n *google\.protobuf\.NullValue (optional_null_value|oneof_null_value) = \d+;//g;
' "$include/google/protobuf/test_messages_proto3_editions.proto" \
    > "$out/google/protobuf/test_messages_proto3_editions.proto"
diff "$include/google/protobuf/test_messages_proto3_editions.proto" "$out/google/protobuf/test_messages_proto3_editions.proto" || true
