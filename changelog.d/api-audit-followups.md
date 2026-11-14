- `Proto.Error.Reason` has a constructor, `MissingRequired Int`,
  reserved for a proto2 `required` field absent from binary; no
  decoder gives it while the generator reads proto3 alone, but a
  `case` on a `Reason` must cover it. `Proto.Error.Error`, `Reason`
  and the `Binary` record are frozen within a major.
