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
- A message on a cycle generates `mergeFooBytesAt`, `mergeFooBytesLevels`
  and `mergeFooBytesLevel` beside `mergeFooBytes`, and `levelsFoo` and
  `levelFoo` (`levelFooWith` for one that holds an `Any`) beside
  `decodeFoo`; a oneof with a member on the cycle, `levelFooKind`. Other
  messages generate what they did. `Proto.Binary` gains `recursive`,
  `Levels`, `levels` and `level`, and `Proto.Json` gains `Levels`,
  `levels`, `atLevel`, `deeper` and `deeperWith`, which generated code
  calls.
