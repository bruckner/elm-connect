- Breaking: a generated JSON encoder refuses a value proto3 JSON has no
  form for, where it wrote one wrongly and silently: a
  `google.protobuf.Timestamp` outside years 1 to 9999, a number in a
  `Value`, `Struct` or `ListValue` that is NaN or infinite (written as
  `null` before), and a `FieldMask` path whose lowerCamelCase form reads
  back as another path. The refusal is the new
  `Proto.Error.BadValue { typeName, path, message }`, `path` leading to
  the value from the message written (`"events.3.createTime"` in
  `Proto.Error.toString`) and `message` saying what is wrong with it
  (`"the time is outside years 1 to 9999"`), never quoting the value. A
  `Duration` past protobuf's range is still
  clamped when it is built, so it is never refused.
- Breaking: every message has one JSON encoder, `encodeNote : Note ->
  Proto.Json.Encode.Encoder x` when nothing it holds can be refused and `Note ->
  Proto.Json.Encode.Encoder Proto.Error.Error` otherwise. `Proto.Json.Encode.encode`
  writes it (`Result Proto.Error.Error Json.Encode.Value`, an `Any`
  through an empty registry), `Proto.Json.Encode.encodeWith registry` writes one
  holding an `Any`, and `Proto.Json.Encode.encodeTotal : Encoder Never ->
  Json.Encode.Value` writes one that cannot refuse, with no `Result`; the
  compiler rejects `encodeTotal` of an encoder that can refuse.
  `encodeNoteWith` is gone: `Proto.Json.Encode.encodeWith registry (encodeNote
  note)` replaces it. A message that gains a refusable field, at any
  depth, changes its encoder's type, and only `encodeTotal` call sites
  break.
- Breaking: `Proto.Message.init` and `initWith`, and `Proto.Method.init`
  and `initJson`, take the request's encoder as `a -> Proto.Json.Encode.Encoder
  Proto.Error.Error`: the generated `encodeNote` as it is, or
  `Proto.Json.Encode.succeed << f` for a hand-written `f : a -> Value`, in place
  of `\_ -> Ok << f`.
- Breaking: removed from `Proto.Json`: `encodeAnyWith` and
  `encodeNestedAnyWith` (`Proto.Json.Encode.any`, run by `encode` or
  `encodeWith`; `Proto.Any.toJson` gives an `Any`'s message JSON),
  `registryDeeper` (`Proto.Json.Encode.deeper`), the `try` helpers
  `tryObjectOfFields`, `tryOptionalField`, `tryRepeatedField`,
  `tryDictField` and `tryBoolMapField` (`Proto.Json.Encode.checkedObject` and
  the checked field encoders), and the unchecked `encodeTimestamp`,
  `encodeDuration`, `encodeFieldMask`, `encodeStruct`, `encodeValue` and
  `encodeListValue` (`Proto.Json.Encode.timestamp` and the other checked
  value encoders; `Proto.Value.toJson` writes a `Value` unchecked). New
  in `Proto.Json.Encode`, for generated code: `Encoder`, `Field`,
  `Fields`, `succeed`, `checkedObject`, `fields`, `checkedFields`,
  `optional`, `checkedRepeated`, `checkedDict`, `checkedBoolMap`,
  `member`, `deeper`,
  `timestamp`, `duration`, `fieldMask`, `struct`, `listValue`, `value`,
  `any`, `totalOptional` and `totalRepeated`; and
  `Proto.Route.fieldMaskText`,
  with which a route prints a mask in its path or query.
- Breaking: a call over JSON writes its request's JSON once before it
  builds any route, and is not sent when the request has none, over
  every binding: a value proto3 JSON has no form for in a path, a query
  or a typed `Value` body was sent unchecked. It fails with the new
  `Rpc.Error.badValue { typeName, path, message }`, a `BadCall` with
  `InvalidArgument`, the message `bad value: a <type> with no JSON form
  (<what is wrong>)` and the `BadValue` in `protoError`; `Rpc.Error.badAny` stays the error
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
- An `Any` written alone, as a method whose request is an `Any` writes
  it, counts 100 nested `Any`s, as a read of one does; a message's `Any`
  fields count from the message, as before.
- The protobuf conformance suite passes seven more cases: the
  out-of-range `Timestamp`, non-finite `Value` and unmappable
  `FieldMask` outputs.
