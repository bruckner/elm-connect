- Reads count every message that nests against the one budget of 100
  levels, from the outermost. A message nests when, through its fields
  at any depth, it reaches a message on a cycle of references, a
  `Value`, `Struct` or `ListValue`, or an `Any`. A recursive message read
  a message of another cycle from 1 again, and a message on no cycle
  passed no depth on, so each recursive type chained in a schema, and
  each `Value`, `Struct` or `ListValue` below a message on no cycle, had
  100 levels of its own: three chained types read about 300 levels, past
  which node overflowed its stack and `Json.Decode.decodeValue` threw.
  Now a read of 100 levels succeeds and one of 101 fails, in JSON and
  binary, counting a message on no cycle above a cycle, a `Struct` or an
  `Any` too, so an `Any` held through such messages is refused one level
  earlier for each of them, by a read and a JSON write alike, and an
  answer read through a `response_body` counts from 2, its response
  being level 1. Whether a
  message nests depends only on what it reaches, so a package generates
  the same code whatever else is generated with it.
- A message that nests gets codecs at a depth (`decodeNestedNote`,
  `decodeNestedNoteWith`, `mergeNestedNoteBinary`, and `decodeNestedNoteKind`
  for a oneof of it with a member that counts), its plain codecs being
  them at depth 1. This is new for a schema without recursion: a message
  holding a `Struct`, `Value`, `ListValue` or `Any`, and every message
  holding it, now takes the depth (the notes example: 215 bytes
  gzipped, reads within 1 %). A message that does not
  nest generates what it did. A `Value` held in a oneof of a message that
  nests counts on from the message.
- The `types::deep_nesting` warning says whether reads count the chain's
  messages: they refuse a chain of messages that nest past 100 levels,
  and read a chain of messages that do not to its end.
- New in the runtime, called by generated code: `Proto.Json.deeper`,
  `Proto.Json.nestedValueMember` and `Proto.Json.nestedValueMemberEither`;
  regenerate.
