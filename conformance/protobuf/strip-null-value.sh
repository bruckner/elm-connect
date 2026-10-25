#!/usr/bin/env bash
# Write protobuf's test_messages_proto3.proto, read from SOURCE, to OUT with
# its two google.protobuf.NullValue fields removed (optional_null_value = 307
# and the oneof member oneof_null_value = 120): the generator has no Elm
# mapping for NullValue (types::unsupported_well_known) and refuses a file
# that uses it. Fails unless exactly those two lines went.
#   conformance/protobuf/strip-null-value.sh SOURCE OUT
set -euo pipefail
source="$1"
out="$2"
mkdir -p "$(dirname "$out")"
grep -v -E '^\s*google\.protobuf\.NullValue (optional_null_value|oneof_null_value) = [0-9]+;' "$source" > "$out"
removed=$(( $(wc -l < "$source") - $(wc -l < "$out") ))
if [[ "$removed" -ne 2 ]]; then
  echo "strip-null-value.sh: removed $removed lines from $source, expected 2" >&2
  exit 1
fi
