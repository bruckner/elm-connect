- Breaking: `Proto.Json` is split by reader. `Proto.Json.Encode` and
  `Proto.Json.Decode`, new, mirror elm/json and hold what an application
  calls; `Proto.Json` keeps the helpers generated code calls, and
  generated modules import the new modules where they use them
  (regenerate). The leaf module `Proto.Json.Encoder` is gone, and each
  moved function has one name, listed below.
- Breaking: `Proto.Json.Encoder`, `encode`, `encodeWith`, `encodeTotal`
  and `succeed` are `Proto.Json.Encode.Encoder`, `encode`, `encodeWith`,
  `encodeTotal` and `succeed`. `Proto.Json.Encoder.Encoder` is
  `Proto.Json.Encode.Encoder`, which `Proto.Message` and `Proto.Method`
  signatures name.
- Breaking: `Proto.Json.writeTimestamp`, `writeDuration`,
  `writeFieldMask`, `writeStruct`, `writeListValue` and `writeValue` are
  `Proto.Json.Encode.timestamp`, `duration`, `fieldMask`, `struct`,
  `listValue` and `value`.
- Breaking: `Proto.Json.writeAny` is `Proto.Any.encode`: a lone `Any` is
  written with `Proto.Json.Encode.encodeWith registry (Proto.Any.encode
  any)`.
- Breaking: `Proto.Json.string`, `int32`, `uint32`, `int64`, `uint64`,
  `int64AsInt`, `uint64AsInt`, `float`, `float32`, `bytes`,
  `bytesAsBytes`, `timestamp`, `duration`, `fieldMask`, `empty`,
  `nullValue`, `struct`, `value`, `listValue` and `anyWith` are
  `Proto.Json.Decode`'s, names unchanged.
