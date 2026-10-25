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
