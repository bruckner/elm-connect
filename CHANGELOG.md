# Changelog

All notable changes to this project are recorded here. The Elm package
and the crates share one version and are released together, under one
tag (design §8).

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
- Live verification: `just live` runs the runtime against a server.
  `examples/notes/` holds an example API (`notes.v1.NotesService`), a Go
  server answering it over Connect (connect-go) and HTTP transcoding
  (Vanguard) from one port, and the Go and Elm buf generates for it;
  `conformance/live/` a headless Elm program over the runtime, driven
  from Node through an `XMLHttpRequest` over `node:http`, and a smoke
  suite of every method over both transports, error bodies with
  details, `grpc-status` headers, bare statuses, timeouts, retries,
  Connect GET, bindings, trackers and each way of sending. CI runs it
  as the `live` job; Go and buf join the toolchain pin.
- Live verification runs the Connect conformance suite
  (`connectrpc/conformance` v1.0.6, `just live-conformance`, part of
  `just live`): `conformance/live/conformance.mjs` makes the runner its
  client under test for unary calls over Connect with JSON on HTTP/1.1,
  `conformance.yaml` declaring the rest unsupported. Calls go through the
  pure halves and again through `Rpc.sendTraced`; 39 and 34 of 40 test
  cases pass, `known-failing.txt` (cancellation) and
  `known-failing-send.txt` (response headers and trailers, which only the
  halves give) listing the rest with reasons. The runner gains the
  `halves` way of sending, which reports the answer's status and headers.
- Live verification of transcoding: the example server also serves the
  route fixtures' `routes.v1.Routes` under Vanguard, echoing each
  request, and `conformance/live/routes.mjs` sends every fixture through
  the runtime and checks the request against the fixture, the echo
  against the fixture's request (as proto3 JSON) and the runtime's
  reading of the answer. Three fixtures part from Vanguard and two
  bindings cannot be served beside the others; both are recorded in
  `conformance/live/known-divergent.json` (design §7).
  `cases/transcode.json` adds `google.rpc.Status` bodies as sent,
  statuses without one, `grpc-status` headers and empty or non-JSON 2xx
  answers; the runner reports each exchange's response body.
- `examples/notes` is a browser application on the generated client:
  list, create, edit with an update mask, archive and delete, errors
  with their details, and a toggle between Connect and transcoding,
  every call through one `Api.rpc`. The server serves it with `-static`;
  `just example-notes` builds and runs both. `Google.Rpc` is generated
  for it from googleapis with buf. The README's examples and the new
  walkthrough are excerpts of it, checked by `just snippets` in the gate
  and compiled by `just live`; the `Any` example, which built a `Note`
  from two fields it does not have, is fixed. The `live` CI job caches npm, Elm and
  `connectconformance` as well as Go and buf.
- A path variable the request's JSON has no value for, such as one
  under an unset message, is sent as the field's proto3 default (`0`,
  `false`, an enum's zero name) instead of an empty segment, which a
  server parsing it as a number or enum rejects. `Proto.Http.variable`
  takes the default's text as a third argument, which the generator
  writes; the route fixture and Vanguard now agree on the request, and
  the server reading the messages on the way as set is recorded in
  `conformance/live/known-divergent.json` (design §5.3, §7).
- Generated encoders leave out every field at its default, as
  protobuf-go's `protojson` (and so connect-go) does: a field without
  presence at its zero value (a float only at `0`, so `-0`, NaN and the
  infinities are written), a `Maybe` when `Nothing` (no more `null`), a
  list or map when empty. A field with presence is written whenever it
  is `Just`, at its default too, and so is a oneof's set member; `Value`
  fields and `Empty` fields (`{}`) are always written. Decoding is
  unchanged: a missing field reads as its default. Request bodies
  shrink, and an application comparing encoded JSON as text will see
  smaller objects. A message encoder is now `Proto.Json.object` over
  `( String, Maybe Value )` pairs, with the new `Proto.Json.implicit`,
  `implicitFloat`, `repeated`, `dict` and `boolDict`; a oneof encoder
  gives `List ( String, Maybe Value )`. `Proto.Json.encodeMaybe` is
  removed. The Rust route reference serializes with defaults left out
  too (design §3.4).
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
- `Rpc.Trace` gains `headers` and `trailers`: the last answer's response
  metadata, split as a Connect unary answer carries it, trailers being
  the headers named `trailer-<name>`; names are lowercased and a
  repeated header's values come joined with `", "`. `Rpc.splitTrailers`
  applies the same rule to the `Http.Metadata` the pure halves give.
  The Connect conformance suite's five header and trailer test cases now
  pass through `Rpc.sendTraced` (39 of 40), and `known-failing-send.txt`
  lists none.
