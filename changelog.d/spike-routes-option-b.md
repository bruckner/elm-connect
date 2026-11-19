- A route function takes the client's registry and gives a `Result`:
  `Proto.Method.withRoutes : List (Registry -> req -> Result
  Proto.Error.Error Route)`. A route that holds no
  `google.protobuf.Any` ignores the registry and is `Ok`; one whose
  body holds an `Any` writes it with the registry, and an `Any` it
  cannot write is the route's `Err`, which the call fails with unsent.
  `Proto.Method.withJsonRoutes` and `Proto.Route.jsonField` are gone.
  Regenerate: generated service modules change.
- `Proto.Route.Route` has no `responseBody` field: the field a
  binding's answer is read from is given to the method with
  `Proto.Method.withResponseBody n field`, which generated code writes
  for a binding whose rule names a `response_body`. Reading an answer
  (`Rpc.response`) builds no route and encodes nothing of the request.
- `Rpc.request`, and a trace, of a transcoded call whose `Any` the
  client's registry cannot write show the binding's verb, path and query,
  with that `Any` written as `{"@type": …}`; the call is still not sent.
  A method written with `Proto.Method.withBindings` keeps its path and
  query there too, where it showed an empty path.
