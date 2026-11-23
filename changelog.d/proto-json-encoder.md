- Breaking: a generated message's JSON encoder gives a
  `Proto.Json.Encoder`, `encodeNote : Note -> Proto.Json.Encoder`, which
  `Proto.Json.encode` writes, or `Proto.Json.encodeWith registry` for a
  message holding an `Any`. The write refuses a value proto3 JSON has no
  form for, which was written wrong without a word: a `Timestamp`
  outside years 1 to 9999, a `Duration` past protobuf's
  ±315,576,000,000 seconds, a `FieldMask` path that does not round-trip
  through lowerCamelCase, a NaN or infinity in a `Value`, `Struct` or
  `ListValue`. The refusal is the new `Proto.Error.NotWritable
  { typeName, path }`, which an exhaustive `case` on `Proto.Error.Error`
  must cover. A call whose request cannot be written is not sent: a
  `BadCall`, `Internal`, `unwritable request`, over transcoding wherever
  the refused value would go. Reads and the binary codec keep such
  values, as protobuf's runtimes do. The nine protobuf conformance cases
  of values with no JSON form now pass.
- A message whose JSON write nothing it holds can refuse also gets
  `jsonNote : Note -> Json.Encode.Value`, the total encoder
  `encodeNote` wraps (docs/migrating.md, "Writing JSON").
- Breaking: `encodeNoteWith` is gone, with `Proto.Json.tryObjectOfFields`,
  `tryOptionalField`, `tryRepeatedField`, `tryDictField` and
  `tryBoolMapField`; `Proto.Message.init` and `initWith`, and
  `Proto.Method.init` and `initJson`, take an encoder giving a
  `Proto.Json.Encoder` (`Proto.Json.ready << encodeTitle` for a plain
  `Title -> Json.Encode.Value`). `Proto.Json` adds `Encoder`, `encode`,
  `encodeWith`, `ready` and the `write` helpers generated code builds
  encoders from.
- A method whose request a JSON write can refuse has route functions of
  the request and its JSON (`Proto.Method.withJsonRoutes`), as one
  holding an `Any` had, so that sending checks the request.
- `Proto.Duration.fromParts` keeps a duration past protobuf's range
  rather than clamping it to the range, so a duration read from binary
  is written back as it came, and refused by a JSON write.
