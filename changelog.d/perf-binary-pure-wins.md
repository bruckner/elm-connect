- Writing protobuf binary is faster for messages that hold other
  messages: by about half for a wide message, a third for a deeply
  nested one, and 6 % for building a binary request in the package's
  benchmark; reading them is 8 to 9 % faster. The bytes written are
  the same.
- `Proto.Any.pack` of a message that cannot hold an `Any` (one built by
  `Proto.Message.init`, as generated code builds every such message) no
  longer encodes the message as JSON first; it writes the binary
  straight away, with the same result.
