- `google.protobuf.Value`, `Struct` and `ListValue` are held as a union,
  `Proto.Value.Value` (`ValueNull`, `ValueBool`, `ValueNumber`,
  `ValueString`, `ValueStruct`, `ValueList`), where they were elm/json's
  `Json.Encode.Value`: a `Value` field is `Maybe Proto.Value.Value`, a
  `Struct` field `Maybe (Dict String Proto.Value.Value)` and a
  `ListValue` field `Maybe (List Proto.Value.Value)`. `==` on them, and on
  any message holding them, now compares content; elm/json's walked only
  the left value's keys, so `{"a":1}` equalled `{"a":1,"b":2}`.
  `Proto.Value.toJson` and `fromJson` convert for ports and an
  application's own decoders. Code that built members with `Json.Encode`
  or read them with `Json.Decode` changes (docs/migrating.md, "Value,
  Struct and ListValue"). `Proto.Json.jsonValue` and `encodeValue` are the
  `Value` codecs; `Proto.WellKnown.value`, `struct` and `listValue`,
  `Proto.Json.struct`, `listValue` and their encoders, and
  `Proto.Binary.struct`, `listValue` and `value` are retyped.
- One depth budget of 100 covers every read: messages entered along a
  cycle, each `google.protobuf.Any` read from JSON through the registry,
  and each array and object of a `Value`, `Struct` or `ListValue`, the
  same unit in JSON and binary. A `Struct` or `Value` read from JSON used
  to be unbounded, and an `Any` nested in an `Any` overflowed the stack
  between 300 and 1,000 levels; deep input of every kind now fails with
  "Expecting messages nested at most 100 deep" or `TooDeep`. A binary
  `Struct` or `ListValue` counts one level where it counted two with its
  `Value`, so 100 levels read alike in both codecs. Converting an `Any`
  read from binary to JSON counts the `Any`s and the messages around
  them as a read does, and one past the limit fails with `TooDeep`,
  named `google.protobuf.Any`, where it overflowed the stack.
- An error the runtime returns no longer holds JSON nested more than 50
  levels deep: a `BadJson` from `Proto.Message.decodeJson`, an answer's
  body or error details, or an `Any`'s conversion holds a short marker in
  its place, so printing it with `Json.Decode.errorToString` or
  `Proto.Error.toString` no longer throws on deep input.
- A message on a cycle that holds a `Struct`, `Value`, `ListValue` or
  `Any` reads it through new depth-taking helpers, which generated code
  calls: `Proto.Json.structAt`, `listValueAt`, `jsonValueAt`,
  `messageValueFieldAt`, `messageValueFieldEitherAt`, `anyWithAt` and
  `registryDepth`, and `Proto.Binary.structAt`, `listAt` and `valueAt`;
  one that holds an `Any` writes a field on its cycle with
  `Proto.Json.registryDeeper`. Other messages generate what they did.
