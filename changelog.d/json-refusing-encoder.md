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
- Breaking: a call over JSON writes its request's JSON once before it
  builds any route, and is not sent when the request has none, over
  every binding: a value proto3 JSON has no form for in a path, a query
  or a typed `Value` body was sent unchecked. It fails with the new
  `Rpc.Error.badValue { typeName, path }`, a `BadCall` with
  `InvalidArgument`, the message `bad value: a <type> with no JSON form`
  and the `BadValue` in `protoError`; `Rpc.Error.badAny` stays the error
  of an `Any` that cannot be written (`bad Any`, `Internal`). Over
  protobuf binary such a call is sent. A call over a transcoded route
  without a body pays one JSON encode of its request it did not before.
- Breaking: `Rpc.request` gives `Result Rpc.Error Rpc.Request`: the error
  of every refusal sending makes (a base URL with a query or a fragment,
  a request with no proto3 JSON, a path value its template cannot match,
  a header a request cannot carry, a request over the write limit), so
  what it gives `Ok` is what `Rpc.task` and `Rpc.send` send, and no
  refused request is built with `null` for its message. Rewriting a
  request becomes a `case` before `Rpc.taskFromRequest`.
- Breaking (generated code): a method with a `body:` field of type
  `google.protobuf.Value` takes its routes as functions of the request
  and its JSON (`Proto.Method.withJsonRoutes`), read by the new
  `Proto.Route.jsonValueField`, which keeps a `NullValue` as `null`.
- `Proto.Json.Encoder` is `Proto.Json.Encoder.Encoder`, in a module of its
  own, so that `Proto.Message.init` and `initWith` and `Proto.Method.init`
  and `initJson` show a public name in their signatures.
- An `Any` written alone, as a method whose request is an `Any` writes
  it, counts 100 nested `Any`s, as a read of one does; a message's `Any`
  fields count from the message, as before.
- The protobuf conformance suite passes seven more cases: the
  out-of-range `Timestamp`, non-finite `Value` and unmappable
  `FieldMask` outputs.
