- `Proto.Json.field` and `fieldEither`, the field steps that each
  checked for themselves that the JSON is an object, are removed; no
  generated code called them. Wrap a hand-written pipeline in
  `Proto.Json.Decode.message`, which makes the check once, and read each field
  with `Proto.Json.Decode.field` or `fieldEither`, which take the same
  arguments and do not check the object again.
- `Proto.Json.valueField` and `valueFieldEither` are removed. Inside
  `Proto.Json.Decode.message`, read a `google.protobuf.Value` field with
  `Proto.Json.Decode.nullField name (Proto.Json.Decode.nestedValue 0)` or
  `nullFieldEither jsonName protoName (Proto.Json.Decode.nestedValue 0)`,
  which read it as they did: a missing key is `Nothing`, `null` is
  `Just ValueNull`.
- `Proto.Json.valueMember` and `valueMemberEither` are removed. Write
  `Proto.Json.Decode.nullMember name (Json.Decode.map constructor
  (Proto.Json.Decode.nestedValue 0))` or `nullMemberEither jsonName protoName`
  with the same decoder, which read
  the member as they did, `null` included.
- `Proto.Json.encodeBoolMap` is no longer exposed. A field's encoder
  writes a map with `bool` keys with `Proto.Json.Encode.boolMap`, which
  gives `Nothing` for an empty map and otherwise `Just` the object
  `encodeBoolMap` wrote.
