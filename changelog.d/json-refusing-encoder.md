- Breaking: a generated JSON encoder refuses a value proto3 JSON has no
  form for, where it wrote one wrongly and silently: a
  `google.protobuf.Timestamp` outside years 1 to 9999, a number in a
  `Value`, `Struct` or `ListValue` that is NaN or infinite (written as
  `null` before), and a `FieldMask` path whose lowerCamelCase form reads
  back as another path. The refusal is the new
  `Proto.Error.BadValue { typeName, path }`, `path` leading to the value
  from the message written (`"events.3.createTime"` in
  `Proto.Error.toString`). A `Duration` past protobuf's range is still
  clamped when it is built, so it is never refused.
- Breaking: every message has one JSON encoder, `encodeNote : Note ->
  Proto.Json.Encoder x` when nothing it holds can be refused and `Note ->
  Proto.Json.Encoder Proto.Error.Error` otherwise. `Proto.Json.encode`
  writes it (`Result Proto.Error.Error Json.Encode.Value`, an `Any`
  through an empty registry), `Proto.Json.encodeWith registry` writes one
  holding an `Any`, and `Proto.Json.encodeTotal : Encoder Never ->
  Json.Encode.Value` writes one that cannot refuse, with no `Result`; the
  compiler rejects `encodeTotal` of an encoder that can refuse.
  `encodeNoteWith` is gone: `Proto.Json.encodeWith registry (encodeNote
  note)` replaces it. A message that gains a refusable field, at any
  depth, changes its encoder's type, and only `encodeTotal` call sites
  break.
- Breaking: `Proto.Message.init` and `initWith`, and `Proto.Method.init`
  and `initJson`, take the request's encoder as `a -> Proto.Json.Encoder
  Proto.Error.Error`: the generated `encodeNote` as it is, or
  `Proto.Json.succeed << f` for a hand-written `f : a -> Value`, in place
  of `\_ -> Ok << f`.
- Breaking: removed from `Proto.Json`: `encodeAnyWith` and
  `encodeNestedAnyWith` (`writeAny`, run by `encode` or `encodeWith`;
  `Proto.Any.toJson` gives an `Any`'s message JSON), `registryDeeper`
  (`writeDeeper`), the `try` helpers `tryObjectOfFields`,
  `tryOptionalField`, `tryRepeatedField`, `tryDictField` and
  `tryBoolMapField` (`writeObject` and the `write` helpers), and the
  unchecked `encodeTimestamp`, `encodeDuration`, `encodeFieldMask`,
  `encodeStruct`, `encodeValue` and `encodeListValue` (`writeTimestamp`
  and the other `write` helpers; `Proto.Value.toJson` writes a `Value`
  unchecked). New in `Proto.Json`, for generated code: `Encoder`, `Field`,
  `Fields`, `succeed`, `writeObject`, `plainFields`, `checkedFields`,
  `writeOptional`, `writeRepeated`, `writeDict`, `writeBoolMap`,
  `writeMember`, `writeDeeper`, `writeTimestamp`, `writeDuration`,
  `writeFieldMask`, `writeStruct`, `writeListValue`, `writeValue`,
  `writeAny`, `totalOptionalField`, `totalRepeatedField`,
  `totalDictField` and `totalBoolMapField`; and `Proto.Route.fieldMaskText`,
  with which a route prints a mask in its path or query.
- `Rpc.Error.badAny` says `unwritable request` for a request holding a
  value proto3 JSON has no form for (`Proto.Error.BadValue`), and `bad
  Any` as before for an `Any` that cannot be written.
- The protobuf conformance suite passes seven more cases: the
  out-of-range `Timestamp`, non-finite `Value` and unmappable
  `FieldMask` outputs.
