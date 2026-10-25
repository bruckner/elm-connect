# Binary codec spike: notes

Decisions taken while building, and the alternatives, for the report.

## Proto.Binary (runtime)

- **A message decoder takes its byte length**, now inside the opaque
  `Proto.Binary.Decoder a` (run 3, below); it was `Int -> Bytes.Decode.Decoder a`. elm/bytes has no end-of-input test, no
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
- **Merge** (run 3, below): a singular message field arriving twice is
  merged; a field of a wire type its declaration does not take is skipped
  as unknown; a duplicate key in a `bool` map replaces the earlier entry.
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
- The transport path cost a JSON-only program 2.2 KB gzip (notes example),
  because `Rpc.send` reached the bytes path statically. Fixed in run 3 (see
  "DCE of the bytes path").
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

## Merge semantics, specified (run 2; built in run 3, see the next section)

Protobuf merges a singular message field (and a oneof's message member, if
the same member is set) that arrives twice; repeated fields inside it
concatenate, scalars take the last value. The shape that fits the
generated code:

- Generate `mergeFooBytes : Foo -> Int -> Bytes.Decode.Decoder Foo` as
  `Proto.Binary.message (finish existing) step finish`, and
  `decodeFooBytes = mergeFooBytes defaultFoo`. The trick: `finish` only
  reverses the repeated fields, an involution, so applied to a finished
  value it gives back the in-progress state the step function conses onto.
- `Proto.Binary.embedded` takes the merge function instead of the decoder
  (`embedded encodeFooBytes mergeFooBytes defaultFoo`); its `Codec` gains
  `readInto : a -> Decoder ( Int, a )`.
- A singular message field's step becomes
  `Proto.Binary.fieldInto codec value.foo (\v -> { value | foo = Just v }) wire`,
  reading into `Maybe.withDefault zero existing`; a oneof member's passes
  the member's current value from a generated `case` (`Nothing` for another
  member). Boxed recursive types (`Tree_`) get `mergeTree_Bytes (Tree_ v)`.
- Packed run for a singular scalar: take its last element. Duplicate keys of
  a `bool` map: replace (the `List ( Bool, v )` holding needs a dedup).
- Cost: one more top-level function per message, a few bytes per message
  field step; all generated, nothing public changes but `embedded`'s
  argument (a public runtime function the generated code calls).

## DCE of the bytes path (run 3)

