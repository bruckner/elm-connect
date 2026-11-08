- Breaking: a `google.protobuf.Any` holds a type URL and its message's
  protobuf binary, whatever codec the calls use, as in Go, Java and
  protobuf-es; its proto3 JSON is converted through a registry. One
  type, `Proto.Any.Any`: `pack`, `packWith`, `is`, `typeUrl`,
  `typeName`, `bytes`, `unpack : Message a -> Any -> Maybe a`,
  `tryUnpack : Message a -> Any -> Result Problem a`, `toJson :
  Registry -> Any -> Result Problem Value` (the payload's proto3 JSON)
  and `describe`. `Problem` is `TypeMismatch`, `InvalidProto`,
  `UnregisteredType` (with the type URL) and `UnwritableAny` (an `Any`
  inside the message cannot be written), each documented with what to do
  about it. `==` on `Any` compares content.
- Breaking: `Proto.Json.anyWith : Registry -> Decoder Any` and
  `encodeAnyWith : Registry -> Any -> Result Problem Value` replace
  `any` and `encodeAny`. Both are strict, as protojson is: an `"@type"`
  the registry lacks fails the read, naming the URL, and an unregistered
  type fails the write; there is no `{"type", "value"}` fallback.
  `Proto.Binary.any` needs no registry; `Proto.Binary.anyWith` is
  removed.
- Breaking: `Proto.Message.Message a` holds a message's full name and
  both its codecs: `Proto.Message.init name encodeJson decodeJson
  encodeBytes decodeBytes`, and `initWith` for a message whose JSON
  codecs take a registry. `message`, `withBinary`, `messageBinary` and
  the readers `encode`, `decoder`, `default`, `toDescriptor`,
  `encodeBytes` and `bytesDecoder` are removed; `typeName` reads a typed
  value. A descriptor's full name is `Proto.Message.fullName` and
  `Proto.Enum.fullName`, which were `typeName`. `Proto.WellKnown`'s
  values hold both codecs.
- Breaking: `Proto.Registry` is `Registry`, `empty`, `register : Message
  a -> Registry -> Registry`, `union`, `unionAll` and `wellKnown`
  (`withBinary` and `toBinary` are removed). Each generated package's
  `registry`, which replaces `binaryRegistry`, holds the package's own
  messages and nothing else (no imports, no well-known types, no error
  details); an application composes `Proto.Registry.unionAll [
  Notes.V1.registry, Proto.Registry.wellKnown,
  Proto.ErrorDetails.registry ]`.
- Breaking: `codec=json|proto|both` now says only which codecs the
  service methods are wired with. Every package gets both codecs, its
  typed values and `registry` whatever the option says, and
  `naming::codec_collision` applies under every option. A message that
  reaches an `Any` has `encodeNoteWith` and `decodeNoteWith`, taking the
  registry, in place of `encodeNote` and `decodeNote`; a type named for
  one with `With` at the end is `naming::codec_collision`.
- Breaking: methods are built by `Proto.Method.initJson`, `initProto`
  and `init`, in place of `json`, `proto` and `both`, and a method's JSON
  codecs take the registry at use time (`Proto.Method.initJson
  "notes.v1.NotesService" "GetNote" (\_ -> Ok << encodeGetNoteRequest)
  (\_ -> decodeNote)`). A method holds no registry: the client's is the
  one table. `Proto.Method.encodeRequest` and `responseDecoder` take a
  registry, the former giving a `Result`; `Rpc.Call.requestJson` and
  `Rpc.Call.toJson` take a registry and give a `Result`, never `null` for
  a request they cannot write.
- `Rpc.withRegistry` sets the registry a client's calls convert an `Any`
  through, `Proto.Registry.empty` until set. Over JSON a request holding
  an `Any` it cannot write is not sent: `NoAnswer (UnwritableRequest
  problem)`, a new `Rpc.Error.Reason`, code `Internal`.
- Breaking: `StatusError.details` is `List (Result DetailProblem Any)`,
  in wire order, with the new `Rpc.Error.DetailProblem =
  UnregisteredType String | InvalidDetail (Maybe String) String`. A
  Connect body's details and gRPC-Web's `grpc-status-details-bin` are
  read from their binary with no registry (`debug` is not read); a
  `google.rpc.Status` body's, from transcoding, through the client's
  registry, so one of a type it lacks is `UnregisteredType` with its URL
  where it was dropped. A detail problem never fails the status read.
  `Rpc.Error.details` is removed; use `Proto.Any.unpack`.
  `Rpc.Trace.toJson` lists a status's detail problems under
  `detailProblems`, and `toString` counts them.
- `Proto.ErrorDetails`: Elm records and typed values of
  `google/rpc/error_details.proto`'s messages (`ErrorInfo`, `RetryInfo`,
  `DebugInfo`, `QuotaFailure`, `PreconditionFailure`, `BadRequest`,
  `RequestInfo`, `ResourceInfo`, `Help`, `LocalizedMessage`, and their
  nested messages as `QuotaFailureViolation`, `BadRequestFieldViolation`
  and the like), and `registry` holding all of them.
- Fixed: a send encodes its JSON request at most once: for its body, a
  route read from bindings as data, the check that its `Any`s can be
  written and the write limit alike. Reading an answer with
  `Rpc.response` over a route read from bindings encodes nothing.
