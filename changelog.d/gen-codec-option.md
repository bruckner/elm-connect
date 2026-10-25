- `Proto.Message.withBinary`, `Proto.Method.withBinary`,
  `Proto.Message.messageBinary` and `Proto.Method.methodBinary` attach
  the binary codecs to a typed value or a method, and
  `Proto.Message.encodeBytes`/`bytesDecoder`,
  `Proto.Method.encodeRequestBytes`/`responseBytesDecoder` and
  `Proto.Method.hasJson` read them back.
- `Proto.Duration.fromParts` keeps the nanoseconds of a duration at
  protobuf's limit of ±315,576,000,000 seconds, as `fromString` does,
  rather than dropping them.