- **Shape.** `Proto.Method.withBinary`/`methodBinary` build the whole bytes
  path as closures (`Rpc.Internal.Binary.binary`): the Connect message (POST
  bytes, GET's unpadded URL-safe base64, computed only for a GET), the
  write-limit check (encodes only when a limit is set), and the reading of
  an answer as bytes (content type, read limit, `Proto.Binary.decode`; any
  non-200 handed back to the text path as UTF-8). `Proto.Message.withBinary`
  likewise builds an `Any`'s base64 halves (`toBase64`, `fromBase64`). A
  program that never calls `withBinary` never reaches `Proto.Binary`,
  `Proto.Bytes` or elm/bytes: none of their definitions, and not elm/bytes'
  kernel, which any `Bytes.width` in the generic path would drag in whole
  (its header imports `Bytes.Encode.getWidth`/`write`).
- **The type move.** `Rpc` must read those closures, so the record moved to
  `Proto.Internal.Method` / `Proto.Internal.Message`, with the descriptor as
  a type parameter, and `Proto.Method.Method req res` /
  `Proto.Message.Message a` became aliases of
  `Internal.Method Descriptor req res` / `Internal.Message Descriptor a`.
  The descriptor stays a parameter because moving `Proto.Method.Descriptor`
  would move `Idempotency(..)`, whose constructors an alias cannot
  re-export. No cycle: `Proto.Internal.Method` imports `Rpc.Error` and
  `Rpc.Body` (neither imports a method), and `Proto.Method` imports
  `Rpc.Internal.Binary`, which imports neither `Proto.Method` nor
  `Rpc.Internal.Call`: its closures take the read limit and the text
  reader as arguments instead of a `Call`. Every public signature is
  unchanged and every test passes as it was.
- **Costs of the move.** The package site and compiler errors show
  `Proto.Internal.Method.Method` (the note `Proto.Any.Any` already carries).
  An opaque union becoming an alias is what `elm diff` would call a major
  change against a published version, so it belongs before the first Elm
  publish, or is done with the union kept public and an internal reader
  instead (which needs a public function).
- **Generic path tightened on the way:** `Rpc.Internal.Http.send`/`task`
  take the `Http.Expect`/`Http.Resolver` (no bytes twins), the request-size
  check takes the binary's length from the closure, one
  `Proto.Internal.Method.binaryUnder` serves every site.
- **What is left in a JSON-only program** (notes, `codec=json`: +552 B gzip
  over dfe7d38, from +2,700 at this run's start; numbers in
  `measurements-run3.md`): the codec setting itself, read at run time
  (`Transport.proto`, the `MissingCodec` check and its message, the answer
  guard against reading binary as text, the choice between the string and
  bytes `Expect`), about 170 B; `Any`'s binary-aware payload (`InBoth`,
  `unpack`'s `Binary` problem), about 100 B; and the bytes kind of
  `Rpc.Body` plus the refactored Connect message, about 280 B. All of it
  follows from the codec being a run-time `Transport` setting, which any
  program can turn on. Getting to zero needs the codec chosen where the
  method is built (a method with binary codecs always sends binary over
  Connect, say), so a JSON-only program has nothing to dispatch on; that is
  a different public shape from `withCodec`.
- **Found while measuring:** binary programs grew by 3.4 KB gzip between
  run 2's measurement and its final head (SizeBinary 14,663 to 18,037). The
  binary `Any` writer's conversion of a well-known type's JSON form (the
  live leg's data-loss fix) reaches `Proto.Json`'s well-known decoders and
  `Proto.Timestamp` from every binary program. Corpus binary codecs are now
  10.5 KB gzip against JSON's 9.2. The same closure trick applies (attach
  the conversion where JSON produced the `Any`); not done here.

## Merge and the decoder type (run 3)

- **Generated shape.** Per message `mergeFooBytes : Foo -> Proto.Binary.Decoder
  Foo` = `Proto.Binary.merge step finish`, and `decodeFooBytes :
  Proto.Binary.Decoder Foo` = `mergeFooBytes defaultFoo`. `merge step finish
  start` loops from `finish start`: `finish` only reverses lists, an
  involution, so a finished value is turned back into the in-progress
  state the step conses onto, and repeated fields read into it append.
  `Proto.Binary.embedded encodeFooBytes mergeFooBytes defaultFoo`; its
  `Codec` gains `readInto`. A singular message field's step is
  `Proto.Binary.fieldInto codec value.foo (\v -> { value | foo = Just v })
  wire value`; a oneof's message member passes `case value.pick of Member m
  -> Just m; _ -> Nothing`. A recursion wrapper gets `mergeTree_Bytes
  (Tree_ value) = Proto.Binary.map Tree_ (mergeTreeBytes value)` in place
  of `decodeTree_Bytes`. `merge` is a new value prefix beside
  `encode`/`decode`/`default`/`message`/`enum` and is no prefix of them.
- **Every field helper takes the record** (`field codec set wire value`,
  `repeated`, `mapEntry`, `fieldInto`): a field of a wire type its
  declaration does not take is skipped as an unknown field, leaving the
  record as it is. **Deviation from the brief:** the brief (and run 2's
  spec above) says a packed run for a singular scalar takes its last
  element. protobuf-go does not: `consumeInt32` and every singular
  consumer return `errUnknown` on a wire-type mismatch, which files the
  field as unknown (`internal/impl/codec_gen.go`, v1.36.12). Taking the
  last element would read data the reference implementation ignores, so
  the runtime follows it. Before, such a field failed the whole decode.
- **`bool` maps:** `Proto.Binary.insertBool` replaces an earlier entry for
  the key. `Dict` maps already took the last.
- **Not merged:** well-known types held as Elm values (`Timestamp`,
  `Duration`, `Struct`, `ListValue`, `Value`, `FieldMask`, `Any`) replace
  the one before (`embeddedWhole`); the wrappers merge, being plain
  messages. No suite case exercises it.
- **Q1, decided: the opaque `Proto.Binary.Decoder a`.** It costs nothing:
  Elm 0.19.2 `--optimize` compiles a one-constructor, one-field type to
  `identity` (`var $author$project$Proto$Internal$Binary$Decoder =
  $elm$core$Basics$identity`), so wrapping and unwrapping vanish. It
  hides the byte length a decoder takes (plumbing elm/bytes forces) and
  let the merge change land without touching the decoder's public type.
  It lives in `Proto.Internal.Binary` and `Proto.Binary.Decoder` is an
  alias, because `Proto.Message` runs one and `Proto.Binary` imports
  `Proto.Message` through `Proto.Json`/`Proto.Any`; the package site shows
  the internal name, as for `Any`.
- **Cost of merge**, interleaved runs of the bench (run 2's compiled
  `bench2.js` against this build, twice each): binary decode of the corpus
  8.41/8.51 → 8.91/8.89 µs (+5 %), of the 1,000 leaves 901/896 → 938/935
  µs (+4 %); encode unchanged within noise (that run-to-run noise is
  ±10 % on this machine today). The first build was +19 % on decode and
  slower on encode, because `embedded` applied the merge to the default
  eagerly for `readBody`, at every use site; making it lazy and building
  `merge`'s decoder as one closure brought it to the figures above. Size:
  `SizeBinary` +1,244 B minified, +303 B gzip.
- **Conformance:** the five merge cases pass and left `failure_list.txt`.
  1,413 of 1,468 proto3 cases pass (was 1,408): Required 1,099/1,135,
  Recommended 314/333; binary→binary Required 480/482 and Recommended
  216/216 (the two left are unknown fields not kept). Tally in
  `protobuf-conformance/tally-v32.0-rc2-merge.md`.
- `spike/codec-harness/src/Experiments.elm` and `HoistCycle.elm` (run 2's
  Q2/Q3 experiments) are ported to the new API so `Bench2` still builds.
