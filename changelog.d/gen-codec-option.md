- The generator option `codec=json|proto|both` (CLI `--codec`), default
  `json`, whose output is unchanged. `both` adds protobuf binary codecs
  beside the JSON ones: per message `encodeNoteBytes`, `decodeNoteBytes`
  and `mergeNoteBytes`, per enum its number conversions, per oneof and
  recursion wrapper an encoder (and a merge), all written against
  `Proto.Binary`. `proto` generates the binary codecs alone: messages
  and oneofs get no JSON codecs, enums keep theirs.
- `Proto.Message.withBinary` and `Proto.Message.messageBinary` attach
  the binary codecs to a typed value, and `Proto.Message.encodeBytes`
  and `bytesDecoder` read them back. `Proto.Method.proto` builds a
  method with binary codecs alone and `Proto.Method.both` one with both,
  and `Proto.Method.hasJson` says whether a method has JSON codecs.
- `naming::codec_collision`: under `codec=both`, or `codec=proto` for an
  enum, a type named for another with `Bytes` at the end (`NoteBytes`
  beside `Note`) has JSON codecs that take the other's binary codecs'
  names. It points at both types; `rename` one of them.
- `Proto.Duration.fromParts` keeps the nanoseconds of a duration at
  protobuf's limit of ±315,576,000,000 seconds, as `fromString` does,
  rather than dropping them.
