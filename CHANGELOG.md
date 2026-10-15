# Changelog

All notable changes to this project are recorded here. The Elm package
follows Elm's enforced semantic versioning; the crates follow Cargo's.

## Unreleased

- Toolchain, Cargo workspace, conformance harness seed and CI; no
  generation yet.
- `elm-connect-gen`: protobuf descriptors to a typed IR of messages,
  enums, oneofs, maps and well-known types, with the Elm naming rules and
  diagnostics for names Elm cannot take. Nothing is emitted yet.
- `elm-connect-gen`: a typed Elm AST for generated code and a printer
  whose output elm-format 0.8.8 accepts unchanged.
- Generation, end to end for messages of singular scalar fields: record
  type aliases with proto3 JSON encoders and decoders, from both
  `elm-connect gen` and `protoc-gen-elm-connect`. Other constructs are
  reported as `generate::unimplemented`. The runtime package
  `bruckner/elm-connect` starts with `Connect.Json`, and the conformance
  corpus with its first case, `scalars`.
- Generation of proto3 `optional` fields and singular message fields as
  `Maybe`, and repeated fields as `List`, with the `cardinality`
  conformance case. Decoders accept a field under its proto name as well
  as its JSON name (`Connect.Json.fieldEither`), and 32-bit integers as
  strings and in exponent notation (`Connect.Json.int32`);
  `Connect.Json.encodeMaybe` encodes `Nothing` as `null`.
- Generation of enums as custom types, encoded by name and decoded by name
  or number through `Connect.Json.enum`, an unknown value reading as the
  zero value, with the `enums` conformance case. Enum values keep their
  declaration order in the IR; a negative value no longer drops its enum.
- The printer keeps an application's leading arguments on its first line
  when only the last argument spans lines.
- Generation of oneofs as custom types with an unset constructor, held in
  one record field at the oneof's declared position, with the `oneofs`
  conformance case. The runtime gains `Connect.Json.oneof`, `member` and
  `memberEither`.
- Generation of map fields as `Dict String V` (string and 64-bit integer
  keys) or `Dict Int V` (32-bit integer keys), with `Connect.Json.intDict`
  and the `maps` conformance case. A `bool` map key is the
  `types::map_key` diagnostic (`map_bool_key` case), the corpus's first
  diagnostics case.
- Generation of the well-known types of design section 3.5, with the
  `well_known` conformance case and the `any_field` diagnostics case. The
  runtime gains `Connect.Timestamp` (RFC 3339 to and from `Time.Posix`),
  `Connect.Duration` (an exact, opaque duration with proto3 JSON's
  `"1.5s"` form), and `Connect.Json` codecs for timestamps, durations,
  field masks and `Empty`; it now depends on elm/time.
- Generation of recursive messages: a field that closes a cycle of record
  fields holds the target's wrapper type (`type Node_ = Node_ Node`),
  decoded lazily, as are oneof members that close a cycle, with the
  `nesting` conformance case. Every construct of the type layer is now
  generated; nothing reports `generate::unimplemented`.
- The `packages` conformance case (qualified references to another
  generated package and its import), and diagnostics cases for a generate
  set that is not closed (`packages_not_generated`) and a package cycle
  (`packages_cycle`). A case may now hold an `include/` directory of protos
  that are imported but not generated. Rendered diagnostics carry no
  trailing whitespace.
- The `naming` conformance case (reserved-word fields and oneofs, a
  `json_name` override, enum values with and without the conventional
  prefix and with digits) and the `naming_collision` diagnostics case.
- CI compiles the runtime package and the conformance corpus with Elm
  0.19.0 and 0.19.1 as well (`conformance/compile-with.sh`,
  `just compile-with`).
- The gate audits the GitHub Actions workflows with zizmor
  (`just zizmor`).
- The gate scans the commit history for secrets with gitleaks
  (`just gitleaks`).
- The `int64` option (`--elm-connect_opt=int64=int`, `elm-connect gen
  --int64 int`): 64-bit integers become `Int`, decoded only within
  ±(2^53 − 1) (`Connect.Json.int64AsInt`) and encoded as decimal strings
  (`Connect.Json.encodeInt64AsInt`). A field's `jstype` option overrides
  it either way. The runtime gains `Connect.Int64` (`toInt`, `fromInt`).
  The `int64_option` conformance case; a case may set options in
  `options.txt`.
