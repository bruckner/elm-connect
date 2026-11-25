- A JSON read counts an `Any` reached through a message off a cycle
  against the one nesting budget. A recursive message that holds an
  `Any` only through another message (or through a oneof with no member
  on its cycle) passed that message the registry without its depth, so
  each such `Any` added one level and a hostile document could nest
  about 5,000 levels in one read; past a few hundred (node, Chromium,
  Firefox) to a few thousand (WebKit) the JavaScript stack overflowed,
  and `Json.Decode.decodeValue`,
  `Proto.Message.decodeJson` and a call with a `response_body` threw.
  Generated code now counts such an `Any` on from the message's depth,
  in its decoder and its encoder, so a read refuses past 100 levels and
  a JSON write refuses the same `Any` at the same place; regenerate.
