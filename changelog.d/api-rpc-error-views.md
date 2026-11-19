- Breaking: `Rpc.Error.Error` is an opaque type, read in three layers.
  The RPC: `code`, `message`, `details` and `source` (`Nothing` when no
  status was stated). The HTTP exchange underneath: `cause`, a total
  `Cause = BadCall | NetworkError | Timeout | BadStatus Response |
  BadResponse Response`, elm/http's error with the answer kept, and
  `httpStatus`. The codec under that: `protoError`, the
  `Proto.Error.Error` of a body that did not decode or of a request
  `Any` that could not be written. `RpcStatus`, `HttpStatus`,
  `NoAnswer`, `Reason`, `Problem` and `StatusError` are gone;
  docs/migrating.md maps each to the new readers. Code that read only
  `code`, `message` and `toString` is unchanged.
- New builders, which the runtime uses too, so an error built in a test
  is `==` to the runtime's when it states the same things:
  `fromStatus`, `fromCode` (a stated status in a stand-in answer: the
  code's HTTP status, no headers, no body), `fromResponse`, `timeout`,
  `networkError`, `badCall`, `badAny`, `badResponse`, `badBody`,
  and `withMessage`. They serve application code too: a layer that
  refuses to send a call, such as one that will not send without a
  session, builds `badCall` with the code it means, which is never
  retried.
- A `BadResponse` is always a success (2xx). A 200 over Connect or
  gRPC-Web that is not the protocol's answer and states no status,
  such as a proxy's HTML page, is a `BadResponse` whose code stays
  `unknown`, and is no longer retried. Every builder that takes an
  answer gives the error the runtime would give for it.
- Messages hold no value from the request or the answer: a body that
  did not decode is `bad response body`, where it was elm/json's or the
  binary report's text cut to 300 characters; a request `Any` that
  could not be written is `bad Any`; a bad URL prints no URL (`bad URL:
  the base URL holds a query or a fragment`, or `… the browser could not
  read it`). `Rpc.Error.protoError` holds the problem itself.
- A `BadCall` or a `BadResponse` is never retried, whatever a policy's
  codes: a request over its write limit, or an answer over its read
  limit, both `ResourceExhausted`, were retried by a policy listing that
  code. An answer over the read limit is a `BadResponse` that keeps its
  status and headers, its body dropped.
- Changed: a failure text of the `Proto` JSON decoders says what was
  expected and no longer what was found: `Expecting an integer`, where
  it was `Expecting an integer, but got "x"`; `Expecting distinct map
  keys`, where it named both keys; and so on for enum names, map keys,
  numbers, base64, timestamps, durations, field masks and an `Any`'s
  `"@type"`. The rejected value is still in elm/json's failure, and
  `Proto.Error.toString` still prints it. A JSON `Any` whose message
  does not decode fails where its message does, with that failure's own
  path and text, where it was one text quoting the inner failure whole.
  Code matching these texts changes.
