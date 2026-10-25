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
