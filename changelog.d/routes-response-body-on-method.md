- A binding's `response_body` field is held by the method, not the
  route: `Proto.Route.Route` loses `responseBody`, and the new
  `Proto.Method.withResponseBody n "field"` names the field binding `n`'s
  answer is read from. Generated code writes it after `withRoutes` for
  each binding that has one, so only a method written by hand with a
  response field needs the new call, and a route record written by hand
  drops the field. Reading a transcoded answer
  no longer builds the request's route, so it takes 12 to 25 % less
  time. A request of a method whose bodies hold an `Any` is built up to
  20 % faster, since building it no longer builds a second route, over
  `null`, to find the response field.
