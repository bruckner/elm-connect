#!/usr/bin/env bash
# Run a command under a wall-clock limit in seconds (macOS has no timeout(1)):
#   spike/to.sh SECONDS cmd args...
# SIGALRM survives exec, so the command is killed when the limit passes.
secs="$1"; shift
exec perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