- 32-bit integer decoders check the proto type's range:
  `Connect.Json.int32` fails outside −2^31 to 2^31 − 1, and the new
  `Connect.Json.uint32` (for `uint32` and `fixed32`) outside 0 to
  2^32 − 1.
- `Connect.Json.bytes` validates base64 (standard or URL-safe alphabet,
  padding optional) and fails on anything else; the string is still kept
  as received.
- `google.protobuf.Empty` carries nothing: a singular field of it is `()`
  rather than `Maybe ()` (`{}` on the wire always, `()` when absent or
  `null`), and a oneof member of it is a constructor without an argument,
  decoded by the new `Connect.Json.emptyMember` and `emptyMemberEither`
  (an object sets it; `null` is unset).
  Design §3.8 starts a list of dead ends.
- `google.protobuf.Struct` is `Dict String Json.Encode.Value` and
  `ListValue` is `List Json.Encode.Value`, with presence like any message
  field (`Maybe` when singular). The runtime gains `Connect.Json.struct`,
  `encodeStruct`, `listValue` and `encodeListValue`; the decoders fail on
  JSON of the wrong shape. `Value` stays `Json.Encode.Value`.
- Oneofs and two-name fields decode strictly, as protobuf-go's protojson
  does. A oneof's decoder is the new `Connect.Json.members`, given the
  oneof's name, its unset value and a `Connect.Json.Member` per member:
  a malformed member fails the message instead of reading as unset, and
  two members present fail, naming the keys. A member present as `null`
  is absent, except a `google.protobuf.Value` member, which holds `null`
  (the new `Connect.Json.valueMember` and `valueMemberEither`). An object
  holding a field or member under both its JSON name and its proto name
  fails (`fieldEither` and every two-name helper). `member`,
  `memberEither`, `emptyMember` and `emptyMemberEither` now build a
  `Member` rather than a `Decoder`.
- `map<bool, V>` fields are generated as `List ( Bool, V )`, encoded as
  an object keyed `"true"` and `"false"` and decoded by the new
  `Connect.Json.boolMap` (any other key fails), with
  `Connect.Json.encodeBoolMap`. The `types::map_key` diagnostic and the
  `map_bool_key` case are gone; the `maps` case covers a `bool` key.
- Every message gets a default value, `defaultFoo : Foo`, with each
  field at its proto3 default and each oneof unset, in a new
  `-- DEFAULTS` section between the types and the encoders.
- An unknown enum name fails the decode (`Expecting a value of enum
  "Priority", but got "WHATEVER"`), as protobuf-go does; an unknown
  number still reads as the zero value. `Connect.Json.enum` takes the
  enum's proto name first. Aliases (`allow_alias`) collapse into the
  constructor of the first value declared with their number, which the
  encoder writes; the decoder reads every alias name.
- `Connect.Json.int64` and `int64AsInt` accept a 64-bit integer string
  in exponent notation (`"1e3"`, `"1.5e3"`, `"-2e0"`), and `int64`
  always gives the canonical decimal string (`"1000"`, `"1500"`, `"-2"`;
  `"007"` reads as `"7"`), worked out as text so no digit is lost past
  2^53. A value that is not an integer, or has more than 20 digits,
  fails.
- Design: sub-millisecond timestamp precision is recorded as a dead
  end; nested messages stay flattened (`OuterInner`); the runtime
  package is kept; `google.protobuf.Any` is in scope, its design
  pending.
- The IR holds services and methods: each method's Elm value name, its
  request and response types (messages or supported well-known types),
  its idempotency, and its `google.api.http` rule as written. Streaming
  methods are the `services::streaming` diagnostic. Each service has an
  Elm module of its own (`Notes.V1.NotesService`), so a method value
  clashes only with another method of its service
  (`naming::value_collision`); a module name shared by two services, a
  service and a package, or two packages is `naming::module_collision`,
  and a service name with no module form is `naming::invalid_service`
  (`services_streaming`, `services_value_collision` and
  `services_module_collision` cases). Nothing is emitted for methods
  yet.
