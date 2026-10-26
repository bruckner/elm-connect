# The protobuf conformance suite's testee

[protobuf's conformance suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance)
runs the runtime's protobuf binary and proto3 JSON codecs, through the Elm
generated for its test messages, against protobuf's own reference
implementation. From the
repository root:

```sh
just protobuf-conformance
```

```
proto/google/protobuf/test_messages_proto3.proto   the suite's proto3 test messages, NullValue fields stripped
proto/LICENSE                                      protobuf's license (BSD 3-Clause), which covers it
generated/                                         the Elm elm-connect generates from it (codec=both), committed
src/Testee.elm                                     the Elm worker that reads and writes each message
testee.mjs, testee.sh                              the Node driver conformance_test_runner starts
fetch-runner.sh                                    fetches the runner, checked against its SHA-256
strip-null-value.sh                                writes the proto from protobuf's
failure_list.txt                                   the cases the testee fails, classified
build/                                             the runner, the compiled worker and run output (gitignored)
```

## What runs

`conformance_test_runner` starts `testee.sh` and writes it one
`ConformanceRequest` after another on stdin, each a message to parse in
one format and to write back in another. `testee.mjs` reads the few
fields it needs by hand, a protobuf payload as base64, and hands each
request to `Testee.elm` over a port, which reads a
`protobuf_test_messages.proto3.TestAllTypesProto3` from protobuf binary
or proto3 JSON with the generated decoder and writes it back in the
format asked for with the generated encoder, or answers that the input
failed to parse. The messages are generated under `codec=both`, so an
`Any` read from JSON is written to binary through the generated
`binaryRegistry`.

1,468 cases run (1,135 Required, 333 Recommended), counting those that
must fail to parse or to serialize, by the formats of their request:

| input → output | Required | Recommended |
|---|---:|---:|
| binary → binary | 482 | 216 |
| binary → JSON | 298 | 15 |
| JSON → binary | 148 | 20 |
| JSON → JSON | 207 | 82 |

Answered `skipped`:

- JSPB and text format,
- every message but `TestAllTypesProto3`: proto2 and editions
  (`--maximum_edition PROTO3`).

The recipe runs with `--enforce_recommended`, so a Recommended case
counts as a Required one does.

## The runner

Protobuf's releases ship protoc alone, so `fetch-runner.sh` fetches
`conformance_test_runner` v32.0-rc2 as
[bufbuild/protobuf-conformance](https://github.com/bufbuild/protobuf-conformance/releases/tag/v32.0-rc2)
builds it from protobuf's `conformance/` and publishes it, the newest
release there. The script holds the release URL and the SHA-256 of each
platform's archive, which are the digests GitHub reports for the
release's assets:

| platform | asset | SHA-256 |
|---|---|---|
| macOS (x86_64; runs under Rosetta on arm64) | `conformance_test_runner-32.0-rc2-osx-x86_64.zip` | `9c01b26eface95c277eb4c08de09536ad6605434632c9e3682ee4d5b553ad280` |
| Linux x86_64 | `conformance_test_runner-32.0-rc2-linux-x86_64.zip` | `d53590d6cda2b59a8e4b21e95dc429bc1b2b6fe8d484d6fbaab1f411c743ed85` |

It checks the archive before unpacking it into
`build/conformance_test_runner-v32.0-rc2/`, and does nothing when the
runner is already there; delete that directory to fetch it again. To
move the pin, change the version and both digests together.

## The test proto

`proto/google/protobuf/test_messages_proto3.proto` is protobuf v32.0's
`src/google/protobuf/test_messages_proto3.proto` (the same file as
v32.0-rc2's, which the runner's archive carries in `include/`) with two
lines removed: the fields `oneof_null_value = 120` and
`optional_null_value = 307`, of type `google.protobuf.NullValue`, which the
generator refuses (`types::unsupported_well_known`). `strip-null-value.sh`
writes it from protobuf's file and fails unless exactly those two lines
went:

```sh
conformance/protobuf/strip-null-value.sh \
  conformance/protobuf/build/conformance_test_runner-v32.0-rc2/include/google/protobuf/test_messages_proto3.proto \
  conformance/protobuf/proto/google/protobuf/test_messages_proto3.proto
```

`just protobuf-conformance` writes it again from the runner's copy and
fails if it differs from the committed one, and fails if `generated/` is
not what `elm-connect check --codec both` expects. `just
protobuf-conformance-gen` regenerates `generated/` with the CLI built
from the checkout, with the binary codecs beside the JSON ones and the
other options at their defaults:

```sh
elm-connect gen --codec both -I proto google/protobuf/test_messages_proto3.proto --out generated
```

The proto is Copyright Google Inc. and licensed under the BSD 3-Clause
License; protobuf's `LICENSE` is beside it (`THIRD_PARTY.md`).

## Reading the failure list

`failure_list.txt` names, one per line, each case the testee fails, in
groups. A group's comment says why its cases fail and classifies them:

- **Design choice**: elm-connect does something on purpose that the
  suite disagrees with, and the documentation says so (a `Timestamp` is
  a millisecond `Time.Posix`, for one; unknown fields are not kept).
- **Fix candidate**: the runtime or the generator could do what the
  suite asks (most are inputs the JSON decoders accept and the
  specification refuses).

The groups of cases whose input is binary come first, then those whose
input is JSON; a group of the second kind lists the cases written back
as binary beside those written back as JSON, since one cause fails both.

The runner fails the run on a case that fails and is not listed, and on
a listed case that passes, so a fix removes its lines in the same change.
After a run, `build/run/failing_tests.txt` lists the failures with the
runner's reason for each, and the run's output has the request and the
testee's response. Running with `TESTEE_FAIL_ALL=1` fails every case
the testee runs (and skips what it skips), answering in the format asked
for with a payload that is no message, which makes its
`failing_tests.txt` the list of every case that runs, and its output
each case's request:

```sh
cd conformance/protobuf
mkdir -p build/all
TESTEE_FAIL_ALL=1 build/conformance_test_runner-v32.0-rc2/bin/conformance_test_runner \
  --enforce_recommended --maximum_edition PROTO3 --output_dir build/all ./testee.sh
```
