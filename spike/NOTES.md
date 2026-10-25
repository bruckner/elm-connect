# Binary codec spike: notes

Decisions taken while building, and the alternatives, for the report.

## Proto.Binary (runtime)

- **A message decoder takes its byte length** (`Int -> Bytes.Decode.Decoder a`),
  not a bare `Bytes.Decode.Decoder a`. elm/bytes has no end-of-input test, no
  position and no backtracking (`oneOf`), so a decoder cannot find where a
  message ends on its own; every read reports its width and the message loop
  counts down the length. `Proto.Binary.decode decodeXBytes bytes` supplies
  `Bytes.width` for a whole body. A nested message is read in place from the
  same stream (no slice copy).
- **Length prefixes copy.** elm/bytes cannot tell an `Encoder`'s width without
  running it (`Bytes.Encode` has `getStringWidth` but no `getWidth`), so each
  nested message, packed run and map entry is encoded to `Bytes` first and then
  copied in after its length (`delimited`): one extra copy per nesting level.
  The alternative is a generated `sizeXBytes` per message (protobuf's
  `encoded_len`), more code per message.
- **One `Codec a` per scalar and well-known type**, holding both directions,
  its default and whether it packs. Generated code passes codecs to a handful
  of field helpers (`field`, `repeated`, `mapEntry`, `implicit`, `optional`,
  `present`, `list`, `dict`, `boolMap`). A program that only decodes still
  keeps the encoders of the codecs it touches (DCE keeps a record whole).
- **64-bit integers** travel as two unsigned 32-bit halves (`U64 high low`):
  decimal text by 16-bit limbs divided by 10,000; text to bits by digit with
  the carry computed in floating point (Elm's `//` truncates to 32 bits). The
  `AsInt` codecs range-check to ±(2^53 − 1) and fail outside it, keeping
  `int64=int`'s Elm type.
- **Defaults**: a field without presence is left out at its default; a float
  at `0` or `-0` (as prost does; NaN is written: the NaN check comes first
  because Elm 0.19.2 compiles `x == 0` on a Float to `!x`). Inside a map entry
  a default key or value is left out too, as prost-reflect writes it
  (protobuf-go writes both; both are valid).
- **Map order**: the `Dict`'s order (Elm `compare`: strings by UTF-16 code
  unit, 64-bit keys held as text by their text, so `"-1" < "10" < "2"`), a
  `bool` map's `False` first. Deterministic per value, not protobuf-go's
  deterministic order for 64-bit keys held as text.
- **Not done**: a singular message field arriving twice is replaced, not
  merged (protobuf merges); a packed run arriving for a singular scalar field
  fails (protobuf takes its last element); a duplicate key in a `bool` map is
  kept twice.
- **`Any`**: read, it holds the packed message's binary (`InBinary`), as an
  `Any` from a Connect error detail does, so `Proto.Any.unpack` gives
  `BinaryOnly`. An `Any` holding JSON (decoded from proto3 JSON, or `pack`ed)
  is written with its type URL alone: the packed type's binary encoder is not
  at hand. Fixing that needs `Proto.Any.pack` to keep the binary when the
  `Message` carries binary codecs, and JSON-to-binary for the well-known
  types' JSON forms.
- **`Duration`**: `Proto.Duration.fromParts`/`toParts` are new (additive) so
  the codec reads and writes the exact seconds and nanoseconds.
- **`Timestamp`** as `Time.Posix` drops nanoseconds past the millisecond when
  read, as the JSON codec does.

## Generator (`codec=json|binary|both`)

- Default `json`: output byte-identical (the conformance corpus, the notes
  example and Eliza regenerate unchanged; only the option-list help text in
  `options_invalid`'s diagnostics gains `codec`). The header records
  `codec=binary`/`codec=both` like the other options.
- Names: `encodeFooBytes`/`decodeFooBytes` per message, wrapper and enum, and
  `encodeFooKindBytes` per oneof. Not reserved: a message `FooBytes` beside
  `Foo` would collide (`encodeFooBytes` twice). Before landing, naming.rs
  should reserve the suffix or the generator diagnose the clash.
- An enum's binary codecs are its number conversions (`Kind -> Int`,
  `Int -> Kind`, unknown → zero under either `enum_unknown`); Elm has no
  negative literal patterns, so negative numbers are `if`s in the `case`'s
  fallback.