- `google/api/http.proto` and `google/api/annotations.proto` are
  embedded (Apache-2.0, `THIRD_PARTY.md`), so `elm-connect gen` compiles
  protos that import them without a googleapis checkout. The protoc
  plugin keeps extension options, which it used to drop.
- `google.api.http` rules are parsed and checked against their request
  and response messages (`elm-connect-gen::route`): the path template
  under http.proto's grammar, path variables, `body`, `response_body`,
  additional bindings, and the query parameters every other request
  field becomes, by dotted proto field path with the default each is
  left out at. Each problem is a `route::*` diagnostic pointing at the
  rule (`routes_invalid` case).
- The runtime sends calls: module `Rpc`, with `Rpc.Code`. A call
  (`Rpc.Call`, from `Rpc.call` and a `Rpc.MethodDescriptor`) is a
  method applied to its request, carrying its HTTP bindings as data
  (`Rpc.binding` and the segment, body and parameter constructors) and
  per-call headers, timeout, tracker and binding choice
  (`Rpc.viaBinding`, `Nothing` for a binding the method lacks). A
  descriptor's codecs are `encodeJson` and `jsonDecoder`. A config
  (`Rpc.Config`, `Rpc.config`) is plain data: the transport (`Connect`,
  with `useGet` off by default and `maxGetUrl`), base URL, headers,
  timeout, credentials and a retry policy. `Rpc.task`, `Rpc.send` and
  their traced forms send a call; `Rpc.request`, `Rpc.response` and
  `Rpc.taskFromRequest` are the pure halves. A trace carries the HTTP
  status and the code the call ended with. Errors are `Rpc.Rpc` (an
  error code, message, raw details and the source they were read from:
  a Connect error body or the HTTP status) or `Rpc.Transport`.
  `Rpc.Code` has `Code` (`Ok` or `Failed`) and `ErrorCode`, each with
  conversions to and from Connect's names, gRPC's numbers and HTTP
  statuses. The package now depends on elm/http.
- `Rpc` sends calls over HTTP transcoding too (`Rpc.Transcode`): path,
  query, body, custom verb and response body from the call's
  `google.api.http` binding, chosen with `Rpc.viaBinding`; success on
  any 2xx, an empty body reading as `{}`. A method without a rule goes
  over the implicit route `POST /<service>/<method>`, the request
  Connect would send. Failed answers under either transport are read
  from a Connect error body, a `google.rpc.Status` body, the
  `grpc-status` and `grpc-message` headers, or the HTTP status, in
  that order (`Rpc.StatusBody`, `Rpc.GrpcHeaders`).
- Calls are generated: each service gets a module of its own
  (`Notes.V1.NotesService`, file `Notes/V1/NotesService.elm`) with one
  function per method from its request to an `Rpc.Call`, built with
  `Rpc.call` from the method's descriptor and its `google.api.http`
  bindings as data (`Rpc.binding`), the rule's own first. A method
  without a rule has no bindings, and the runtime calls it over the
  implicit route. The package module holds types and codecs only. The
  `unbound_methods` option (`implicit`, the default, or `error`;
  `--unbound-methods` on the CLI) makes a method without a rule the
  `services::unbound_method` diagnostic instead. Conformance cases
  `services` and `services_unbound_error`. A rule whose request is a
  well-known type other than `Empty` can no longer leave fields to the
  query (`route::query_field`).
- Route fixtures (`conformance/routes/`): `routes.proto` and JSON
  fixtures of request to path, query and body, covering http.proto's
  examples, percent-encoding, query value forms and omission, bodies,
  and the implicit route of a method without a rule. A Rust reference
  implementation on prost-reflect checks the generated routes against
  them, and the runtime's tests replay them through `Rpc.request` with
  the Transcode transport and `Rpc.viaBinding` (`tests/Routes/` and
  `tests/RouteFixtures.elm`, generated and pinned; `just bless`
  rewrites them).
- The `services_invalid` diagnostics case: a method type outside the
  generate set, a method name with no Elm form, a service name with no
  module form, a rule without a path, and nested additional bindings,
  so every diagnostic of the method layer is pinned in the corpus.
