- Every HTTP binding the generator accepts is now a route function. A
  method with a binding it could not type, such as a `bytes` field held
  as `Bytes` (`bytes=bytes`) in a path or query, a path through a
  recursive message, a body field of `google.protobuf.Empty` or `Value`,
  or a body holding a `google.protobuf.Any`, took its bindings as data
  (`withBindings (Proto.Method.bindings descriptorX)`) and was read by
  the runtime's interpreter; no generated method does now, so no
  generated program carries the interpreter: the notes example's bundle
  is 1.3 KB (3.3 %) smaller gzipped, and such requests are built 11 to
  17 % faster.
- A method whose bodies hold an `Any`, which only the client's registry
  can write, takes route functions of the request and its proto3 JSON
  (`routeCreateNote0 : CreateNoteRequest -> Json.Encode.Value ->
  Proto.Route.Route`), given to the new `Proto.Method.withJsonRoutes`:
  the path and query come from the typed request, the body from the
  JSON the send encodes once.
- A `bytes` field held as `Bytes` is written into a path or a query as
  base64 in the URL-safe alphabet, padded (`-_8=`), where the
  interpreter wrote standard base64 (`+/8=`): grpc-gateway's default mux
  answers 404 to the `%2F` a standard `/` becomes in a single-segment
  path, and Vanguard, grpc-gateway and Envoy all read the URL-safe
  alphabet in a path and a query. A server that reads only standard
  base64 in a query would now refuse such a value. A `bytes` field held
  as a `String` is sent as it holds it, as before.
- A `google.protobuf.Value` body field set to JSON `null` is sent as
  `null`; the interpreter sent `{}`, which a server reads as an empty
  struct. An unset one is still `{}`.
- New `Proto.Route.bytesText` and `Proto.Route.jsonField`, and
  `Proto.Query.bytes`, the helpers these route functions call.
- A binding the generator accepts but cannot write as a route function
  is reported as `internal::untyped_route`, a new code for a bug in
  elm-connect, rather than generated as data.
