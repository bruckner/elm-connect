# Binary codec spike: final report (run 2, legs 1–5)

Branch `spike/binary-codec` at **904a01a**: six commits on top of f0a5483 (run 1, see `REPORT-RUN1.md`). No PR, nothing merged. Scratch outputs under `spike/out-run2/` (gitignored). A verified prebuilt protobuf conformance runner was found, so no CMake build was needed.

## Commits
| leg | SHA | subject |
|---|---|---|
| 1 | f95d140 | Send Connect calls as protobuf binary |
| 2 | 4307cc1 | Measure the binary codecs against JSON |
| 3 | f2abcc6 | Check the proto codec against live servers |
| 4 | 921dbd3 | Run the protobuf conformance suite on the codecs |
| 5 | 1bac099 | Specify merge semantics for the binary decoders |
| – | 904a01a | Format the binary bench harness |

**Gate:** `just check` exits 101 at `test`; the only failure is the known path-length test `a_missing_import_names_the_include_paths_searched`, untouched. With `--no-fail-fast`, 283 Rust tests pass and that one fails. Every other gate passes alone: fmt-check, clippy, elm-check (4,394 Elm tests), snippets, changelog-check, zizmor, gitleaks, deny, license, package.

## Leg 1: transport (as built)
- **`Rpc.Body`** gains a bytes kind: `bytes` and `toBytes`. Text body → `application/json`, bytes body → `application/proto`. `toText` of a bytes body gives `Nothing`.
- **`Rpc.Transport.Codec(..) = Json | Proto`**, `withCodec`, `codec` reader. A flag inside the internal `Connect` options, so transports still compare with `==`. Over transcoding `withCodec` is ignored (the rule `withMaxGetUrl` follows today); the implicit route stays JSON.
- **Requests under `Proto`:** POST sends `Proto.Binary.encode` as the body; GET sends `?connect=v1&base64=1&encoding=proto&message=<unpadded URL-safe base64>` (the order the Connect conformance suite recommends).
- **Answers:** new `Rpc.responseBytes : Config -> Call -> Http.Response Bytes -> Result Error res`; `Rpc.response` keeps its `String` signature. `send`, `task`, `taskTraced` switch to `expectBytesResponse`/`bytesResolver` under Proto. A 200 must be `application/proto` or carry no content type; anything else is a `BadResponse` keeping the bytes. A non-200 answer is decoded as UTF-8 and goes through the unchanged JSON error path, so errors stay JSON `Rpc.Error`s. `Rpc.response` (text) on a Proto success gives a `BadResponse` pointing at `responseBytes` (XHR text decoding is lossy for binary).
- **Run-1 Q6 made explicit:** new `Rpc.Error.Reason` constructor `MissingCodec { method, codec }`: a JSON-only method under Proto (`codec = "proto"`), or a `codec=binary` method under JSON or transcoding (`codec = "json"`). Code `Internal`, nothing sent, caught before the retry loop. New reader `Proto.Method.hasJson`. Alternatives in NOTES: per-method JSON fallback (silently mixes codecs); phantom codec type (sound, not additive).
- **Size limits:** `withWriteMaxBytes` measures the binary, encoded only when a limit is set; `withReadMaxBytes` measures the answer's bytes.
- **Trace:** a bytes request body shows as `body: null` plus a `bodyBase64` key (bytes only).
- **Tests:** new `tests/Rpc/CodecTest.elm` (18 tests). Live harness takes `config.codec`; `xhr.mjs` handles DataView bodies and `arraybuffer` responses; `spike/live-both/` builds the runner against notes and the Connect suite generated with `codec=both`.

## Leg 2: measurements (`spike/measurements-run2.md`)

**Size** (Elm 0.19.2 `--optimize`, terser, gzip -9):

