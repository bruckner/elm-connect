- `Rpc.Error.BadResponse` is `BadResponse Code Problem Response`, with
  the new `Rpc.Error.Problem = Body Proto.Error.Error | Envelope
  String`: `Body` holds the error of a body that is not the response
  message (`BadJson`, `BadBinary` with its report, or `UnregisteredType`
  for an `Any` of a type the client's registry lacks, which was a
  sentence in elm/json's error), and `Envelope` names a malformed
  answer (another of the protocol's content types, gRPC-Web framing,
  trailers or status). Patterns binding the problem as a `String`
  change; `Rpc.Error.message` gives `bad response body: <problem>` for a
  `Body` and `bad response: <problem>` for an `Envelope`.
- A transcoded method's `response_body` field that does not decode
  keeps elm/json's error at the field, no longer flattened to text.
