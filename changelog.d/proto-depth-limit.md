- Reads are limited to 100 levels of nesting, as protobuf's own runtimes
  limit them: a message on a cycle of references (one that holds itself,
  directly, through a list, a map's values, a oneof member or other
  messages), and a binary `Struct`, `Value` or `ListValue`, a level being
  each message entered along the cycle. Past it a binary read fails with
  `Proto.Error.TooDeep`, now given, with the path to the field one level
  too deep and the offset of its length, where it used to overflow the
  stack at a few hundred levels and report `Unlocated`; a JSON read fails
  with "Expecting messages nested at most 100 deep", where
  `Json.Decode.decodeValue` and `Proto.Message.decodeJson` used to throw.
  Writing is not limited; the calling guide's "Nesting depth" says what
  can still overflow.
- A message on a cycle generates `mergeNestedFooBytes` beside
  `mergeFooBytes` and `decodeNestedFoo` beside `decodeFoo`
  (`decodeNestedFooWith` beside `decodeFooWith` for one that holds an
  `Any`), its decoders at a nesting depth; a oneof with a member on the
  cycle, `decodeNestedFooKind`, and a recursive message's wrapper,
  `mergeNestedFoo_Bytes`. Other messages generate what they did.
  `Proto.Binary` gains `recursive` and `memo`, and `Proto.Json` gains
  `memo` and `deeperWith`, which generated code calls.