| program | optimized | minified | gzip |
|---|---:|---:|---:|
| JSON codecs (SizeJson − SizeNull) | 129547 | 31246 | 9172 |
| binary codecs, `codec=binary` (SizeBinary − SizeNullBytes) | 137560 | 28900 | **7094** |
| both, `codec=both` (SizeBoth − SizeNullBytes) | 256654 | 58053 | 15917 |
| notes example, baseline dfe7d38 | 298401 | 77210 | 25477 |
| notes, this head, `codec=json` | 322866 | 84428 | 27686 |
| notes, `codec=both` | 384671 | 98793 | 31594 |

- Unminified, runtime `Proto.Binary` is 42.4 KB against `Proto.Json`'s 40.9 KB.
- Generated binary codecs are about 1.5x the JSON ones unminified, but smaller minified and gzipped, because binary programs drop `Proto.Timestamp`. Per-message table in the file.
- **Finding:** the transport path costs a JSON-only program **+2.2 KB gzip (+8.7 %)**: `Rpc.send` reaches the bytes path statically, pulling in `Proto.Bytes` and elm/bytes. Fixing it means moving the bytes path behind `withBinary`, which needs the method type in an internal module (`Proto.Method` cannot import `Rpc.Internal`, import cycle). Not done; must be done before landing.

**Speed** (Node 24, median of 11; µs per input; binary times start and end at `Bytes`; JSON columns match the baseline):

| inputs | JSON decode | binary decode | ratio | JSON encode | binary encode | ratio | JSON raw/gz B | binary raw/gz B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| corpus, all (140) | 8.31 | 7.78 | 0.94 | 2.35 | 5.01 | 2.13 | 30320/23261 | 10806/12218 |
| Scalars | 5.99 | 9.95 | 1.66 | 1.61 | 3.89 | 2.42 | 5057/3423 | 1575/1541 |
| Maps | 13.59 | 17.84 | 1.31 | 4.73 | 10.46 | 2.21 | 3844/2716 | 1526/1586 |
| Tree | 12.85 | 6.39 | 0.50 | 3.56 | 5.78 | 1.62 | 1970/1340 | 695/868 |
| WellKnown | 8.37 | 15.45 | 1.84 | 3.64 | 12.89 | 3.54 | 3456/2427 | 1981/1795 |
| Everything | 47.42 | 31.82 | 0.67 | 12.13 | 20.17 | 1.66 | 6646/3947 | 2092/2032 |
| Choice | 2.10 | 0.97 | 0.46 | 0.40 | 0.73 | 1.81 | 780/1168 | 287/654 |
| Repeated, 1,000 leaves | 443.88 | 854.89 | 1.93 | 259.08 | 720.67 | 2.78 | 32742/5131 | 14869/3127 |

elm/http's `ArrayBuffer`→`DataView` handoff costs 0.03 µs.

**Run-1 Q2 and Q3 settled by numbers on the 1,000-leaf payload:**
- **Q2:** a size function per leaf instead of the copy in `delimited`: encode 705 → 660 µs (−6 %). Kept the copy; the time goes into building `Bytes.Encode.sequence` trees, not copying.
- **Q3:** hoisting each message's codec to one top-level value: decode 812 → 802 µs (−1 %, noise). A hoisted codec of a recursive message compiles and round-trips (`HoistCycle.elm`). Kept the use-site form.

## Where elm/bytes hurt, with numbers
- **Flat scalar decode** is 1.3–1.9x slower than `JSON.parse` + `Json.Decode` (Scalars, Maps, WellKnown; 1.93x on 1,000 leaves): varints are read one byte per `andThen` inside a `loop`. Binary is *faster* where the JSON decoders probe for fields: oneofs (0.46), Tree (0.50), Everything (0.67).
- **Encode** is always slower, 1.1–3.5x: `JSON.stringify` is native; elm/bytes builds `sequence` trees and varint lists.
- **No encoder width** → a copy per nested message, measured at only 6 %.
- **64-bit values** need two-halves arithmetic; **no negative literal patterns**; the `x == 0` NaN trap (as run 1).