- `Rpc.Error` gains `Canceled`, a call the application withdrew, and
  `Rpc.cancel tracker toMsg` cancels a call sent with `Rpc.send` through
  that tracker and reports `Err Canceled` to `toMsg`, where
  `Http.cancel` alone reported nothing. Its code is `Canceled`, its
  message empty and `errorToString` gives `canceled`. Code that matches
  every `Rpc.Error` constructor adds a branch for it. The live runner
  cancels as an application would (an envelope's `cancelAfterMs`), so
  the Connect conformance suite's cancellation case passes, 40 of 40
  through the halves and 39 through `sendTraced`, whose task cannot be
  cancelled, and a smoke case cancels a call sent with `send`.
- `protoc-gen-elm-connect` no longer generates `google/api/http.proto`
  or `google/api/annotations.proto` when they are among its files to
  generate, as they are under `buf generate --include-imports`: they
  only carry `google.api.http`, and every API with HTTP rules got a
  `Google.Api` module of `Http`, `HttpRule` and `CustomHttpPattern`.
  The rule is by file name, the files the CLI embeds, whose
  `--include-imports` already skipped them; other `google/api` files,
  such as `httpbody.proto`, still generate. `just live-gen` checks the
  notes example under `buf generate --include-imports`.
- The live suite generates without the network: the googleapis files the
  notes example imports and the Connect conformance suite's protos are
  vendored (`examples/notes/third_party/googleapis/`,
  `conformance/live/suite/proto/`), exported from the Buf Schema Registry
  at the commits that were pinned, so a cold buf cache no longer depends
  on the registry being up. `examples/notes/buf.lock` is gone, and `just
  protos-refresh` re-exports both. The generated code is unchanged.
- Option `module_prefix=<Elm module>` (CLI `--module-prefix`), such as
  `module_prefix=Api.Notes`: every module the run generates goes inside
  it, package and service modules alike, a renamed package's too, with
  file paths, imports and references following; the runtime's modules
  are untouched. A value that is not dot-separated Elm module segments
  is an error. The `module_prefix` conformance case pins it.
- Property tests (design §7). Elm fuzz tests check the runtime's laws:
  every proto3 JSON codec round-trips across its type's range (64-bit
  integers past 2^53, floats' special values, both base64 alphabets,
  timestamps of years 1 to 9999, durations to ±315,576,000,000 s, field
  masks, enums, maps, `Struct` and the rest), the generated codecs leave
  out defaults, and `Rpc.request` over Transcode keeps path values,
  query and body apart and percent-encodes what it must. The route
  fixtures' test samples 16 requests for each binding of `routes.proto`
  (256 in all) from a fixed seed, and its reference's HTTP requests
  for them are pinned in `tests/RouteProperties.elm` and replayed
  through `Rpc.request` as the fixtures are (`just bless` rewrites the
  file). `routes.proto`'s `Resource` gains three map fields for them,
  which the live suite's `routes.mjs` now reads. The reference writes a
  float in a path or query as the runtime does: `Infinity`, not Rust's
  `inf`, and a finite value in ECMAScript's form.
- A map or `Struct` key of `__proto__` is written: `Proto.Json.dict`,
  `encodeStruct` and `object` build an object holding that key as text
  and parse it, since assigning it to a JavaScript object sets the
  prototype and `Json.Encode.object` lost it, while decoding kept it.
- A lone surrogate in a path or query value is percent-encoded as U+FFFD,
  as the WHATWG URL encoder writes it, where the bytes of the surrogate
  itself were written, which is not UTF-8.
- Docs: `-0` is written as `0` (JavaScript's JSON writer has no negative
  zero); design §3.4 and `implicitFloat` said it was written.

- The live suite runs against grpc-gateway (v2.32.0) as well as Vanguard:
  the notes example's server mounts it under `/gateway`, proxying over
  gRPC to the same service, and `just live` runs the transcode cases (32
  pass) and the route fixtures against it (20 agree; 6 diverge, recorded
  in `conformance/live/known-divergent-gateway.json` with a reading of
  who is right: among them, the gateway keeps a `FieldMask` query value's
  paths in their JSON form and its default unescaping splits `%2F` in a
  single-segment variable). `routes.mjs` and `run.mjs` take `--prefix`,
  `run.mjs` `--transport`, and Vanguard's file is now
  `known-divergent-vanguard.json`, its matched answer under `observed`.
  Both files hold probes, requests the runtime does not make, asserting
  where the two transcoders answer differently.
- The notes example's transport selector gains a third choice, HTTP
  transcoding via grpc-gateway, which sends the same calls to the
  server's `/gateway`.
