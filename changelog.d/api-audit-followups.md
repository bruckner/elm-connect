- `Proto.Error.Reason` has a constructor, `MissingRequired Int`,
  reserved for a proto2 `required` field absent from binary; no
  decoder gives it while the generator reads proto3 alone, but a
  `case` on a `Reason` must cover it. `Proto.Error.Error`, `Reason`
  and the `Binary` record are frozen within a major.
- `Proto.Any.toJson`, and so `Proto.Json.encodeAnyWith` and every
  request holding an `Any`, writes an `Any` held as JSON alone through
  the registry given, as it does one holding binary: a registry with an
  entry for its type reads the JSON as that message first and writes it
  as held, failing with `BadJson` when it is not that message; a strict
  registry without one fails with `UnregisteredType`. Before, every
  registry wrote it unread. A lenient registry without an entry still
  writes it as it arrived.