## What binary unlocks (shown live or by the suites)
- **Servers that speak only `application/proto`:** the notes server answers every method and every way of sending over proto (25 cases).
- **`Any` binary details:** `Proto.Any.unpack` reads a binary-only `Any` with a message generated under `codec=both`. A Connect error detail carrying `debug` keeps its binary too (new internal payload `InBoth`). `Proto.Any.pack` of a message with binary codecs keeps its binary. New `Problem` constructor `Binary` for bytes that do not decode.
- **`bytes` fields without base64** on the wire.
- **Wire size:** the 1,000-leaf payload is −55 % raw and −39 % gzipped.
- **gRPC-Web readiness:** bytes body and answer path in place; the codecs read and write exactly the bytes inside a 5-byte envelope. Only framing is missing.
- **Data-loss bug found by the live leg and fixed:** a `CreateNote` whose `attachment` Timestamp came from proto3 JSON was stored empty; the binary `Any` writer wrote the type URL alone. It now converts any well-known type's JSON form to binary.

## API shape as it stands; the decoder signature (Q1)
- **Generated:** `encodeFooBytes : Foo -> Bytes.Encode.Encoder`, `decodeFooBytes : Int -> Bytes.Decode.Decoder Foo`.
- **Attachment:** `Proto.Message.withBinary` / `Proto.Method.withBinary` decorators, plus `messageBinary` / `methodBinary`.
- **Readers:** `encodeBytes`, `bytesDecoder`, `encodeRequestBytes`, `responseBytesDecoder`, `hasJson`.
- **Runtime:** `Rpc.Body.bytes`, `Rpc.Transport.withCodec`, `Rpc.responseBytes`, `MissingCodec`, `Proto.Any.Problem.Binary`, `Proto.Binary.listUnpacked`.
- **Q1, argued:** use an opaque `Proto.Binary.Decoder a` rather than a bare `Int -> Decoder a`. The length is plumbing; users meet decoders only through `Proto.Binary.decode` and `bytesDecoder`. The representation is already due to change: merge (Q8) needs a decoder starting from an existing value (`a -> Int -> Decoder a`); an opaque type absorbs that without breaking anyone. Cost: one wrapper per decode. For the encoder keep `Bytes.Encode.Encoder`; a size-carrying opaque encoder buys ~6 %.

