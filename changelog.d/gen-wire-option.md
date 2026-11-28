- The generator option `codec=both|json|binary` (CLI `--codec`), default
  `both`, says which codec each method's calls are typed at, the `codec`
  of `Rpc.Call codec req res`. Under `both` a method carries its JSON
  and protobuf binary codecs and its calls are free in the codec, so any
  client sends them; `json` gives proto3 JSON alone (`Rpc.Call Rpc.Json`,
  as 0.1's calls were) and `binary` protobuf binary alone
  (`Rpc.Call Rpc.Binary`), for an
  application that speaks one codec: narrower call types, and the other
  codec's code behind the calls left out of its bundle. Every message
  gets protobuf binary codecs beside its JSON ones whatever the option
  says: per message `encodeNoteBinary`, `decodeNoteBinary` and
  `mergeNoteBinary`, per enum its number conversions, per oneof and
  recursion wrapper an encoder (and a merge), all written against
  `Proto.Binary`.
- `naming::codec_collision`: whatever the `codec` option, a type named
  for another with `Binary` at the end (`NoteBinary` beside `Note`) has JSON codecs that take the other's binary codecs'
  names. It points at both types; `rename` one of them.
- `Proto.Duration.fromParts` keeps the nanoseconds of a duration at
  protobuf's limit of ±315,576,000,000 seconds, as `fromString` does,
  rather than dropping them.
