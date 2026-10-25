# elm-connect's binary codecs against elm-protocol-buffers

What elm-connect's `Proto.Binary` and its generated `*Bytes` codecs (this
branch, after run 3's merge) do against **eriktim/elm-protocol-buffers 1.2.0**
(`Protobuf.Decode`, `Protobuf.Encode`, `Protobuf.Types.Int64`) with the code
its usual generator writes, **protoc-gen-elm 4.0.4** (anmolitor, npm), which
also needs **anmolitor/elm-protoc-utils 2.3.0** (and, through it,
`danfishgold/base64-bytes`, `elm/parser`, `rtfeldman/elm-iso8601-date-strings`)
for its JSON codecs and well-known types.

## Setup

- protoc-gen-elm 4.0.4 from the npm registry, installed with
  `npm install --ignore-scripts --save-exact` into `spike/compare/npm`
  (gitignored); tarball integrity
  `sha512-at4f1pa9cchVe+qYj49LMX9KThuYDJNtBa7wsmFFz1GdvfQljtO/zoadZsGfw73RAy2QEcXE++loY3TCL5qDBg==`
  as the registry reports it. It is an Elm program compiled to JS
  (`elm.min.js`) plus a 1.4 KB `index.js`, with no npm dependencies. The
  Elm packages come from the package index through `elm install`.
- `spike/compare-gen.sh` writes everything under `spike/compare/`: the
  reduced corpus, protoc-gen-elm's Elm for it (`grpc=false,json`, with the
  well-known types' `.proto` files from protoc 35.1's include directory),
  elm-connect's (`codec=both,bytes=bytes`, so `bytes` is `Bytes` on both
  sides), and the protobuf suite's message for the correctness leg.
