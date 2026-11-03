- Breaking: descriptors by full name moved out of `Proto.Registry` into
  the new `Proto.Descriptors`, type `Descriptors`: `empty`,
  `fromDescriptors`, `union`, `wellKnown`, `message`, `enum`, `messages`
  and `enums`, under the same names. Each generated package module's
  `registry` is now `descriptors : Proto.Descriptors.Descriptors`, and
  `Proto.Any.describe` takes a `Descriptors`. Rename
  `Proto.Registry.message "…" Notes.V1.registry` to
  `Proto.Descriptors.message "…" Notes.V1.descriptors`, and regenerate.
- `Proto.Registry` holds codecs alone, the table an `Any` resolves
  through; its new shape is in the typed `Any` notes.