- Every field's codec is built at its use site
  (`Proto.Binary.embedded encodeLeafBytes decodeLeafBytes defaultLeaf`), so a
  decoder allocates a `Codec` record per field read. Hoisting one top-level
  codec per message would avoid it; it needs care with recursive messages
  (a top-level value in a cycle), which the use-site form sidesteps.
- `codec=binary`: messages, oneofs and wrappers get no JSON codecs; enums keep
  theirs (their typed value `Proto.Enum.enum` holds them, and transcoded
  query parameters would need them). Such a module is for Connect's proto
  codec only: transcoding needs JSON.

## Attachment shape (additive)

- `Proto.Message.withBinary encodeFooBytes decodeFooBytes`, piped after
  `Proto.Message.message`; `Proto.Method.withBinary encodeReqBytes
  decodeResBytes`, piped after `Proto.Method.method`. A decorator composes
  with any constructor, so it fits the gen-routes spike's positional
  `methodWith encode decode descriptor [ routes ]` (and its endpoint-form
  descriptor) unchanged: `methodWith ... |> withBinary ...`.
- `Proto.Message.messageBinary` / `Proto.Method.methodBinary` build the
  binary-only values: their JSON encoder writes `null` and their JSON decoder
  fails with a message naming `codec=binary`.
- Readers: `Proto.Message.encodeBytes`/`bytesDecoder`,
  `Proto.Method.encodeRequestBytes`/`responseBytesDecoder`, all `Maybe`.
- Alternatives considered: (a) a second constructor taking all four codecs
  (`methodWithBinary encode decode encodeBytes decodeBytes descriptor`):
  positional growth, and one more variant per future codec; (b) a codec
  record type (`{ json : ..., binary : ... }`) passed to one constructor:
  cleaner for a third codec, but not additive. The decorator is additive
  and DCE-neutral for JSON-only programs (the field is `Nothing`).