- **What protoc-gen-elm cannot take.** It accepts every file, but its output
  does not compile for three constructs, two of them in the codec corpus:
  a negative enum value (`KIND_NEGATIVE = -1`: it writes a negative literal
  pattern, which Elm has no syntax for), a `bool`-keyed map (`map<bool,
  string>`, `map<bool, Leaf>`: it writes `Dict Bool v`, and `Bool` is not
  `comparable`), and an enum with `allow_alias` (duplicate `case` patterns;
  only in the suite's message). The comparison runs on the corpus without
  `KIND_NEGATIVE` and the two `bool` maps, both sides generated from that
  copy; samples whose JSON names `KIND_NEGATIVE` are left out (130 of 140
  remain).
- Harness `spike/compare-harness/` (one Elm app holding both sides; the
  size programs reach one side and one format each, since DCE keeps a
  record whole) and drivers `spike/compare-bench.js` (codec-bench2.js's
  method: 50 rounds, median of 11, binary times from `Bytes` to `Bytes`,
  JSON times including `JSON.parse`/`stringify`) and `spike/compare-size.sh`
  (`elm make --optimize`, terser 5.36.0, gzip -9). Elm 0.19.2, Node 24.21.0.

## API shape

| | elm-connect | elm-protocol-buffers + protoc-gen-elm |
|---|---|---|
| a message decoder | `Proto.Binary.merge step finish`: a generated step that `case`s on the field number into a record update; `decodeFooBytes = mergeFooBytes defaultFoo` | `Protobuf.Decode.message default [ fieldDecoders ]`: a list of `( number, decoder )`, turned into a `Dict` once when the decoder is built |
| composition | a field's value through a `Codec` (`Proto.Binary.embedded encodeFooBytes mergeFooBytes defaultFoo`, `Proto.Binary.int32`, …) passed to a field helper | the message's `Decoder` itself (`optional 18 (map Just decodeFoo) set`), `lazy` for recursion |
| field dispatch | `case` on the number; unknown numbers skipped by wire type; a wire type the field does not take skipped as unknown | `Dict.get` on the number; unknown numbers skipped; a wrong wire type fails the decode |
| oneofs | one custom type per oneof with an unset constructor (`ChoicePickUnset \| ChoicePickText String \| …`), last member wins, a message member merges | `Maybe (Pick a0 … a11)`, a custom type with one type parameter per member applied in an internal module; last wins; no merge |
| maps | `Dict k v`; 64-bit keys as decimal `String`; `bool` keys as `List ( Bool, v )`; a later entry replaces | `Dict k v`; 64-bit keys as `( Int, Int )`; `bool` keys do not compile; each entry rebuilds the `Dict` through `Dict.toList`/`Dict.fromList` |
| repeats | `List`, read packed or not, consed and reversed once | `List`, read packed or not, each element appended with `++` |
| enums | custom type; an unknown number reads as the zero value | custom type with `Unrecognized_ Int`, keeping an unknown number; negative values do not compile |
| well-known types | runtime codecs to Elm values: `Time.Posix`, `Proto.Duration`, `Dict String Value`, `Proto.Any.Any`, wrappers as `Maybe Float`/`Maybe String`/…, `List String`, `()` | records generated from the `.proto` files: `Timestamp = { seconds : Int64, nanos : Int }`, `Any = { typeUrl : String, value : Bytes }`, wrappers as `Maybe DoubleValue` (a record with `value`) |
| 64-bit | `String`, exact (default), or `Int` range-checked (`int64=int`) | `Protobuf.Types.Int64`, opaque, two 32-bit halves |
| bytes | base64 `String` (default) or `Bytes` (`bytes=bytes`) | `Bytes` |
| unknown fields | skipped, not kept | skipped, not kept |
| merge | message fields merge | the later replaces |
| encoding | proto3 defaults left out, fields in number order, maps in key order: byte-identical to prost on the corpus | every field written, defaults included (`string ""`, `int32 0`); valid, but larger and not canonical |
| by hand | nothing; the transport runs the codecs (`Rpc.Transport.withCodec Proto`) | nothing for the codecs; `Protobuf.Decode.decode`, `Protobuf.Decode.expectBytes`, or elm-grpc for calls |

One message, `Leaf { string name = 1; int32 count = 2; }`. elm-connect:

```elm
mergeLeafBytes : Leaf -> Proto.Binary.Decoder Leaf
mergeLeafBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 -> Proto.Binary.field Proto.Binary.string (\v -> { value | name = v }) wire value
                2 -> Proto.Binary.field Proto.Binary.int32 (\v -> { value | count = v }) wire value
                _ -> Proto.Binary.skip wire value
        )
        identity

decodeLeafBytes : Proto.Binary.Decoder Leaf
decodeLeafBytes = mergeLeafBytes defaultLeaf

encodeLeafBytes : Leaf -> Bytes.Encode.Encoder
encodeLeafBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.name
        , Proto.Binary.implicit Proto.Binary.int32 2 value.count
        ]
```

protoc-gen-elm (in `Proto.Codec.V1.Internals_`, re-exported from
`Proto.Codec.V1` as `decodeLeaf`/`encodeLeaf`):

```elm
decodeProto__Codec__V1__Leaf : Protobuf.Decode.Decoder Proto__Codec__V1__Leaf
decodeProto__Codec__V1__Leaf =
    Protobuf.Decode.message defaultProto__Codec__V1__Leaf
        [ Protobuf.Decode.optional 1 Protobuf.Decode.string (\a r -> { r | name = a })
        , Protobuf.Decode.optional 2 Protobuf.Decode.int32 (\a r -> { r | count = a })
        ]

encodeProto__Codec__V1__Leaf : Proto__Codec__V1__Leaf -> Protobuf.Encode.Encoder
encodeProto__Codec__V1__Leaf value =
    Protobuf.Encode.message [ ( 1, Protobuf.Encode.string value.name ), ( 2, Protobuf.Encode.int32 value.count ) ]
```

Theirs is shorter per message and reads as data; ours is longer (a step
per field, the record passed to each helper) and compiles to a jump table.
For the corpus: elm-connect 5,662 lines for both formats; protoc-gen-elm
8,515, of which 3,294 are the well-known types it generates as messages.

## Size

Each program minus the same program without codecs (SizeNullBytes for
binary and both, SizeNull for JSON); bytes, minified / gzip:

| codecs | elm-connect | elm-protocol-buffers | difference |
|---|---:|---:|---:|
| binary | 40,326 / 10,618 | **29,124 / 7,167** | theirs −28 % / −33 % |
| binary, elm-connect without the `Any` writer's JSON conversion (scratch experiment) | 30,028 / 7,329 | 29,124 / 7,167 | theirs −3 % / −2 % |
| JSON | **36,229 / 10,568** | 41,204 / 11,305 | ours −12 % / −7 % |
| both | **60,354 / 16,148** | 64,115 / 16,826 | ours −6 % / −4 % |

Unminified attribution (`spike/compare-attr.py`), binary program:
elm-connect's generated codecs 77,003 B and runtime 77,433 B (`Proto.Binary`
48,185, `Proto.Json` 18,806, `Proto.Timestamp` 6,495, `Proto.Duration`
3,171, internal 776); protoc-gen-elm's generated codecs 109,320 B and
elm-protocol-buffers 36,451 B. Our generated code is a third smaller; our
runtime is twice theirs, and a third of it (`Proto.Json`,
`Proto.Timestamp`) is reached only because `Proto.Binary.any`'s writer
converts a well-known type's JSON form to binary. With that conversion
stubbed out, the two binary programs are within 162 B gzip. The JSON
programs: ours carries `Proto.Json` 39,003 B, theirs elm-protoc-utils
18,010 B plus three packages it pulls in (`elm/parser`, the ISO 8601
parser, base64) 36,918 B.

