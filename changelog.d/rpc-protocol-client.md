- Calls are sent with a client, built from a protocol: `Rpc.client
  Rpc.Protocol.connect "https://api.example.com"` in place of
  `Rpc.config "https://api.example.com"`. `Rpc.Config`, `Rpc.config`
  and the record's fields are gone: `Rpc.Client.withHeaders`,
  `withTimeout`, `withCredentials` and `withRetry` set what the fields
  held, and `protocol`, `baseUrl`, `headers`, `timeout`, `credentials`
  and `retry` read it back. `Rpc.checkConfig` is `Rpc.Client.problems`,
  and `Rpc.Client.toJson` gives a client as data. A client holds
  functions, so it belongs in code rather than in a message; clients
  built alike are `==`.
- `Rpc.Transport` is gone; `Rpc.Protocol` takes its place.
  `Rpc.Transport.connect` is `Rpc.Protocol.connect`,
  `Rpc.Transport.transcode` is `Rpc.Protocol.transcode`, `connectGet` is
  `Rpc.Protocol.connect |> Rpc.Protocol.withConnectGet` (which leaves
  any other protocol unchanged), and `Rpc.Transport.connect |>
  Rpc.Transport.withCodec Rpc.Transport.Proto` is
  `Rpc.Protocol.connectProto`. `withMaxGetUrl`, `withReadMaxBytes`,
  `withWriteMaxBytes` and `name` keep their names on `Rpc.Protocol`,
  which adds `codec` (`"json"` or `"proto"`) and `toJson`.
  `Rpc.Transport.withCodec`, `Rpc.Transport.codec` and its `Json` and
  `Proto` constructors are gone.
- A call, a client and a protocol carry their codec in their type:
  `Rpc.Call Rpc.Json req res`, `Rpc.Client Rpc.Proto`. Code generated
  with `codec=json` gives `Rpc.Call Rpc.Json` calls, `codec=proto`
  gives `Rpc.Call Rpc.Proto`, and `codec=both` gives calls free in the
  codec, which a client of either sends. Annotations that named
  `Rpc.Call req res` gain the parameter. A client sending a call
  generated without its codec is a compile error.
- `Rpc.send`, `task`, `taskTraced`, `sendTraced`, `request` and
  `taskFromRequest` take an `Rpc.Client codec` in place of the config.
  `Rpc.response` takes an `Rpc.Client Rpc.Json` and a JSON call, and
  `Rpc.responseBytes` an `Rpc.Client Rpc.Proto` and a binary one.
- `Rpc.Error.MissingCodec` is gone: the types now rule out the call it
  reported.
- `Rpc.Trace.transport` is replaced by `Rpc.Trace.protocol` and
  `Rpc.Trace.codec`, and `Rpc.Trace.toJson` writes `"protocol"` and
  `"codec"` where it wrote `"transport"`.
- Methods are built by `Proto.Method.json`, `Proto.Method.proto` and
  `Proto.Method.both`, in place of `Proto.Method.method`,
  `methodBinary` and `method … |> withBinary`, and take the service's
  and the method's names first (`Proto.Method.json
  "notes.v1.NotesService" "GetNote" encodeGetNoteRequest decodeNote`);
  `withIdempotency`,
  `withRoutes` and `withBindings` follow as before. A method's type
  gains its codec, `Proto.Method.Method codec req res`.
  `Proto.Method.encodeRequestBytes` and `responseBytesDecoder` are gone;
  `encodeRequest`, `responseDecoder` and `hasJson` stay.
- The generator option value `codec=binary` (CLI `--codec binary`) is
  `codec=proto`; `binary` is refused with a diagnostic naming `proto`.
  A generated method's documentation names its codecs (`Codecs: JSON.`).
- `Proto.Any.pack` of a message with protobuf binary codecs alone
  (`codec=proto`) holds its binary alone; it held a `null` JSON beside
  it before.
- `Rpc.Retry.on` puts the policy's math on the policy, and the
  protocol modifiers install the code they need, so a program that
  names no GET, limit or retry policy carries none of their code.
- Generated route functions name each path value's local for its
  field (`name_`, `noteName_`) rather than by number (`value0_`).