- A well-known request or response type (`google.protobuf.Empty`) takes its
  codec's whole-message halves: `Proto.Binary.messageEncoder
  Proto.Binary.empty`, `Proto.Binary.messageDecoder Proto.Binary.empty`.
  `Proto.WellKnown`'s typed values do not get binary codecs yet.
- Where streaming and gRPC-Web would plug in: both frame each message as a
  5-byte envelope (flag byte, 4-byte big-endian length) around exactly the
  bytes `encodeFooBytes` writes, and `decodeFooBytes` takes that length;
  nothing in the codecs changes, only `Rpc.Body`/the transport's framing.

## Transport (run 2)

- **`Rpc.Body`** gains a bytes kind: `Rpc.Body.bytes`, `Rpc.Body.toBytes`.
  `toText` of a bytes body is `Nothing`. The body's kind picks the content
  type: text is sent as `application/json`, bytes as `application/proto`. The
  constructor is opaque, so the new kind is additive for code that builds and
  reads bodies; code that pattern-matched could not (the type is opaque).
- **`Rpc.Transport.Codec(..)` = `Json | Proto`, `withCodec`, `codec`.** Kept
  as a flag inside the internal `Connect` options (`proto : Bool`), so
  `Transport` stays `==`-comparable and the public `Codec` union lives in
  `Rpc.Transport` without an import cycle. `withCodec` on `transcode` is
  ignored, as `withMaxGetUrl` is on a transport that never GETs (documented):
  transcoding is JSON by definition. The implicit route over transcoding
  (Connect's POST) stays JSON too.
- **POST** carries `Proto.Binary.encode`'s bytes; **GET** is
  `?connect=v1&base64=1&encoding=proto&message=<unpadded URL-safe base64>`.
  Connect accepts padded or unpadded; unpadded keeps `=` out of the query.
- **Answers.** A new public `Rpc.responseBytes : Config -> Call -> Http.Response
  Bytes -> Result Error res`; `Rpc.response` keeps its `String` signature.
  `send`/`task`/`taskTraced` choose `Http.expectBytesResponse`/`bytesResolver`
  when the transport is Connect+Proto. Over Proto a 200 is decoded with the
  method's binary decoder; it must be `application/proto` or carry no
  content type (any other is a `BadResponse` naming it, the bytes kept as
  `Rpc.Body.bytes`). Any non-200 is decoded as UTF-8 text and read by the
  unchanged error path, so a Connect error stays a JSON `Rpc.Error`
  (`RpcStatus … ConnectBody`). `responseBytes` under the JSON codec reads the
  bytes as UTF-8 and behaves as `response`. `response` (text) under Proto
  fails a 200 with a `BadResponse` pointing at `responseBytes`: XHR's text
  decoding is lossy for binary, so reading it would silently corrupt.
  Alternative considered: change `Rpc.response` to take bytes always (one
  function, but a breaking signature change and a UTF-8 decode in Elm for
  every JSON answer).
- **Run-1 Q6, the rule:** a call whose method lacks the transport's codec is
  refused unsent with a new `Rpc.Error.Reason`, `MissingCodec { method,
  codec }` (`"proto"`: JSON-only method under `withCodec Proto`; `"json"`: a
  `codec=binary` method under JSON or transcoding). Code `Internal`, like
  `InvalidHeader`, since it is a local configuration fault; never retried
  (it is found by `unsendable`, before the retry loop, as `InvalidHeader` is). `Proto.Method.hasJson` is new so the
  runtime can tell a binary-only method. Alternatives: (a) fall back to JSON
  per method under Proto (silent mixed codecs; makes a half-generated program
  "work" but hides the cost the user opted out of); (b) a phantom codec type
  on `Method`/`Call` so the compiler refuses the mix (sound, but every
  signature grows a parameter: not additive). Adding a `Reason` constructor
  is a breaking change for exhaustive matches; before 1.0 that is the moment
  to reserve it.
- **Sizes:** `withWriteMaxBytes` measures the binary (encoded only when a
  limit is set); `withReadMaxBytes` the answer's bytes.
- **Trace:** a bytes request body is `"body": null` plus `"bodyBase64"`; the
  key appears only for bytes, so JSON traces are byte-identical to before.
- **Live harness:** an envelope's config takes `"codec": "json"|"proto"`;
  `xhr.mjs` sends DataView/ArrayBuffer bodies and answers
  `responseType = "arraybuffer"`; the halves path uses `Rpc.responseBytes`
  under Proto. The committed example and suite bindings stay JSON-only; the
  Proto runs use `spike/live-both/elm.json`, which compiles the same
  `Live.elm` against notes and the conformance suite generated with
  `codec=both` into `target/live/{notes,suite}-both`
  (`spike/live-both/build.sh` generates and builds `build/elm-both.js`).

## Measurements (run 2; numbers in `measurements-run2.md`)

- Binary decode in Elm is 0.46–1.93x JSON's time: faster where proto3
  JSON's decoders probe (oneofs, `Tree`, `Everything`), slower on flat
  scalars, well-known types and long repeats (1,000 leaves: 855 vs 444 µs).
  Encode is always slower, 1.1–3.5x (1,000 leaves: 721 vs 259 µs):
  `JSON.stringify` is native, `Bytes.Encode.sequence` trees are not.
- Generated binary codecs are ~1.5x the JSON ones unminified but smaller
  minified+gzipped (7.1 vs 9.2 KB for the corpus): their code is
  repetitive and they drop `Proto.Timestamp`.
- The transport path costs a JSON-only program 2.2 KB gzip (notes example),
  because `Rpc.send` reaches the bytes path statically. Moving it behind
  `withBinary` (the method carrying a closure that sends bytes) would let DCE
  drop it, but `Proto.Method` cannot import `Rpc.Internal` (cycle); it needs
  the method type in an internal module both sides import. Not done here.
- Q2 (size* vs copy): +6 % encode speed for a size function per message;
  kept the copy. Q3 (hoisting): 1 %, kept the use-site form; a hoisted
  recursive codec does compile.

## Server oracle (run 2)

- **Notes server over `application/proto`:** `conformance/live/cases/proto.json`,
  25 cases against the `codec=both` build (`spike/live-both/run.sh`): every
  notes method POSTed as binary, errors still read as JSON `Rpc.Error`s with
  their `google.rpc` details, GET as `base64=1&encoding=proto`, size limits
  on binary bytes, all five ways of sending, retry, the canned
  status/`grpc-status` answers; transcoding under Vanguard and grpc-gateway
  ignores the codec and stays JSON. `proto-missing.json` (2 cases, JSON-only
  build) checks `MissingCodec` is refused unsent. All pass. Envoy was not run
  (it needs func-e's download; the codec cannot reach transcoding's code path).
- **Found by it, fixed (run-1 Q4):** `CreateNote` with an `attachment`
  Timestamp read from proto3 JSON silently stored an empty Timestamp: the
  binary `Any` writer wrote the type URL alone. Now (a) `Proto.Any.pack` of a
  message with binary codecs keeps its binary too (`Payload` gains `InBoth`;
  internal), (b) the binary writer converts a well-known type's JSON form to
  binary, (c) `Proto.Any.unpack` reads a binary-only `Any` with a message
  that has binary codecs (new `Problem` constructor `Binary` for bytes that
  do not decode; `BinaryOnly` now means "no binary codecs to read it with"),
  (d) a Connect error detail with `debug` keeps its binary beside the JSON.
  Still lossy: an `Any` holding a non-well-known message's JSON alone (read
  from proto3 JSON) is written with its type URL alone; fixing that needs a
  codec registry (type URL → codecs), which generated code could provide per
  package beside `registry`.
- **Connect conformance, proto codec:** `conformance.mjs` selects the codec
  per request and reads results back from binary (`okBinary`,
  `detailsBinary`, which the runner now reports), and maps a `BadResponse` to
  `internal` as `Rpc.Error.code` does. `spike/live-both/conformance-proto.yaml`
  lists `CODEC_PROTO` alone: 56 cases (halves) / 56 (sendTraced, 1 known
  from known-failing-send.txt); 52 / 51 pass. The 4 failures
  (`spike/live-both/known-failing-proto.txt`) are codec-independent
  error-body readings the proto-only suites exercise: missing/null `code`
  (suite: message from body, code from HTTP status; runtime: HttpStatus
  error), unrecognized code name (suite: from HTTP status; runtime:
  `unknown`), and a non-Connect content type on a 200 (suite: `unknown`;
  runtime: BadResponse = `internal`). Fixed on the way: GET query parameters
  in the protocol's recommended order (`connect, base64, encoding, message`).
  The JSON run is unchanged: 40/40 halves, 39+1 known sendTraced.

## Protobuf conformance suite (run 2)

- **Runner:** `conformance_test_runner` v32.0-rc2, prebuilt by
  bufbuild/protobuf-conformance (GitHub release, asset
  `conformance_test_runner-32.0-rc2-osx-x86_64.zip`, SHA-256
  `9c01b26eface95c277eb4c08de09536ad6605434632c9e3682ee4d5b553ad280`, the
  digest GitHub reports for the asset; runs under Rosetta). Protobuf's own
  releases ship protoc alone. No build was needed. The repo notes v32.0 is
  bufbuild's last runner release (later ones move to an npm package).
- **Testee:** `conformance/protobuf/` — `Testee.elm`, a worker over the
  Elm generated from `test_messages_proto3.proto` under `codec=both`, and
  `testee.mjs`, a vanilla-JS pipe driver that reads ConformanceRequest and
  writes ConformanceResponse by hand (four wire types) and hands each
  request to the worker over a port. Proto2/editions messages and
  JSPB/text formats are answered `skipped`. `just protobuf-conformance`
  (opt-in, not in `check`) fetches the runner, generates, builds and runs
  it against `failure_list.txt`; it passes.
- **Deviation:** the generator refuses `google.protobuf.NullValue`
  (`types::unsupported_well_known`), so the testee's proto is the suite's
  with its two NullValue fields removed
  (`spike/protobuf-conformance/strip-null-value.sh`); 2 Recommended cases
  fail for it, classified unsupported.
- **Result** (`spike/protobuf-conformance/tally-v32.0-rc2.md`; totals from a
  `TESTEE_FAIL_ALL=1` run whose failure list names every case run): 1,468
  proto3 cases, 1,408 pass. Required 1,095/1,135, Recommended 313/333.
  Binary→binary: Required 478/482, Recommended 215/216. Binary→JSON
  292/298 + 10/10, JSON→binary 136/148 + 15/20, JSON→JSON 189/207 + 73/87.
- **Fixed on the way (ours, cheap):** repeated scalars declared
  `[packed = false]` were written packed (26 Recommended cases). The IR now
  records `unpacked` from the field's own options (prost-reflect's
  `is_packed()` reports such a field packed when the pool comes from
  protox), and the generator emits `Proto.Binary.listUnpacked`. The codec
  corpus has no such field, so its blessed output is unchanged.
- **Binary failures left (7):** merge of a message field arriving twice (5,
  ours: run-1 Q8, specified below), unknown fields not retained (2, spec
  choice). Cross-format: an `Any` holding a non-well-known message's JSON
  written to binary loses its message (3, ours: needs a codec registry).
  The other 50 are the proto3 JSON codecs' (Time.Posix milliseconds,
  encoders that cannot refuse out-of-range values, 64-bit numbers through
  Float, lenient JSON parsing, unknown enum names), classified in
  `conformance/protobuf/failure_list.txt`.
