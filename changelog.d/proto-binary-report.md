- `Proto.Binary.decode` gives `Result Proto.Error.Binary a` in place of
  `Maybe a`: the full name of the message read, the reason
  (`Proto.Error.Reason`: `Truncated`, `LengthOverrun`, `InvalidTag`,
  `InvalidWireType`, `MalformedVarint`, `IntOutOfRange`, `InvalidUtf8`,
  `Unlocated`, and `MissingRequired`, reserved for a proto2 `required`
  field and never given while the generator reads proto3 alone),
  the fields the failure is in, as message names and field numbers,
  and the offset of the first byte that could not be read. A successful
  decode costs what it did: the report is built by a second pass over
  the input, run only when the first fails.
- New module `Proto.Error`: the proto layer's error type, `Error`
  (`BadBinary`, `BadJson`, `TypeMismatch`, `UnregisteredType`), the
  binary report `Binary` and its `Reason`, and `toString` for a log.
- `Proto.Binary` fails a `string` field whose bytes are not UTF-8, as
  proto3 requires, map keys, `StringValue` and an `Any`'s type URL
  included. Each string is read from its own slice of the input, so a
  string ending in the first byte of a multi-byte character, or in a
  stray continuation byte, no longer reads past its end. A string of
  ASCII costs nothing more to read.
- Generated binary decoders pass the message's full name to
  `Proto.Binary.merge`, which now takes it first, and its step gives a
  `Proto.Binary.Field`. Regenerate.