## Speed

µs per input, elm-connect / elm-protocol-buffers, the second of two runs
(the first agrees within 5 %). JSON columns cover only the samples both
decoders read (the count in brackets; see Correctness):

| inputs | n (JSON) | binary decode | binary encode | JSON decode | JSON encode |
|---|---:|---:|---:|---:|---:|
| corpus, all | 130 (81) | **7.66** / 8.60 | **4.28** / 10.58 | 4.65 / **2.72** | **1.54** / 1.82 |
| Scalars | 13 (13) | 9.57 / **7.42** | **3.39** / 5.46 | 6.10 / **3.07** | **1.83** / 2.97 |
| Optionals | 7 (7) | **2.55** / 3.09 | **0.96** / 2.86 | 2.94 / **1.43** | 4.61 / **1.33** |
| Repeated | 6 (0) | 8.59 / **7.46** | **4.09** / 7.42 | – | – |
| Maps | 7 (7) | **16.94** / 19.83 | **9.08** / 18.51 | 12.85 / **7.22** | **4.92** / 6.37 |
| Choice | 20 (20) | **0.99** / 1.32 | **0.67** / 1.46 | 2.40 / **1.31** | 0.42 / 0.39 |
| Names | 10 (10) | 2.11 / 2.10 | **1.03** / 2.64 | 2.38 / **0.87** | **0.70** / 0.84 |
| Outer | 8 (5) | **2.56** / 3.80 | **1.66** / 4.64 | 2.69 / **1.39** | 1.31 / **0.94** |
| Tree | 10 (0) | **7.74** / 10.09 | **5.33** / 19.10 | – | – |
| WellKnown | 8 (2) | **16.40** / 24.74 | **11.32** / 22.54 | **10.38** / 16.90 | 5.09 / 4.65 |
| Wrappers | 18 (4) | 6.95 / 7.08 | **3.31** / 7.09 | 3.93 / **2.31** | **1.30** / 1.92 |
| Across | 8 (5) | 3.26 / 3.13 | **1.78** / 4.33 | 3.18 / **1.50** | **1.03** / 1.38 |
| Leaf | 8 (8) | **0.64** / 0.90 | **0.53** / 1.02 | 0.60 / **0.38** | 0.33 / **0.23** |
| Everything | 7 (0) | **31.84** / 32.69 | **18.09** / 55.77 | – | – |
| Repeated, 1,000 leaves | 1 (1) | **887.57** / 3398.47 | **667.97** / 2410.03 | 474.88 / **229.95** | 266.23 / **137.22** |

