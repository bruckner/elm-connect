- `Proto.Json.field` and `fieldEither`, the field steps that each
  checked for themselves that the JSON is an object, are removed; no
  generated code called them. Wrap a hand-written pipeline in
  `Proto.Json.message`, which makes the check once, and read each field
  with `Proto.Json.messageField` (for `field`) or `messageFieldEither`
  (for `fieldEither`), which take the same arguments.
- `Proto.Json.valueField` and `valueFieldEither` are removed. Inside
  `Proto.Json.message`, read a `google.protobuf.Value` field with
  `Proto.Json.messageNullField name (Proto.Json.nestedValue 0)` or
  `messageNullFieldEither jsonName protoName (Proto.Json.nestedValue 0)`,
  which read it as they did: a missing key is `Nothing`, `null` is
  `Just ValueNull`.
- `Proto.Json.valueMember` and `valueMemberEither` are removed. Write
  `Proto.Json.nullMember name (Json.Decode.map constructor
  (Proto.Json.nestedValue 0))` or `nullMemberEither jsonName protoName`
  with the same decoder, which read
  the member as they did, `null` included.
- `Proto.Json.encodeBoolMap` is no longer exposed. A field's encoder
  writes a map with `bool` keys with `Proto.Json.boolMapField`, which
  gives `Nothing` for an empty map and otherwise `Just` the object
  `encodeBoolMap` wrote.
