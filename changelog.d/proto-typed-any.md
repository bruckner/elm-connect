- Breaking: `Proto.Message.Message codec a` carries the codec, as
  methods and calls do, and holds a type's full name and the codecs of
  one world. `codec=json` generates `messageNote : Message Rpc.Json
  Note`, `codec=proto` and `codec=both` a `Message Rpc.Proto Note` of
  binary codecs. Its builders are `initJson` and `initProto`
  (`message`, `messageBinary` and `withBinary` are gone), and its one
  reader is `typeName`: `encode`, `decoder`, `default`, `toDescriptor`,
  `encodeBytes` and `bytesDecoder` are gone, the generated codecs,
  default and descriptor taking their place. A descriptor's full name is
  `Proto.Message.fullName`, which was `typeName`. `Proto.WellKnown`
  gives each well-known type once per world, the binary one with
  `Proto` at the end (`timestampProto`).
- Breaking: `Proto.Any.Any codec` holds the packed message in one form:
  `Any Rpc.Json` its proto3 JSON (code generated with `codec=json`),
  `Any Rpc.Proto` its protobuf binary (`codec=proto` and `codec=both`).
  `pack` and `packWith` take a `Message Rpc.Proto a`, `packJson` and
  `packJsonWith` a `Message Rpc.Json a`; `unpack` and `unpackJson` give a
  `Maybe a`, `tryUnpack` and `tryUnpackJson` a `Result Problem a`.
  `Problem` is `TypeMismatch name`, `InvalidProto`, `InvalidJson error`
  and `UnregisteredType name`; `BinaryOnly` is a compile error now. New:
  `bytes`, `json`, and `toJson` and `toProto`, which convert through a
  registry. An `Any` compares with `==` by its content.
- Breaking: under `codec=both` an `Any`'s proto3 JSON is converted
  through a registry, and a type it lacks fails rather than being
  written in a form no proto3 reader takes. `binaryRegistry` is
  `registry`, holding the package's messages' codecs, its imports' and
  the well-known types', and `Proto.Registry` has `withCodecs`,
  `unionAll`, `wellKnown`, `toJson` and `toBytes` (`withBinary` and
  `toBinary` are gone). A message, oneof or wrapper that holds an `Any`
  has JSON codecs taking the registry, `decodeNoteWith` beside
  `decodeNote` and `encodeNoteWith : Registry -> Note -> Result
  Proto.Any.Problem Value` in place of `encodeNote`. `Proto.Json.any` and
  `encodeAny` read and write an `Any Rpc.Json`; `Proto.Json.anyWith` and
  `encodeAnyWith` an `Any Rpc.Proto` through a registry;
  `Proto.Binary.anyWith` is gone. A type named for such a message with
  `With` at the end is `naming::codec_collision`.
- Breaking: `Proto.Method.json`, `proto` and `both` are `initJson`,
  `initProto` and `init`; `init` takes the registry its calls use and
  JSON codecs taking a registry.
- New: `Rpc.withRegistry` gives a client the registry its calls convert
  an `Any` through, in place of each method's package's. A request
  holding an `Any` the registry cannot write as JSON is not sent:
  `Rpc.Error.Reason` has a new constructor, `UnregisteredType name`
  (code `Internal`).
- Breaking: `Rpc.Error.StatusError.details` is a `List Rpc.Error.Detail`,
  `{ proto : Maybe (Any Rpc.Proto), json : Maybe (Any Rpc.Json) }`, the
  forms each detail arrived in. `Rpc.Error.details` takes a
  `Message Rpc.Proto a` and reads the binary; the new
  `Rpc.Error.detailsJson` takes a `Message Rpc.Json a` and reads the
  JSON, which is what code generated with `codec=json` uses. Under
  `codec=both` the registry fills in the missing form of each detail of
  a type it has.
- New: `Proto.Json.tryObjectOfFields`, `tryOptionalField`,
  `tryRepeatedField`, `tryDictField` and `tryBoolMapField`, the field
  encoders of a message whose encoder gives a `Result`.
