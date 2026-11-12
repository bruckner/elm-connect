- Breaking: the proto layer has one error type, `Proto.Error.Error`.
  `Proto.Any.Problem` and `Rpc.Error.DetailProblem` are gone.
  `Proto.Any.tryUnpack` gives `Result Proto.Error.Error a`
  (`TypeMismatch { expected, actual }`, both full names, the type it was
  unpacked as and the type inside, or the `BadBinary` of binary that is
  not the message).
  `Proto.Any.toJson`, `Proto.Json.encodeAnyWith`, the generated
  `encodeNoteWith` and `Proto.Message.initWith`'s encoder give
  `Result Proto.Error.Error Value`: `UnregisteredType url`, or the
  `BadBinary` of the `Any` that failed, at any depth, named by its own
  type, where the old `UnwritableAny` named the outermost `Any`.
- Breaking: `Rpc.Error.UnwritableRequest` holds a `Proto.Error.Error`,
  and `StatusError.details` is `List (Result Proto.Error.Error Any)`: a
  Connect detail with no `type` or a `value` not in base64, and a
  `google.rpc.Status` detail with no `"@type"` or not its message, are
  the detail's `BadJson`; an undecodable `grpc-status-details-bin` is
  the `BadBinary` of `google.rpc.Status`; a type the client's registry
  lacks is `UnregisteredType`. A trace's `detailProblems` and
  `Rpc.Error.message` describe them with `Proto.Error.toString`.
- A binary answer that is not the response is a `BadResponse` whose
  problem says why and where (`Proto.Error.toString` of its report), in
  place of "the body is not the response of … in protobuf binary".
- Breaking: `Rpc.Error.Reason`'s `InvalidHeader` is renamed `BadHeader`,
  and `InvalidPathValue` `BadPathValue`, in the form of `BadUrl` and
  `BadResponse`.
- New: `Proto.Message.fieldNumbered` and `fieldNamed` find a field of a
  descriptor by number or declared name, for showing a binary report's
  path.
