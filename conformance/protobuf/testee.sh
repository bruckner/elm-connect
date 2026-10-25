#!/usr/bin/env bash
# The program conformance_test_runner starts: the Node testee beside this file.
exec node "$(dirname "$0")/testee.mjs"
