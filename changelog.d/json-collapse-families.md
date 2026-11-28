- `Proto.Json.emptyMember` and `emptyMemberEither` are removed. A oneof
  member of `google.protobuf.Empty` is a `Proto.Json.member` (or
  `memberEither`) of `Json.Decode.map (\() -> Ctor) Proto.Json.empty`,
  which generated code now writes and which reads it as before: set
  when its key holds an object, unset when it holds `null`.