## Conformance results
- **Connect suite, proto codec** (runner v1.0.6; `spike/live-both/conformance-proto.yaml`): 52/56 through the halves, 51/56 with `sendTraced` (one already in the known list). The 4 new failures do not depend on the codec; the suite runs these error-body cases only when the proto codec is listed. Recorded in `known-failing-proto.txt`: a Connect error body with missing/null `code` and a `message` (suite wants the message read; runtime gives HttpStatus; 2 cases); an unrecognized code name (suite wants the HTTP-status mapping; runtime gives `unknown`); a 200 with `image/jpeg` (suite wants `unknown`; runtime gives BadResponse = `internal`). Fixed in the harness: `badResponse` maps to `internal`; results and details read back from binary. JSON runs unchanged: 40/40 through the halves, 39 + 1 known with `sendTraced`. Transcoding stays JSON under Vanguard and grpc-gateway. Envoy not run.
- **Protobuf suite:** runner `conformance_test_runner` v32.0-rc2, prebuilt by **bufbuild/protobuf-conformance** (`conformance_test_runner-32.0-rc2-osx-x86_64.zip`, SHA-256 `9c01b26eface95c277eb4c08de09536ad6605434632c9e3682ee4d5b553ad280`, matching GitHub's asset digest; runs under Rosetta). Protobuf's own releases ship only protoc. Testee `conformance/protobuf/` (Elm worker + vanilla-JS pipe driver). Recipe `just protobuf-conformance`, opt-in, passes against `failure_list.txt`.
  **1,408 of 1,468 proto3 cases pass. Required 1,095/1,135. Recommended 313/333.**

  | formats | Required | Recommended |
  |---|---:|---:|
  | binary → binary | 478/482 | 215/216 |
  | binary → JSON | 292/298 | 10/10 |
  | JSON → binary | 136/148 | 15/20 |
  | JSON → JSON | 189/207 | 73/87 |

  - **Failures classified** in `failure_list.txt`: merge of a message field arriving twice (5, ours, Q8); unknown fields not kept and written back (2, spec choice); an `Any` holding a non-well-known message's JSON written to binary (3, ours; needs a codec registry); the other 50 belong to the existing JSON codecs: Time.Posix milliseconds, encoders that cannot refuse out-of-range values, 64-bit numbers read through Float, lenient JSON parsing, unknown enum names.
  - **Fixed on the way (ours, cheap):** repeated scalars declared `[packed = false]` were written packed (26 Recommended cases). The IR now reads the option from the field itself, because prost-reflect's `is_packed()` reports such a field packed when the pool comes from protox.
  - **Deviation:** the generator refuses `google.protobuf.NullValue` (`types::unsupported_well_known`); the testee uses the suite's proto with its two NullValue fields removed (`strip-null-value.sh`); 2 cases fail for it, classified unsupported. A generator gap worth a later fix.

## Recommendation and 1.0 posture
- **Land as an opt-in minor after 1.0**, once: (1) the bytes path moves behind `withBinary` so JSON-only programs pay nothing again (today +2.2 KB gzip); (2) merge (Q8) is implemented.
- **Why worth it:** only way to reach servers without a JSON codec; makes binary-only `Any` details readable; prerequisite for gRPC-Web; cuts wire size 39–55 %; codecs smaller than JSON's once minified and gzipped. Speed is mixed, not a win: decode 0.5–1.9x JSON's time, encode 1.1–3.5x slower.
- **Reserve before 1.0** (each would break code if added later): option `codec=json|binary|both`; the `*Bytes` suffix in naming.rs plus a clash diagnostic (Q5, not built); `Rpc.Error.Reason.MissingCodec`; `Proto.Any.Problem.Binary`; opaque `Proto.Binary.Decoder` if Q1 goes that way; `Rpc.Body.toText` meaning "text only".
- **Stays additive:** `Rpc.Body.bytes`/`toBytes` (`Body` opaque), `Rpc.Transport.Codec`/`withCodec`, `Rpc.responseBytes`, the `withBinary` decorators and readers, `Proto.Binary` as a whole, internal `InBoth`.

## Run-1 Q1–Q11
1. Go opaque: `Proto.Binary.Decoder a`.
2. Keep the copy (size function gains 6 %).
3. Keep the use-site form (hoisting gains 1 %; recursive hoisting compiles).
4. Mostly fixed: `pack` keeps binary, well-known JSON converts, `unpack` reads binary, Connect details keep binary. Still lossy: a non-well-known message's JSON alone; needs a codec registry, which generated code could emit per package beside `registry`.
5. Not built. Reserve the suffix and diagnose a clash before 1.0.
6. Done: `MissingCodec`, refused before sending.
7. Open. `Proto.WellKnown`'s typed values have no binary codecs; generated methods use `Proto.Binary.messageEncoder/messageDecoder` for well-known request/response types.
8. Specified, not built: generated `mergeFooBytes existing = message (finish existing) step finish` (works because `finish` only reverses lists, an involution); `decodeFooBytes = mergeFooBytes defaultFoo`; `embedded` takes the merge function; a `fieldInto` step helper. Fixes 5 conformance cases. Details in NOTES.
9. Acceptable: order deterministic per value, any order valid on the wire, no suite failure.
10. Done.
11. Path-length dependent, still failing in this worktree; out of scope.

## Not done / not verified
- Envoy not run (needs func-e's download).
- The 2.2 KB DCE fix not built.
- The `*Bytes` name reservation not built.
- notes-both size measured only with the JSON transport; the example has no Proto mode.

## Files
`spike/NOTES.md`, `spike/measurements-run2.md`, `conformance/live/cases/proto.json`, `conformance/live/cases/proto-missing.json`, `spike/live-both/run.sh`, `spike/live-both/known-failing-proto.txt`, `conformance/protobuf/` (`failure_list.txt`, `fetch-runner.sh`, `Testee.elm`, `testee.mjs`), `spike/protobuf-conformance/tally-v32.0-rc2.md`.
