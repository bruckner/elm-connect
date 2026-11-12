- `Proto.Error.Reason`'s reason for a 64-bit integer an `Int` cannot
  hold is `IntOutOfRange`, so `Proto.Error(..)` and `Rpc.Code(..)` can
  be exposed together; the binary report's note already uses the
  new name.
- `Rpc.Retry.next` takes the failed call's `error : Rpc.Error.Error` in
  place of `code : Rpc.Code.Code`, and reads the code itself; like the
  runtime's own loop it stops on a `BadUrl`, where nothing was sent.
  Replace `code = Rpc.Error.code err` with `error = err`.
- `Rpc.withRegistry` is `Rpc.Client.withRegistry`, beside the client's
  other modifiers, and `Rpc.Client.registry` reads it back. Generated
  registries' doc comments name the new place; regenerating changes
  only those comments.
- `Rpc.Protocol.Json` and `Rpc.Protocol.Proto` are gone: the codec tags
  are `Rpc.Json` and `Rpc.Proto`, which are `Proto.Codec.Json` and
  `Proto.Codec.Proto`, as generated code writes them.
- New `Proto.Message.decodeJson : Registry -> Message a -> Value ->
  Result Proto.Error.Error a` reads a message's proto3 JSON, an `Any`
  of a type the registry lacks failing as `UnregisteredType` with its
  URL and anything else as `BadJson`; and `Proto.Message.decodeBinary :
  Message a -> Bytes -> Result Proto.Error.Binary a` reads its protobuf
  binary, giving the binary report as `Proto.Binary.decode` does.
- `Rpc.Code`'s conversions read one table of the sixteen codes: 14 to
  49 B smaller gzipped on a minimal client, about 140 to 190 B on a
  program that names codes, as the notes example does.
