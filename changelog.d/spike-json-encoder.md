- Every generated JSON encoder has one shape, `encodeFoo : Foo ->
  Proto.Json.Encoder`, run by `Proto.Json.encode` or
  `Proto.Json.encodeWith registry` into a `Result Proto.Error.Error
  Value`. The registry-taking `encodeFooWith` is gone. A message that
  holds nothing a write can refuse also gets `jsonFoo : Foo ->
  Json.Encode.Value`, the plain encoder its `encodeFoo` wraps.
- A JSON write refuses what proto3 JSON has no form for, with the new
  `Proto.Error.NotWritable` naming the type and the field path: a
  `Timestamp` outside years 1 to 9999, a `Duration` past protobuf's range,
  a `FieldMask` path that reads back as another, a `Value` number that is
  NaN or infinite. It refuses messages on a cycle, and `Struct`, `Value`
  and `ListValue`, nested more than 100 levels instead of overflowing the
  stack.
- `Proto.Duration.fromParts` no longer clamps, so a `Duration` read from
  binary is kept exactly; `Proto.Duration.isValid` reports its range.
- `Proto.Message.init`, `initWith`, `Proto.Method.init` and `initJson` take
  the request or message encoder as `a -> Proto.Json.Encoder`.