- The runtime's data modules move under `Proto`: `Connect.Json`,
  `Connect.Timestamp`, `Connect.Duration` and `Connect.Int64` are now
  `Proto.Json`, `Proto.Timestamp`, `Proto.Duration` and `Proto.Int64`,
  contents unchanged, and generated code imports them so. `Rpc.Code`
  splits in two: `Rpc.ErrorCode` holds `ErrorCode` and `Rpc.Code` holds
  `Code`, each with `toString`, `fromString`, `toInt`, `fromInt`,
  `toHttpStatus` and `fromHttpStatus`; the prefixed `codeToString` and
  its siblings are gone.
- Typed records and descriptor trees. The runtime gains
  `Proto.Descriptor` (`MessageDescriptor`, `EnumDescriptor`,
  `MethodDescriptor`), `Proto.Http` (the HTTP bindings, moved from
  `Rpc`),
  `Proto.Message`, `Proto.Enum` and `Proto.Method` (a type's codecs and
  default with its descriptor; `typeName`, `typeUrl`, `toName`,
  `fromName`, `toNumber`, `fromNumber`), `Proto.WellKnown` (the well-known types'
  records) and `Proto.Registry` (descriptors by full name, `union`,
  `wellKnown`). `Rpc.call` takes a `Proto.Method.Method`;
  `Rpc.MethodDescriptor` is gone, and the call accessors are
  `Rpc.method`, `Rpc.descriptor`, `Rpc.serviceName`, `Rpc.methodName`
  and `Rpc.idempotent`. Generated package modules gain a
  `-- DESCRIPTORS` section with `messageFoo : Proto.Message.Message Foo`
  and `enumBar : Proto.Enum.Enum Bar` per type, the message trees empty
  for now, and service modules build each call from those records. The
  `services_types` conformance case covers methods of well-known types
  and of another package's messages.
- Generated descriptors hold the proto: each message's descriptor lists
  its fields in declaration order (name, JSON name, number, cardinality,
  kind, oneof) and its oneofs (an enum's is built from its record's
  values). Each package module ends its descriptors section with
  `registry : Proto.Registry.Registry`, transitive over the packages it
  imports and the well-known types; a package without types gets a
  module holding its registry. The trees are always written: compiled
  output is the same size when nothing reads them, and a `descriptors`
  option that left them empty was built, measured and dropped. The
  `services_only` conformance case: a package of services alone, whose
  package module holds its registry and nothing else.
- `Proto.Any`: `google.protobuf.Any` as an opaque `Any` holding a type
  URL and the packed message's JSON, or only its protobuf binary when
  that is all that arrived. `pack`, `packWith`, `unpack` (to
  `Maybe (Result Problem a)`, `Problem` being `Json` or `BinaryOnly`),
  `is`, `typeUrl`, `typeName`, `describe` (through a registry), and the
  proto3 JSON codecs, which write a well-known type with a JSON form of
  its own under `"value"`. `Proto.WellKnown.any` is its typed record and
  `Proto.Registry.wellKnown` holds its descriptor. `Rpc.Error`'s details
  are now `List Proto.Any.Any`, read from a `google.rpc.Status` body's
  proto3 JSON or a Connect body's `type`, `value` and `debug`; a detail
  in neither form is left out. `Rpc.details` gives an error's details of
  one message type.
- Generated `google.protobuf.Any` fields: `Proto.Any.Any`, singular as a
  `Maybe`, repeated, as a map value or a oneof member bare, coded with
  `Proto.Any.encodeJson` and `jsonDecoder`; a method of `Any` uses
  `Proto.WellKnown.any`. The `types::any` diagnostic is gone, and the
  `any_field` conformance case is a golden one. An `Any` request field
  outside the body is `route::query_field`.
- A `uint64` or `fixed64` field refuses a negative value when decoded
  (`Proto.Json.uint64`, `uint64AsInt`), as the 32-bit unsigned kinds do;
  `Proto.WellKnown.uint64Value` and `uint64ValueAsInt` likewise. The
  `naming::module_collision` help reads "every service becomes a
  module".