(Optionals' JSON encode 4.61 is an outlier of that run; the first run gave
1.04.) Bytes written for the same inputs (raw / gzip, all 130): ours
9,378 / 10,833, theirs 10,755 / 11,694 (+15 % raw): theirs writes defaults.

- **Binary encode:** ours is 1.6–3.6x faster everywhere, 2.5x on the corpus
  and 3.6x on 1,000 leaves, though theirs carries widths and never copies a
  nested message: each `Protobuf.Encode.message` sorts its field list and
  builds tuples per field, and every default is written.
- **Binary decode:** ours is faster overall (−11 % on the corpus) and 3.8x
  on 1,000 leaves, where theirs appends each element with `++` (quadratic).
  **Theirs is faster on `Scalars` (−22 %) and `Repeated` (−13 %)**, the
  groups densest in 64-bit scalars (5 of `Scalars`' 16 fields; `Repeated`'s
  `int64s`/`uint64s`), and level on `Names`, `Wrappers` and `Across`. The
  likely cost, not isolated here: ours turns each 64-bit value into exact
  decimal text (`int64=string`), theirs keeps two `Int`s.
- **JSON (not the subject of this spike, measured because both have it):**
  theirs decodes 1.6–2.7x faster on what it reads (2.72 vs 4.65 µs on the
  corpus, 230 vs 475 µs on 1,000 leaves) but for `WellKnown`, where ours is
  1.6x faster, and encodes 1.9x faster on 1,000 leaves. Their decoder reads a field with one `Json.Decode.maybe
  (Json.Decode.field name decoder)`; ours (`Proto.Json.field`) decodes the
  object to `Value`, checks which spellings it holds (so an object holding
  both the JSON and the proto name fails, as protobuf requires), tests for
  `null`, then decodes the field. Theirs gets its speed partly from not
  doing that: `maybe` also turns a malformed field into its default.

## Correctness

The protobuf conformance suite (runner v32.0-rc2, same recipe style:
`--enforce_recommended --maximum_edition PROTO3`) against an
elm-protocol-buffers testee, `spike/compare-protobuf/` (the same
`testee.mjs` driver, a `Testee.elm` over the code protoc-gen-elm writes for
`test_messages_proto3.proto` with `NEG = -1`, the aliases of `AliasedEnum`
and `map<bool, bool>` removed so that it compiles). The suite runs the same
1,468 proto3 cases on both:

| level | formats | cases | elm-connect | elm-protocol-buffers |
|---|---|---:|---:|---:|
| Required | binary → binary | 482 | **480** | 463 |
| Required | binary → JSON | 298 | **294** | 0 |
| Required | JSON → binary | 148 | **136** | 0 |
| Required | JSON → JSON | 207 | **189** | 60 |
| Recommended | binary → binary | 216 | **216** | 10 |
| Recommended | binary → JSON | 10 | **10** | 0 |
| Recommended | JSON → binary | 20 | **15** | 0 |
| Recommended | JSON → JSON | 87 | **73** | 52 |
| | all | 1,468 | **1,413** | 585 |

elm-protocol-buffers' failures, by cause (`spike/out-run3/epb-conformance/`,
gitignored; the list is reproducible from the recipe):

- Binary, Required (19): a `bool` read from a varint wider than 32 bits is
  `False` (its varints go through 32-bit operations; 5); merge of a message
  arriving twice (2, the cases elm-connect fixed this run); `map<bool,
  bool>` (7, the field removed because its code does not compile); field
  number 0 accepted (3); unknown fields not kept (2, as for elm-connect).
- Binary, Recommended (206): those cases compare bytes, and it writes every
  default.
