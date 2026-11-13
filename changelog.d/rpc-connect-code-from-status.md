- A Connect error body without a code the protocol names takes the
  code of the HTTP status, as the protocol says and connect-go and
  connect-es do: a body with a string `message` and a missing or `null`
  `code` is an `RpcStatus` with source `ConnectBody` and the server's
  message, where it was an `HttpStatus` error with the status text, and
  an unknown code name, `"ok"` included, reads as the status's code, not
  `Unknown`. `{}` and JSON without a string `message` stay `HttpStatus`.
  The Connect conformance suite's proto run now passes 56 of 56 cases
  through the pure halves.
