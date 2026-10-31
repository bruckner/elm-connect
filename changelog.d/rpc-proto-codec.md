- Connect's proto codec: `Rpc.Protocol.connectProto` sends a call's
  request as protobuf binary, `application/proto` (a GET as
  `connect=v1&base64=1&encoding=proto&message=…`), and reads a
  successful answer as binary; error answers stay JSON. It needs the
  binary codecs of `codec=both` or `codec=proto`. `Rpc.Protocol.codec`
  gives `"proto"` for it. Transcoding stays JSON. A program whose
  methods have no binary codecs carries none of the binary path.
- `Rpc.responseBytes` reads an answer elm/http read as bytes, for a
  binary call sent through `Rpc.request` with an `Rpc.Client Rpc.Proto`;
  `Rpc.response` keeps reading text.
- A call of a method without binary codecs over a binary protocol, or
  of one with binary codecs alone over JSON, is a compile error where it
  is sent: the call's type and the client's both carry the codec.
- `Rpc.Body.bytes`, `bytesAs`, `toBytes` and `contentType`: a body of
  bytes, sent as `application/proto` or a type of its own. `toText` of a
  bytes body is `Nothing`.
- `withReadMaxBytes` counts a binary answer's bytes and
  `withWriteMaxBytes` a binary request's; `Rpc.Trace.toJson` gives a
  binary request body as `"body": null` and its base64 under `bodyBase64`.
- `Proto.Any`: `pack` of a message with binary codecs keeps its binary
  beside its JSON, so the `Any` is written in either form; `unpack` reads
  an `Any` that holds binary alone with such a message, and the new
  `Problem.Binary` says the binary does not decode. A Connect error
  detail with `debug` keeps its binary too.
- `Proto.Registry.withBinary` and `toBinary`: a registry can hold
  messages' codecs, which `Proto.Binary.anyWith` writes an `Any` holding
  JSON alone with, as its message's binary. Code generated with
  `codec=both` gives each package a `binaryRegistry` of its messages and
  of the well-known types they hold, and writes `Any` fields with it, so
  an `Any` read from proto3 JSON is sent as binary. `Proto.Binary.any`,
  without a registry, writes an `Any` holding JSON alone with its type
  URL alone and converts nothing, so a program generated with
  `codec=proto` carries no `Proto.Json`.
