- `Rpc.Call.viaBinding` takes and gives a `Call Rpc.Json`, since
  transcoding speaks JSON: a binary call is a compile error rather than
  a call whose binding Connect ignores. `Rpc.Call.requestJson` and
  `toJson`, and `Proto.Method.encodeRequest` and `responseDecoder`, take
  a JSON call or method likewise, where they gave `null` (or a decoder
  that always fails) for a binary-only one. `Proto.Method.hasJson` is
  gone: the type says it.
