#!/usr/bin/env bash
# Run the runtime's elm-test-rs suites but the codec round trips
# (tests/Codec), whose modules `cargo test` generates under tests/Generated;
# the spike builds no Rust for them.
set -euo pipefail
files=$(find tests -name '*Test.elm' -not -path 'tests/Codec/*' | sort)
# shellcheck disable=SC2086
exec elm-test-rs $files "$@"
