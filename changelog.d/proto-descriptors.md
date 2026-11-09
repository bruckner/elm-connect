- Breaking: descriptors by full name moved out of `Proto.Registry` into
  the new `Proto.Descriptors`, type `Descriptors`: `empty`,
  `fromDescriptors`, `union`, `wellKnown`, `message`, `enum`, `messages`
  and `enums`, under the same names. Each generated package module's
  `registry` is now `descriptors : Proto.Descriptors.Descriptors`, and
  `Proto.Any.describe` takes a `Descriptors`. Rename
  `Proto.Registry.message "…" Notes.V1.registry` to
  `Proto.Descriptors.message "…" Notes.V1.descriptors`, and regenerate.
- `Proto.Registry` holds the codecs an `Any` is written as protobuf
  binary with, and nothing else: `Registry`, `empty`, `union`,
  `withBinary` and `toBinary`. The generated `binaryRegistry` is
  unchanged in this release; the next one renames and widens it.
