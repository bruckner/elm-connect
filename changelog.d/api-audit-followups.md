- `Proto.Error.Reason` has two reserved constructors: `MissingRequired
  Int`, for a proto2 `required` field absent from binary, which no
  decoder gives while the generator reads proto3 alone, and `TooDeep`,
  for a message nested past a depth limit, which no decoder gives
  while the decoders have no limit (protobuf implementations stop at
  100 levels). A `case` on a `Reason` must cover both. `Proto.Error.Error`, `Reason`
  and the `Binary` record are frozen within a major.
- `Proto.Any.toJson`, and so `Proto.Json.encodeAnyWith` and every
  request holding an `Any`, writes an `Any` held as JSON alone through
  the registry given, as it does one holding binary: a registry with an
  entry for its type reads the JSON as that message first and writes it
  as held, failing with `BadJson` when it is not that message; a strict
  registry without one fails with `UnregisteredType`. Before, every
  registry wrote it unread. A lenient registry without an entry still
  writes it as it arrived.
- The generator refuses a `google.api.http` rule that is a `get`, or a
  `custom` one of kind `GET` or `HEAD`, with a `body`, as
  `route::get_body`: a browser sends those methods without a body, so
  the fields mapped to it never reached the server, and the call went
  out regardless. A `delete` with a body is still accepted.
