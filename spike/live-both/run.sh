#!/usr/bin/env bash
# The proto-codec live legs: the notes server over application/proto
# (conformance/live/cases/proto.json against the codec=both build, and
# proto-missing.json against the JSON-only one), then the Connect conformance
# suite with the proto codec, through the halves and with Rpc.sendTraced.
# Run from the worktree root after spike/live-both/build.sh and
# `just live-build` (which builds the server and build/elm.js).
set -euo pipefail
server=target/live/bin/notes-server
node conformance/live/run.mjs --serve "$server" --elm conformance/live/build/elm-both.js \
    conformance/live/cases/notes.json conformance/live/cases/transcode.json conformance/live/cases/proto.json
node conformance/live/run.mjs --serve "$server" --prefix /gateway --transport transcode \
    --elm conformance/live/build/elm-both.js conformance/live/cases/proto.json
node conformance/live/run.mjs --serve "$server" conformance/live/cases/proto-missing.json
cd conformance/live
runner="$(./fetch-conformance.sh)"
known=../../spike/live-both/known-failing-proto.txt
"$runner" --mode client --conf ../../spike/live-both/conformance-proto.yaml --known-failing @"$known" \
    -- node conformance.mjs --send halves --elm build/elm-both.js
cat "$known" known-failing-send.txt > build/known-failing-proto-send.txt
"$runner" --mode client --conf ../../spike/live-both/conformance-proto.yaml --known-failing @build/known-failing-proto-send.txt \
    -- node conformance.mjs --send sendTraced --elm build/elm-both.js
# gRPC-Web (spike/grpc-web): the notes server's methods over
# Rpc.Transport.grpcWeb (cases/grpcweb.json, from spike/make-grpcweb-cases.mjs),
# then the Connect conformance suite's gRPC-Web client cases.
cd ../..
node conformance/live/run.mjs --serve "$server" --elm conformance/live/build/elm-both.js \
    conformance/live/cases/grpcweb.json
cd conformance/live
cat ../../spike/live-both/known-failing-grpcweb.txt ../../spike/live-both/known-failing-grpcweb-halves.txt \
    > build/known-failing-grpcweb-halves.txt
"$runner" --mode client --conf ../../spike/live-both/conformance-grpcweb.yaml --known-failing @build/known-failing-grpcweb-halves.txt \
    -- node conformance.mjs --send halves --elm build/elm-both.js
cat ../../spike/live-both/known-failing-grpcweb.txt known-failing-send.txt > build/known-failing-grpcweb-send.txt
"$runner" --mode client --conf ../../spike/live-both/conformance-grpcweb.yaml --known-failing @build/known-failing-grpcweb-send.txt \
    -- node conformance.mjs --send sendTraced --elm build/elm-both.js
