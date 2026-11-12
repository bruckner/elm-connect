- The generator option `wire=both|json|proto` (CLI `--wire`), default
  `both`, says what each method's calls are wired with. Under `both` a
  method carries its JSON and protobuf binary codecs and its calls are
  free in the codec, `Rpc.Call codec req res`, so any client sends them;
  `json` wires proto3 JSON alone (`Rpc.Call Rpc.Json`, as 0.1's calls
  were) and `proto` protobuf binary alone (`Rpc.Call Rpc.Proto`), for an
  application that speaks one codec: narrower call types, and the other
  codec's code behind the calls left out of its bundle. Every message
  gets protobuf binary codecs beside its JSON ones whatever the option
  says: per message `encodeNoteBytes`, `decodeNoteBytes` and
  `mergeNoteBytes`, per enum its number conversions, per oneof and
  recursion wrapper an encoder (and a merge), all written against
  `Proto.Binary`.
- `Proto.Message.withBinary` and `Proto.Message.messageBinary` attach
  the binary codecs to a typed value, and `Proto.Message.encodeBytes`
  and `bytesDecoder` read them back. `Proto.Method.proto` builds a
  method with binary codecs alone and `Proto.Method.both` one with both.
- `naming::codec_collision`: whatever the `wire` option, a type named for another with `Bytes` at the end (`NoteBytes`
  beside `Note`) has JSON codecs that take the other's binary codecs'
  names. It points at both types; `rename` one of them.
- `Proto.Duration.fromParts` keeps the nanoseconds of a duration at
  protobuf's limit of ±315,576,000,000 seconds, as `fromString` does,
  rather than dropping them.
