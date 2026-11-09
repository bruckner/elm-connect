- `Proto.Registry.lenient : Registry -> Registry` makes a registry read
  a proto3 JSON `Any` of a type it lacks as that `Any`'s JSON alone
  instead of failing; every registry is strict until made lenient, and
  `union` and `unionAll` are lenient when any side is. Such an `Any` is
  written back as JSON as it arrived, unpacks with its message's JSON
  decoder, and is written as protobuf binary as its type URL alone, its
  message lost. `==` compares two such `Any`s by their JSON, and one
  never equals an `Any` holding binary. Under a lenient client registry
  a `google.rpc.Status` body's detail of a type it lacks is read (`Ok`)
  instead of `UnregisteredType`, and unpacks with its typed value.
- `Proto.Any.bytes` is `Any -> Maybe Bytes`, `Nothing` for an `Any` held
  as JSON alone. `bytes : Any -> Bytes` was never released, so no
  release breaks; adding the state after one would have been a breaking
  change.