- Generated code names the elm-connect release it was generated for:
  every module imports the runtime's new `Proto.Version` and defines
  `elmConnectVersion_ = Proto.Version.v0_1` (the generator's major and
  minor version), so a runtime package from another release is a
  compile error naming `Proto.Version`. The trailing underscore marks
  the name as the generator's own, as in a recursive message's wrapper
  (`Node_`): derived value names drop underscores, so no proto name
  derives to it, and a `rename` to it is `naming::value_collision`.
  `elm.json`'s version is now `0.1.0`, the crates' version, which it
  follows in lockstep (design §8).
- The conformance corpus's expected modules and the route replay's
  modules in `tests/Routes` carry `0.1.X` (the major and minor version,
  `X` for the patch) on their header line, which their tests substitute
  before comparing and `just bless` writes, so a patch release leaves
  them alone; a minor release re-blesses the header's minor and the
  `elmConnectVersion_` line in each.
- `elm-connect check`, with `gen`'s arguments: generates in memory and
  compares with the tree under `--out`, reporting missing modules,
  differing ones as unified diffs, and stale files (generated by
  elm-connect, no longer generated); a tree that differs only in the
  version it names gets one message naming both versions. Exits 1 on
  drift.
- Design §8 states the compatibility and versioning policy: one version
  for the Elm package and the crates, released under a bare `X.Y.Z` tag;
  the `Proto.Version` sentinel and what each surface promises within a
  major; the header line as provenance; the drift check. §10 records a
  proposal to emit the runtime's modules beside the generated code.
- Decoding a message takes time linear in its fields: each field step
  looks its key up directly instead of listing the whole object, which
  made a 256-field message about 250 times slower per field than an
  8-field one.
- The package requires elm/json 1.1.4 or newer, which lists an object's
  keys without calling the object's own `hasOwnProperty`, so a JSON key
  of that name no longer fails the decode of the message, map, `Struct`
  or `Any` holding it.
- `Proto.Json.intDict` accepts only canonical decimal keys within
  32 bits: `"07"` (which collided with `"7"`), `"+5"`, `"-0"` and keys
  past 2^32 − 1 or below −2^31 now fail.
- Percent-decoding a `grpc-message` header and parsing a timestamp's
  fraction no longer recurse once per character, so a long header (from
  about 5,000 characters) no longer overflows the stack inside elm/http's
  load handler and leaves the call without a result.
- A timeout that is not a positive number (`0`, negative, NaN,
  infinite) is no timeout: no `Connect-Timeout-Ms` header and no
  elm/http timeout, rather than a 1 ms or maximal header and an XHR
  timeout of none or weeks. A call's such timeout leaves the config's.
- A call whose config's `baseUrl` holds `?` or `#` is not sent and fails
  with `Transport (Http.BadUrl url)`.
- `Rpc.message` (and so `Rpc.errorToString`) quotes at most 300
  characters of a bad response body's problem, then `…`; the whole
  problem stays in `Transport (Http.BadBody problem)`.
- `Proto.Enum.toName` and `toNumber` document what they give for a
  value the encoder writes as other than a name (`""` and `0`).
- A file that declares an edition is `input::editions`, naming the file
  and its edition and asking for `syntax = "proto3";`: the plugin
  panicked in its descriptor pool (exit 101), and the CLI printed
  protox's parse error. Design §1.3 said editions were accepted; it now
  says they are not, in this release.
- `protoc-gen-elm-connect --version` prints the plugin's version and
  `--help` its usage, before reading stdin; run from a terminal with no
  arguments it prints its usage and exits 2 rather than wait silently
  for a request, and an unknown argument exits 2.
- `naming::reserved_name`: a message, enum, oneof or enum value whose Elm
  type or constructor takes a name its module's code uses unqualified
  (`Dict`, `Duration`, `String`, `Int`, `Float`, `Bool`, `List`,
  `Maybe`, `Just`, `Nothing`, `False`), directly or by `rename`, is an
  error naming the escape; the module did not compile, and `gen` exited
  0. Only names the module actually uses count: a message `Dict` in a
  package without maps still generates. `naming::reserved_module`: a
  package or service whose module is one of the runtime's (`Rpc`,
  `Proto.*`) or of elm/core, elm/json, elm/http or elm/time (`Time`,
  `Json.Decode`), which made every import of it ambiguous, is an error
  naming `rename` and `module_prefix`. The help of both writes the
  option as the front end takes it (`--rename` from the CLI, `rename=`
  from the plugin). Two generated modules whose names differ only in
  case are `naming::module_collision`: their files overwrote each other
  on macOS and Windows.
