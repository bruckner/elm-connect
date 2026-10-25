#!/usr/bin/env bash
# Run a command under a time limit in seconds (macOS has no timeout(1)):
#   spike/timeout.sh SECONDS command args...
exec perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"
