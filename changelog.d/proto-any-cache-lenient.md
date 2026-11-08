- An `Any` read from proto3 JSON, or packed, keeps its message's JSON
  beside its binary, and writing it as JSON again writes that JSON as it
  arrived (defaults, proto names and unknown fields included), with no
  conversion and no registry. The read is as strict as before, `unpack`
  reads the binary, and an `Any` read from binary converts through the
  registry as before. A Connect error detail keeps its `debug` JSON the
  same way, where `proto-any`'s notes say it is not read.
- `==` on `Any` sees the JSON it keeps: an `Any` read from binary and
  the same one read from JSON are not `==`, where `proto-any`'s notes
  say `==` compares content. The new `Proto.Any.equal` compares the type
  URL and the binary alone.
- `Proto.Registry.lenient : Registry -> Registry` makes a registry read
  a proto3 JSON `Any` of a type it lacks as that `Any`'s JSON alone
  instead of failing; every registry is strict until made lenient, and
  `union` and `unionAll` are lenient when any side is. Such an `Any` is
  written back as JSON as it arrived, unpacks with its message's JSON
  decoder, and is written as protobuf binary as its type URL alone, its
  message lost. Under a lenient client registry a `google.rpc.Status`
  body's detail of a type it lacks is read (`Ok`) instead of
  `UnregisteredType`, and unpacks with its typed value.
- `Proto.Any.bytes` is `Any -> Maybe Bytes`, `Nothing` for an `Any` held
  as JSON alone. `bytes : Any -> Bytes` was never released, so no
  release breaks; adding the state after one would have been a breaking
  change.