- HTTP rules whose literals or custom verb are not URL path text are
  `route::template`: a literal or verb holds RFC 3986 `pchar`s alone (a
  `?`, `#`, space, control or non-ASCII character, or a `%` opening no
  escape, was written into the URL as it was), and a literal is not a
  dot segment (`..` in `/v1/../admin` left the base URL's path). A
  `custom` kind that is not an HTTP token, or is `CONNECT`, `TRACE` or
  `TRACK`, is `route::rule`; one with CRLF in it reached `xhr.open`.
  The `routes_unsafe` case pins them.
- A proto file whose name holds a newline or another control character
  is `input::file_name`: the name went into the generated header comment
  as it was, and the text after the newline into the module.
- The CLI's `--include-imports` generates only the imported files that
  declare a message or enum the requested packages refer to,
  transitively, and builds each imported package from those files
  alone. A file imported for its options alone, such as
  `google/api/client.proto` or `field_behavior.proto`, no longer brings
  a `Google.Api` module of every type of the package (`HttpRule`
  among them) into the output; a referred-to `google/api/httpbody.proto`
  gives a `Google.Api` of `HttpBody` alone. An imported file of
  services alone is no longer generated. The README's sentence on
  `Google.Api` now says what each binary does.
- `elm-connect check` counts a generated file as stale only when its
  first line names one of the protos it was run on, so two `gen` runs
  sharing an `--out` no longer fail each other's check; it exits 2, not
  1, when it cannot tell (bad arguments, a proto that does not compile,
  an unreadable directory), so 1 always means drift; and its diffs label
  both sides with the real path, `(on disk)` and `(generated)`, where
  the second said `generated/`. Its help says to give it `gen`'s `-I`.
- `elm-connect gen` warns on stderr about each stale generated file it
  leaves under `--out` (by `check`'s rule; it deletes nothing) and says
  how many modules it wrote.
- `Proto.Message.Message`, `Proto.Enum.Enum` and `Proto.Method.Method`
  are opaque, so they can gain what a later release needs as a
  modifier without breaking generated code. They are built by
  `Proto.Message.message`, `Proto.Enum.enum` and `Proto.Method.method`,
  each taking its codecs, default (not for a method) and descriptor in
  order, and read by `encode`, `decoder`, `default` and `toDescriptor`
  (`encodeRequest`, `responseDecoder` and `toDescriptor` for a method).
  The record fields `encodeJson`, `jsonDecoder` and `descriptor` are
  gone; `messageNote.descriptor` is `Proto.Message.toDescriptor
  messageNote`.
- Generated modules give each message and enum a top-level descriptor,
  `descriptorNote` and `descriptorVisibility`, which `messageNote` and
  `enumVisibility` hold, and the package `registry` is built from them,
  so a program using the registry no longer keeps every type's codecs.
- A service module gives each method a top-level descriptor,
  `descriptorGetNote : Proto.Method.Descriptor`, in a
  `DESCRIPTORS` section before the `CALLS`, and the call refers to it
  instead of building it inline. Its name follows the method's Elm name,
  renamed or not; a method named for another's descriptor
  (`DescriptorGetNote` beside `GetNote`) is `naming::value_collision`.
- A generated method's `Proto.Method.method` application puts one
  argument per line however short, so a method's call reads the same
  with or without an HTTP rule. The printer gains `Expr::StackedApply`
  for that layout.
- The descriptor trees are opaque, each named `Descriptor` in the
  module of its concept beside the typed value, built by a positional
  `descriptor` function and read by plain nouns:
  `Proto.Message.Descriptor`, `Proto.Enum.Descriptor` and
  `Proto.Method.Descriptor`, and the new modules `Proto.Field` (a
  field's descriptor, with `inOneof`) and `Proto.EnumValue` (in place of
  the `{ name, number }` record). A field's unions are in `Proto.Field`,
  every constructor prefixed with its union's name:
  `CardinalitySingular`, `KindMessage`, `ScalarString`. The
  `Proto.Descriptor` module is gone. `typeName` and `typeUrl` read a
  message's descriptor, not its typed value
  (`Proto.Message.typeUrl Notes.V1.descriptorNote`), and a typed value's
  descriptor is `toDescriptor`. A message's oneofs are derived from its
  fields' `inOneof`, which generated code writes only for a oneof
  member.
- A method descriptor carries the proto's three-level
  `idempotency_level` as `Proto.Method.Idempotency`
  (`IdempotencyUnknown`, `IdempotencyNoSideEffects`,
  `IdempotencyIdempotent`), built and read by
  `Proto.Method.descriptor` and `Proto.Method.idempotency`, in place of
  `idempotent : Bool`, which was true for `NO_SIDE_EFFECTS` alone. A
  retry policy with `idempotentOnly` now retries an `IDEMPOTENT` method
  too; Connect still sends only an `IdempotencyNoSideEffects` method as
  a GET. `Rpc.idempotent` keeps its meaning, the method has no side
  effects. `annotations` conformance case.
- `Proto.Field.Cardinality` gains `CardinalityRequired`, for proto2's
  `required`, which the generator does not give yet.
- Descriptors carry each field's `google.api.field_behavior`
  (`Proto.Field.behavior`, a list of the new `Proto.Field.Behavior`:
  `BehaviorRequired`, `BehaviorOutputOnly`, …) and `deprecated` option,
  and each enum value's `deprecated` (`Proto.EnumValue.deprecated`),
  written by generated code as `withBehavior` and `withDeprecated`
  modifiers only where set. The CLI embeds
  `google/api/field_behavior.proto`, which neither binary generates;
  the `annotations` conformance case pins the modifiers.
- The notes example has an update-mask snippet
  (`Snippets.UpdateMask`: a `google.protobuf.FieldMask` from two values
  of a message, and a check of a mask's paths), with tests that
  `just check` runs.
- `Rpc.Transport` is an opaque type in its own module, built by
  `connect`, `connectGet` (an `IdempotencyNoSideEffects` method's call
  as a GET),
  `transcode` and `withMaxGetUrl`, and named by `name` (`"connect"`,
  `"transcode"`), so a protocol or an option can be added in a minor.
  It replaces `Rpc.Transport(..)`, `Connect { useGet, maxGetUrl } |
  Transcode`, and `Rpc.connect`: `{ config | transport =
  Rpc.Transport.transcode }`.
- `Rpc.Retry` is an opaque type in its own module: `Rpc.Retry.on codes`
  retries those codes with defaults (3 attempts, 200 ms doubling, a
  30 s cap, full jitter, idempotent methods only), changed by
  `withAttempts`, `withBackoff`, `withMaxBackoff`, `withoutJitter` and
  `allowNonIdempotent`. It replaces the `{ attempts, backoff, codes,
  idempotentOnly }` record. Waits are capped and jittered: no wait
  exceeds 2^31 − 1 ms, past which `setTimeout` ran a long backoff at
  once, and each is drawn uniformly below its bound, seeded from the
  clock, so clients that failed together do not retry together.
- `Rpc.ErrorCode` is renamed `Rpc.Code`, its type `Code`, with the same
  constructors and helpers. The former `Rpc.Code` (`Ok | Failed
  ErrorCode`) is removed: success has no code.
- `Rpc.Trace` is an opaque type in its own module, read by
  `serviceName`, `methodName`, `transport` (new: the config's transport
  name), `binding`, `request`, `httpStatus`, `headers`, `trailers`,
  `code` (now `Maybe Code`, `Nothing` on success),
  `duration` and `attempts`, with `toJson` (every field, stable keys)
  and `toString` (one log line, without the request). The record fields
  `service` and `method` are now `serviceName` and `methodName`, as on a
  call.
- `Rpc.Request`'s and `Rpc.Response`'s `body` are an opaque `Rpc.Body`
  (`Rpc.Body.none`, `text`, read by `toText`) in place of `Maybe String`
  and `String`, so a body of bytes can be added in a minor.
- `Rpc.Config`, `Rpc.Request` and `Rpc.Response` are frozen records
  (design §8.3): a new option goes on `Transport`, `Retry` or `Call`,
  or on a future `Rpc.Client`, never into `Config`.
- `Rpc.checkConfig : Config -> List String` reports a config's problems
  where the application builds it, today a `baseUrl` holding `?` or
  `#`; sending such a config still fails with `Http.BadUrl`.
- `Rpc.Response` gains `url`, the URL the answer came from after any
  redirect (`Http.Metadata.url`).
- `Rpc.idempotent : Call -> Bool` is replaced by `Rpc.Call.idempotency :
  Call -> Proto.Method.Idempotency`, the descriptor's three levels.
- A call's modifiers and readers move from `Rpc` to a new `Rpc.Call`
  module, where its type is defined: `withHeaders`, `withTimeout`,
  `withTracker`, `viaBinding`, `method`, `descriptor`, `serviceName`,
  `methodName`, `idempotency`, `requestMessage`, `requestJson` and
  `toJson`. `Rpc.call` and the type's alias `Rpc.Call` stay, so
  generated code is unchanged.
- `Rpc.Request` and `Rpc.Response` are each declared in a module of
  their own (`Rpc.Request.Request`, `Rpc.Response.Response`), the same
  frozen records; `Rpc` aliases both, so annotations naming
  `Rpc.Request` and `Rpc.Response` compile unchanged, and
  `Rpc.Trace.request` gives an `Rpc.Request.Request`.
- `Rpc.cancel : String -> Cmd msg` is plain `Http.cancel` again: a
  cancelled call reports nothing, and the `Canceled` error is removed.
  The synthetic outcome was reported when nothing was in flight, and
  beside a retry policy the call reported `Canceled` and then its
  result. An application that wants a message batches its own, and
  ignores, by request id, a result that arrives after it cancelled.
- `Rpc.Error` is reshaped, in a module of its own with its readers:
  `RpcStatus StatusError Response` (was `Status`), `HttpStatus
  Response` (was `Http`), `BadResponse String Response` (a 2xx whose
  body did not decode, which was `Transport (Http.BadBody _)` and lost
  the answer) and `NoAnswer Reason`, `Reason` being `Timeout`,
  `NetworkError` or `BadUrl String` (was `Transport Http.Error`, so
  elm/http's type is no longer in the API). `Rpc.code`, `Rpc.message`,
  `Rpc.details` and `Rpc.errorToString` move to `Rpc.Error.code`,
  `message`, `details` and `toString`, and `Source` to `Rpc.Error`;
  `Rpc.Error` stays as an alias of the type. A bad URL's message
  leaves out the URL's user, password and query, and a bad URL is
  never retried.
- `Rpc.send` and `Rpc.sendTraced` take the message before the call
  (`send : Config -> (Result Error res -> msg) -> Call req res -> Cmd
  msg`), so a call pipes into them as into `Rpc.task`:
  `Notes.getNote req |> Rpc.send config GotNote`.
- A header a browser refuses (a name that is not an HTTP token, a value
  holding NUL, CR, LF or a character above U+00FF once spaces and tabs
  at either end are trimmed) no longer reaches elm/http, where
  `setRequestHeader` threw and stopped the whole program: every way of
  sending fails such a call with `NoAnswer (InvalidHeader name)`,
  nothing sent and never retried. `Rpc.checkConfig` reports such
  config headers by name; `Rpc.request` still builds the request. A
  trace of a call that was not sent has `attempts` 0.
- Over transcoding, a binding's literal segments and custom verb are
  percent-encoded where a path segment cannot hold a character (RFC
  3986 `pchar`; a valid `%XX` escape is kept), so a hand-built
  `Proto.Http.literal` holding `#`, `?`, `/` or a space cannot change
  the URL's shape. Generated bindings, which the generator already
  checks, are unchanged.
- A query parameter's message that contains itself, directly or through
  other messages, is refused at the field that holds it and not expanded.
  The walk used to expand it and refuse the field that closed the cycle,
  reporting every field along the way at every depth, once per rule: on
  a cycle of thousands of messages with a GET rule on each, `elm-connect
  gen` allocated gigabytes before it could report `route::query_field`.
  The `routes_query_cycle` case pins where the problem is reported.
- Problems share one copy of each proto file's text for their snippets
  where each held its own: with a problem per rule, a large file's
  copies took gigabytes before the report could be rendered.
- A message held deeper than 100 messages below the request, protobuf's
  nesting limit for parsing, is refused where it is held
  (`route::query_field` for a query parameter, `route::path_field` for a
  path variable) and not expanded: no server reads it, and the limit
  bounds the walk of a long chain of messages, which was every leaf
  below each rule. The `routes_query_depth` case pins the limit from
  both sides.
- A singular `google.protobuf.Value` field, `optional` or not, is now
  `Maybe Json.Encode.Value`, decoded with the new
  `Proto.Json.valueField` (`valueFieldEither`): a missing key is
  `Nothing`, and `null` is `Just Json.Encode.null`, set, as protobuf's
  parsers read it. The field was a bare `Json.Encode.Value` that read a
  missing key as `null` and was always written, so a default message
  sent `"payload": null` and the server saw the field set; an `optional`
  one read `null` as `Nothing`. `Nothing` now leaves the field out, so a
  default message with a `Value` field encodes as `{}`. Repeated, map
  and oneof forms are unchanged.
- A generated record's fields, and its default, descriptor, encoder and
  decoder, are in declaration order, the order the `.proto` file writes
  them in; they were in field-number order, against the design. The
  record constructor is positional, so a message whose numbers are out
  of declaration order now takes its arguments in another order. The
  `field_order` conformance case pins it.
- Generated list literals put one element per line whenever they have
  any, a list of one included, rather than only from two elements on.
  A path variable's field names and template, a query parameter's
  field names and a field's behaviors stay on one line (design §3.1).
- The `bytes=bytes` option (`--bytes bytes` on the CLI) holds `bytes`
  fields, and the `BytesValue` wrapper, as elm/bytes' `Bytes` rather
  than their base64 text, with the `bytes_option` conformance case.
  `bytes=string`, the base64 text, stays the default: Elm's `==` finds
  any two `Bytes` values equal, so records holding them compare equal
  whatever the bytes.
- The runtime gains `Proto.Bytes`, converting base64 text to and from
  elm/bytes' `Bytes` (`fromBase64`, `toBase64`, `empty`), and the
  `Proto.Json` codecs for bytes held as `Bytes` (`bytesAsBytes`,
  `encodeBytesAsBytes`, `implicitBytes`). The package now depends on
  elm/bytes. Elm's `==` finds any two `Bytes` values equal, whatever
  they hold; the module documentation says what that means for records
  and tests.
- Map keys are decoded by their kind. `Proto.Json.intDict` is replaced by
  `int32Dict` and `uint32Dict`, which check the key type's own range, and
  64-bit keys, which were taken as received, now go through `int64Dict`
  and `uint64Dict`, which validate them as 64-bit values and hold them in
  canonical decimal form (`"007"` is the key `"7"`). Every integer key is
  read as a 64-bit value's string is, so `"07"` and `"1e2"` are keys; two
  keys that name one integer (`"7"` and `"07"`) fail the decode instead of
  one replacing the other. The Elm types are unchanged.
- A message without fields decodes only from a JSON object, through the
  new `Proto.Json.emptyMessage`, as every other message does; it
  accepted any JSON (`5`, `"x"`, `[]`, `true`) before.
- `Proto.Field.KindEnum` holds the enum's `Proto.Enum.Descriptor`
  instead of its full name, so a field's enum values, its zero value
  among them, can be read from the field alone. Generated descriptors
  write `KindEnum Notes.V1.Visibility.descriptor`; code matching on
  `KindEnum` reads the name with `Proto.Enum.typeName`. `KindMessage`
  still names its message, since a message can contain itself.
- Descriptors move out of the package module into a module per message
  and enum beside it: `Notes.V1.Note` holds `descriptor :
  Proto.Message.Descriptor` and one `Proto.Field.Descriptor` per field,
  named as its record field (`Notes.V1.Note.title`; a oneof member's
  is the end of its constructor, its first letter lowercased), and
  `Notes.V1.Visibility` holds the enum's `descriptor`. `Notes.V1` keeps
  the values a program sends and receives: types, defaults, codecs, the
  typed values (`messageNote`, `enumVisibility`) and `registry`, in
  sections types, defaults, typed values, registry, encoders, decoders.
  `Notes.V1.descriptorNote` is now `Notes.V1.Note.descriptor`. A message
  or enum whose module name another generated module has (a service of
  its package, a package nested in its own, or another type's but for
  case) is `naming::module_collision`. A field named `descriptor` gets
  the value `descriptor_` there (its record field stays `descriptor`);
  two fields whose descriptor values meet, or a field renamed to
  `elmConnectVersion_`, is `naming::value_collision`.
- `Proto.Http.variable` takes `{ fieldPath, template }` and `Proto.Http.param`
  a path, where `fieldPath` is the path of field descriptors from the
  request message down to the field (`[ Notes.V1.GetNoteRequest.name ]`)
  instead of positional names and texts. The runtime derives a
  variable's or parameter's JSON path, a parameter's dotted proto name,
  the text of the field's default (an enum's zero value's name from its
  descriptor) and whether a parameter is left out at it, once, when the
  binding is built; the generator no longer computes them.
  `Proto.Http.bodyField` takes the body field's descriptor
  (`Notes.V1.CreateNoteRequest.note`) and `Proto.Http.binding`'s
  `responseBody` the response field's
  (`Just Notes.V1.ListNotesResponse.notes`), instead of JSON names.
  Generated service modules import the descriptor modules their routes
  name. A path variable, body field or response body of a well-known
  request or response type is `route::path_field`, `route::body_field`
  or `route::response_body`.
- `Proto.Json`'s field encoders end in `Field`: `implicit`,
  `implicitFloat`, `implicitBytes`, `repeated`, `dict` and `boolDict` are
  `implicitField`, `implicitFloatField`, `implicitBytesField`,
  `repeatedField`, `dictField` and `boolMapField`, and `object` is
  `objectOfFields`, so no helper is named like an elm/json function of
  another type. `Proto.Any.encodeJson` and `jsonDecoder` are
  `Proto.Json.encodeAny` and `Proto.Json.any`, beside the other
  well-known types' codecs. Generated code calls the new names (design
  §3.1, which also records why generated codecs stay `encodeX` and
  `decodeX`).
- `Proto.Duration.seconds` and `milliseconds` are `toSeconds` and
  `toMilliseconds`, as `Proto.Int64.toInt` is. `fromSeconds` and
  `fromMilliseconds` give protobuf's limit, ±315,576,000,000 s, for a
  value past it, and `fromSeconds` gives zero for NaN and the
  infinities, so every `Duration` prints as text `fromString` reads.
- `Proto.Json.int64` and `uint64`, and the `int64Dict` and `uint64Dict`
  keys, check the type's range, -9223372036854775808 to
  9223372036854775807 and 0 to 18446744073709551615, by comparing the
  digits as text; any value of up to 20 digits passed before. The
  errors name the range, as the 32-bit ones do. Design §3.4 records
  why 64-bit integers and `bytes` stay `String` rather than opaque
  types.
- `Proto.Json.int32` and `uint32` read a string as `int64` reads one,
  then check the range, so `"+5"`, `"1.e3"` and `".5e1"` fail as they
  do for a 64-bit value and an integer map key; they went through
  `String.toFloat` before.
- The diagnostic code `generate::unimplemented` is gone: nothing reported
  it since every proto3 construct is generated, and codes become
  permanent at 1.0 (design §8.3).
- Option problems are diagnostics with codes, rendered like every other:
  `options::unknown_option` (an unknown key, an unknown value for a known
  key, or a pair without `=`), `options::duplicate_option` (an option
  other than `rename` given twice, or one proto name renamed twice) and
  `options::invalid_module_prefix`; a `rename` without its `:` is
  `options::invalid_rename`. The plugin reports every problem in its
  parameter at once rather than the first. A run whose only problems are
  in the options says "a problem in the options", and the CLI prints one
  `Error:` per problem rather than another before the header.
- `docs/diagnostics.md` lists every diagnostic code by family, with what
  it reports and its escape in both the CLI's and the plugin's
  spelling; a test holds the list to the generator's codes. Two codes
  move to the `input::` family, which holds what the generator was
  handed: `generate::unknown_file` is now `input::unknown_file` and
  `generate::not_proto3` is now `input::not_proto3`.
- Every diagnostic code the corpus can reach has a rendered snapshot:
  the `naming_invalid`, `naming_type_collision`, `types_unsupported`,
  `input_proto2` and `options_invalid` conformance cases.
  `input::unknown_file`, `input::editions` and `input::file_name`
  cannot come from the corpus and stay covered by the crates' tests, as
  `docs/diagnostics.md` says.
- Every diagnostic help that names an option writes it as the front end
  takes it: `--rename`, `--streaming skip` and `--unbound-methods
  implicit` under the CLI, `rename=`, `streaming=skip` and
  `unbound_methods=implicit` under the plugin. Only `naming::reserved_*`
  did before.
- A diagnostic's `rename` escape names the element at fault by its proto
  full name, `rename=notes.v1.Note.title:<Elm name>`, rather than
  `<proto full name>`: a collision's second claimant, or the first when a
  rename of the second would not part them.
- Did-you-mean hints: `options::unknown_rename` suggests the closest
  proto full name the generated packages have, and its help says that a
  rename takes proto names (`page_count`, not `pageCount`);
  `route::path_field`, `route::body_field` and `route::response_body`
  suggest the closest field when the one named does not exist. A
  suggestion differs only in case and underscores, or is within three
  edits. The `suggestions` conformance case pins them.
- Two messages whose Elm types collide are one `naming::type_collision`,
  which says their record constructors collide too, rather than that and
  a `naming::constructor_collision` with the same sites.
  `naming::constructor_collision` remains for constructors whose types
  do not collide, such as an enum value beside a message of its name.
- A `route::*` problem underlines what it is about: the quoted path,
  `body`, `response_body` or custom kind, or the additional binding's
  block, found in the rule's text, rather than the whole
  `option (google.api.http)`, which is all `SourceCodeInfo` records. Where
  the literal is not found, or there is no source text, the whole option
  stays the site.
- The plugin's diagnostics say where: with no source text from protoc to
  draw a snippet from, each problem leads with its site as
  `library/v1/library.proto:5:9`, from the request's `SourceCodeInfo`,
  and one with several sites lists each with its label. The CLI's
  rendering is unchanged.
- A collision that a rename caused says so: the renamed side's label
  reads "renamed to `title` by `rename`" (`--rename` under the CLI), and
  the help points at that rename rather than at renaming the protos. The
  `rename_collision` conformance case pins it.
- The CLI's "import not found" and "file not found" errors name the
  include paths searched and say to add the file's directory with `-I`.
  The error itself is still protox's.