- Option `streaming=error|skip` (CLI `--streaming`). `skip` leaves each
  client, server or bidirectional streaming method out of its service's
  module and generates the rest; each one is a `services::streaming`
  warning, printed to stderr by both binaries and never failing the run.
  The `services::streaming` error names the option. Diagnostics gain a
  warning severity, and `elm_connect_gen::generate` returns
  `Generated { files, warnings }`; `ir::build_with` builds under the
  options that shape the IR, and the options live in
  `elm_connect_gen::options`. A service without methods gets no module,
  which Elm would reject. The conformance harness pins a case's warnings
  in `expected/warnings.txt` (`services_streaming_skip` case).
- A requested package is generated whole, from every compiled file
  declaring it (protoc's `proto_file` holds the imports), so a field
  whose type sits in an unrequested file of the same package is no
  longer silently dropped (`packages_whole` case). Only packages with a
  requested file are generated, as protoc plugins do; the
  `generate::not_generated` help now names the ways to request an
  imported file: `buf generate --include-imports`, the file on protoc's
  command line, or the CLI's new `--include-imports` flag, which adds
  the named files' transitive imports (bar `google/protobuf` and files
  declaring nothing) to the generate set.
- Option `rename=<proto full name>:<Elm name>` (CLI `--rename`), the
  only option that repeats: an Elm name used as it is in place of the
  derived one, for a package (its module), service (its module's last
  segment), method, message or enum (nested ones too), field, oneof (its
  field, and its type through it), oneof member or enum value (their
  constructors). Derived names follow a renamed one, a nested type's
  included. A name that does not suit its role is
  `options::invalid_rename`, a proto name that names nothing generated
  `options::unknown_rename`; collisions stay `naming::*`, and every
  `naming::*` help names the option (`rename` and `rename_invalid`
  cases).
- Option `enum_unknown=fail|zero` (CLI `--enum-unknown`). `fail`, the
  default, is unchanged: an unknown enum name fails the decode. `zero`
  reads an unknown name as the zero value, as an unknown number always
  is, for clients that outlive server deploys; generated decoders call
  the new `Proto.Json.enumOrZero`, which takes `Proto.Json.enum`'s
  arguments (`enums_unknown_zero` case). `Proto.Enum.fromName` and
  `fromNumber` still give `Nothing` for undeclared names and numbers.
- `Proto.Method.Method` is `{ encodeRequest, responseDecoder,
  descriptor }`: a method carries only what the wire needs, no longer
  its types' `Message` records. Elm's dead-code elimination keeps a
  top-level value whole, so every call used to bring both types'
  defaults and descriptor trees into the bundle. Service modules
  reference the codecs directly (`Notes.V1.encodeGetNoteRequest`,
  `Notes.V1.decodeNote`; for a well-known type the runtime's, such as
  `Proto.Json.encodeEmpty` and `Proto.Json.empty`) and no longer import
  `Proto.WellKnown`. A `Method` built by hand takes the codecs in place
  of `request` and `response`; the typed records still serve `Any`,
  error details and reflection.
- `Rpc.Error` has three constructors: `Status { code, message, details,
  source } Response`, a status the server stated in a Connect body, a
  `google.rpc.Status` body or the `grpc-status` headers; `Http
  Response`, an answer that stated none; and `Transport Http.Error`,
  unchanged. `Response` is `{ statusCode, statusText, headers, body }`,
  the answer as it arrived, kept so an application can parse an error
  body in a shape the runtime does not read (`Http response ->
  myDecoder response.body`). `Source` loses its `HttpStatus` case and
  `StatusBody`'s number. The new `Rpc.code` and `Rpc.message` give
  every error a code and a message: an `Http` error's code is inferred
  from its status by Connect's table, a `Transport` error's is the one
  the Connect clients give (a timeout `DeadlineExceeded`, a network
  failure `Unavailable`, a bad URL or undecodable body `Internal`).
  `Rpc.errorToString` is `<code>: <message>` for all three, so a
  transport error reads `deadline_exceeded: timeout` where it read
  `timeout`. `Trace.code` is a `Code`, no longer a `Maybe Code`:
  `Failed` on any error, a timeout included. Code that matches or
  builds `Rpc` errors by hand moves to `Status` and `Http`, or to
  `Rpc.code error` for the common case. The retry policy judges every
  error by its code, so a network failure retries when `Unavailable` is
  in `codes` and a timeout when `DeadlineExceeded` is.
