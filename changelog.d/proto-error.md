- Breaking: the proto layer has one error type, `Proto.Error.Error`.
  `Proto.Any.Problem` is gone.
  `Proto.Any.tryUnpack` gives `Result Proto.Error.Error a`
  (`TypeMismatch { expected, actual }`, both full names, the type it was
  unpacked as and the type inside, or the `BadBinary` of binary that is
  not the message).
  `Proto.Any.toJson` and a JSON write of a message holding an `Any`
  (`Proto.Json.Encode.encodeWith`) give `Result Proto.Error.Error Value`: `UnregisteredType url`, or the
  `BadBinary` of the `Any` that failed, at any depth, named by its own
  type, where the old `UnwritableAny` named the outermost `Any`.
- Breaking: a request `Any` that cannot be written fails with its
  `Proto.Error.Error` in `Rpc.Error.protoError`; and `Rpc.Error.details`
  is `List (Result Proto.Error.Error Any)`: a
  Connect detail with no `type` or a `value` not in base64, and a
  `google.rpc.Status` detail with no `"@type"` or not its message, are
  the detail's `BadJson`; a `grpc-status-details-bin` that is base64 but
  not a `google.rpc.Status` is its `BadBinary`, and one that is not base64
  a `BadResponse` with code `Internal`; a type the client's registry
  lacks is `UnregisteredType`. A trace's `detailProblems` describes them
  with `Proto.Error.toString`.
- A binary answer that is not the response is a `BadResponse` whose
  `Rpc.Error.protoError` is its report, saying why and where.
- New: `Proto.Message.fieldNumbered` and `fieldNamed` find a field of a
  descriptor by number or declared name, for showing a binary report's
  path.
