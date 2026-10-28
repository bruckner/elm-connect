- Connect's proto codec: `Rpc.Transport.withCodec Rpc.Transport.Proto`
  sends a call's request as protobuf binary, `application/proto` (a GET
  as `connect=v1&base64=1&encoding=proto&message=…`), and reads a
  successful answer as binary; error answers stay JSON. It needs the
  binary codecs of `codec=both` or `codec=binary`. `Rpc.Transport.codec`
  reads the setting back. Transcoding ignores it and stays JSON. A
  program whose methods have no binary codecs carries none of the binary
  path; the setting costs it a few hundred bytes gzipped.
- `Rpc.responseBytes` reads an answer elm/http read as bytes, for a call
  sent through `Rpc.request` under the proto codec; `Rpc.response` keeps
  reading text, and gives a `BadResponse` for a binary answer.
- A new `Rpc.Error.Reason`, `MissingCodec { method, codec }`, code
  `Internal`: a call of a method without binary codecs under the proto
  codec, or of one with binary codecs alone under JSON or over
  transcoding, is not sent, and is not retried.
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
  `codec=binary` carries no `Proto.Json`.