- Every case that compares a JSON output: an unset `google.protobuf.Value`
  field is written as `"optionalValue": null`, which a proto3 JSON reader
  takes as a `Value` holding `null`, so every output gains a field (the
  JSON → JSON cases it passes expect a parse failure).
- Almost every JSON input: its JSON decoders require each repeated field
  to be present ("Expecting an OBJECT with a field named
  `repeatedInt32`"), while proto3 JSON leaves an empty one out. The same
  bug rejects 49 of the 130 codec-corpus samples' canonical JSON. Their
  README says `Any` has no JSON support.

elm-connect's 55 failures are in `conformance/protobuf/failure_list.txt`:
2 binary (unknown fields not kept), 3 `Any` holding a non-well-known
message's JSON written to binary, 2 for the removed `NullValue` fields, the
rest the proto3 JSON codecs' known choices.

## Design: depend, borrow, or neither

- **Depending on it** would mean generating against `Protobuf.Decode.Decoder`
  and `Protobuf.Encode.Encoder`. `Proto.Method.withBinary`,
  `Proto.Message.withBinary` and the generated `decodeFooBytes` would then
  take and give elm-protocol-buffers' types, which puts its major version
  in elm-connect's public API: its next major forces one here, the reason
  the roadmap gives for not reusing its types. `Protobuf.Types.Int64` would
  leak too, unless every 64-bit field converted to and from
  `int64=string|int` at each read and write; that conversion is the cost
  that makes ours slower on 64-bit fields. Its dispatch, `++` appends,
  wire-type failures, written defaults, missing merge and the three
  constructs its generator cannot compile would all become ours; its
  binary codecs pass 463 of 482 Required binary cases to our 480. Gain:
  one module less to maintain (its runtime is 36 KB unminified against
  `Proto.Binary`'s 48 KB). Not worth it.
- **Borrowing from it:**
  - *Width-carrying encoders* (`( Int, Encoder )` pairs, no copy per
    nesting level): run 2 measured the same idea at −6 % on encode for
    1,000 leaves; theirs encodes 2.5x slower than ours anyway, so the
    technique is not where their time goes. Not worth a new encoder type.
  - *Keeping unknown enum numbers* (`Unrecognized_ Int`): proto3 says an
    open enum keeps an unknown value, and ours reads it as the zero value.
    It is a correctness gain, not a speed or size one. Worth considering
    before 1.0, since adding a constructor to every generated enum later is
    a breaking change for exhaustive `case`s.
  - *64-bit values as two `Int`s:* the `Scalars`/`Repeated` gap (22 %/13 %)
    is the decimal text conversion `int64=string` asks for, a choice of
    type rather than a technique; `int64=int` avoids it within ±2^53.
  - *Its JSON field reading:* 1.7x faster, partly by being wrong
    (malformed fields become defaults, `null` handling, duplicate
    spellings). Probing the object once per field, with a fast path for a
    field that has one spelling, might recover part of the gap while
    keeping the semantics. A JSON-codec question for a separate pass.
- **Neither, plus our own fix:** the comparison's largest size gap is ours
  to close. The `Any` writer's JSON conversion costs every binary program
  about 3.3 KB gzip; built under `Proto.Message.withBinary`'s closure,
  or attached where JSON produced the `Any`, it would leave binary
  programs within 2 % of elm-protocol-buffers' while keeping
  elm-connect's 2.5x faster encoding, merge, canonical bytes, and
  conformance.

**Verdict:** keep `Proto.Binary`. It is already smaller in the both-formats
and JSON programs, faster at encoding everywhere and at decoding all but
64-bit-heavy messages, and correct where elm-protocol-buffers 1.2.0 with
protoc-gen-elm 4.0.4 is not. elm-protocol-buffers is better on binary size
today (33 % smaller gzipped, all but 2 % of it from our own `Any` writer)
and on 64-bit-heavy decoding (13–22 %, a consequence of our exact `String`
holding). Borrow the open-enum idea, and fix the `Any` writer's DCE.
