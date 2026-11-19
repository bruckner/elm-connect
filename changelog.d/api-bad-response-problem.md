- A transcoded method's `response_body` field that does not decode
  keeps elm/json's error at the field, in `Rpc.Error.protoError`, no
  longer flattened to text.
- A JSON response holding an `Any` of a type the client's registry
  lacks fails as `UnregisteredType` with its URL, in
  `Rpc.Error.protoError`, where it was a sentence inside elm/json's
  error.
