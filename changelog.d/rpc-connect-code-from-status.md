- A Connect error body without a code the protocol names takes the
  code of the HTTP status, as the protocol says and connect-go and
  connect-es do: a body with a string `message` and a missing or `null`
  `code` states a status, source `ConnectBody`, with the server's
  message, where it stated none and took the status text, and an
  unknown code name, `"ok"` included, reads as the status's code, not
  `Unknown`. `{}` and JSON without a string `message` still state none.
  The Connect conformance suite's proto run now passes 56 of 56 cases
  through the pure halves.
