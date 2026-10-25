#!/usr/bin/env bash
# Writes the edition 2023 twin of a proto3 file to stdout: the syntax
# statement becomes `edition = "2023";`, the file sets implicit presence
# after its package statement, and each `optional` field sets explicit
# presence instead. Nothing else changes, comments included, so the twin
# generates what the proto3 file does. The corpus case
# editions_2023_proto3_equivalent holds the twins of codec_both's inputs.
#   spike/editions-twin.sh FILE.proto > TWIN.proto
set -euo pipefail
sed -E \
    -e 's/^syntax = "proto3";$/edition = "2023";/' \
    -e 's/^(package [A-Za-z0-9_.]+;)$/\1\n\noption features.field_presence = IMPLICIT;/' \
    -e 's/^( *)optional ([^=]+) = ([0-9]+);/\1\2 = \3 [features.field_presence = EXPLICIT];/' \
    "$1"
