- The generator option `codec=json|binary|both` (CLI `--codec`), default
  `json`, whose output is unchanged. `both` adds protobuf binary codecs
  beside the JSON ones: per message `encodeNoteBytes`, `decodeNoteBytes`
  and `mergeNoteBytes`, per enum its number conversions, per oneof and
  recursion wrapper an encoder (and a merge), all written against
  `Proto.Binary`. `binary` generates the binary codecs alone: messages
  and oneofs get no JSON codecs, enums keep theirs. No transport sends
  binary yet.
- `Proto.Message.withBinary`, `Proto.Method.withBinary`,
  `Proto.Message.messageBinary` and `Proto.Method.methodBinary` attach
  the binary codecs to a typed value or a method, and
  `Proto.Message.encodeBytes`/`bytesDecoder`,
  `Proto.Method.encodeRequestBytes`/`responseBytesDecoder` and
  `Proto.Method.hasJson` read them back.
- `Proto.Duration.fromParts` keeps the nanoseconds of a duration at
  protobuf's limit of ±315,576,000,000 seconds, as `fromString` does,
  rather than dropping them.
