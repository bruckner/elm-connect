# elm-connect — design

**Status:** draft, open for iteration. Every section is marked *Decided*
(settled unless someone makes a case), *Proposed* (a recommendation with
the alternatives listed), or *Open* (no recommendation yet). Change this
document by pull request; the PR discussion is the design record.

## 1. What this is

A code generator and a runtime that let an Elm application call a
protobuf-defined API over JSON. Two transports are supported from the
same generated code:

| Transport | Wire | Server side |
|---|---|---|
| **Connect** | `POST /<pkg>.<Service>/<Method>`, JSON body, Connect error JSON | connect-go, connect-es, connect-python, connect-kotlin/swift, Envoy Connect filter |
| **Transcode** | REST paths from `google.api.http`, proto3 JSON, `google.rpc.Status` errors | grpc-gateway, Envoy gRPC-JSON transcoder, any hand-written REST layer that honours the annotations |

The generator is written in Rust. The runtime is an Elm package,
`bruckner/elm-connect`. Both live in this repository.

### 1.1 Why it exists

The Elm ecosystem has one maintained protobuf stack
([eriktim/elm-protocol-buffers](https://package.elm-lang.org/packages/eriktim/elm-protocol-buffers/latest/)
plus [protoc-gen-elm](https://www.npmjs.com/package/protoc-gen-elm) and
[elm-grpc](https://package.elm-lang.org/packages/anmolitor/elm-grpc/latest/)),
and it is binary-first with gRPC-web as its transport. Nobody generates
Elm clients for `google.api.http` transcoding, and nobody speaks the
Connect protocol from Elm. Those two server shapes are what most
protobuf-backed web services actually expose to browsers.

This generator grew out of an in-house Elixir protoc plugin that has
generated a production Elm client since early 2026. That plugin proved the
JSON-only, zero-wrapper-type approach. This is its portable rewrite with
a second transport and a public interface designed to be kept.

### 1.2 Goals

- Generated code a reader can open and understand without the runtime's
  source. Plain records, plain custom types, plain decoders.
- Which transport a method supports is visible in the types. Calling a
  method over a transport it does not support is a compile error.
- Diagnostics in the register of Elm's own compiler: the proto source
  with the problem underlined, and a sentence saying what was expected.
- One binary, no protoc required, on every platform Elm runs on. And
  a conventional protoc plugin from the same library, for build chains
  already built around protoc or Buf. Both entry points are first-class.
- A conformance corpus that pins the generated output and the routes it
  produces, so a server-side transcoder and this client cannot drift.

### 1.3 Non-goals (for 1.0)

- Streaming of any kind, on either transport. Connect streaming uses
  enveloped frames; grpc-gateway and Envoy stream newline-delimited JSON
  in different shapes. Each would be its own design.
- Binary protobuf. JSON only. Users who need `application/proto` have
  the existing stack.
- gRPC-web.
- proto2 syntax. Editions are accepted where they reduce to proto3
  semantics.
- Server code generation.

## 2. The layering  *(Decided)*

Generated code carries no transport. Three layers:

1. **Types and JSON codecs.** Records for messages, custom types for
   enums and oneofs, `encode*` and `decode*` for each. Identical under
   either transport because both use proto3 JSON.
2. **Method descriptors.** One value per RPC describing it: service and
   method names, request and response codecs, idempotency. A method that
   carries a `google.api.http` rule additionally gets a *route* value. A
   method without one gets no route value, so there is nothing to pass
   to the transcoding transport.
3. **Runtime transports.** `Connect` and `Transcode` modules in the
   runtime package. Each takes a config and a descriptor (plus a route,
   for `Transcode`) and produces a `Task` or `Cmd`.

This is the shape connect-es arrived at in v2 (service descriptors from
`protoc-gen-es`, transport in the runtime) and the shape anmolitor's
protoc-gen-elm uses (service module as data, elm-grpc as transport). It
dissolves the "one plugin or two" question: one plugin emits layers 1
and 2; the transport choice is made at the call site.

### 2.1 Before and after

A small service, as a proto:

```proto
package notes.v1;

service Notes {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option (google.api.http) = { get: "/v1/{name=notes/*}" };
  }
  rpc CreateNote(CreateNoteRequest) returns (Note) {
    option (google.api.http) = { post: "/v1/notes" body: "note" };
  }
  rpc Summarize(SummarizeRequest) returns (Summary);   // no HTTP rule
}
```

The in-house generator this grew out of emitted one `Http.request` per
RPC with helpers inlined into every module:

```elm
getNote : Config -> GetNoteRequest -> (Result Http.Error Note -> msg) -> Cmd msg
getNote config request toMsg =
    Http.request
        { method = "GET"
        , headers = authHeaders config
        , url = config.baseUrl ++ ("/" ++ "v1" ++ "/" ++ request.name)
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg decodeNote
        , timeout = Nothing
        , tracker = Nothing
        }
```

Proposed output under this design (names illustrative, see §4):

```elm
-- Notes/V1.elm (generated)

getNote : Connect.Method GetNoteRequest Note
getNote =
    Connect.method
        { service = "notes.v1.Notes", name = "GetNote", idempotent = True
        , encodeRequest = encodeGetNoteRequest, decodeResponse = decodeNote }

getNoteRoute : Transcode.Route GetNoteRequest
getNoteRoute =
    Transcode.get "/v1/{name=notes/*}" [ ... parsed template as data ... ]

summarize : Connect.Method SummarizeRequest Summary
summarize = ...
-- no summarizeRoute: the method has no HTTP rule
```

```elm
-- application code

Connect.task config Notes.getNote { name = "notes/42" }
    : Task Connect.Error Note

Transcode.task config Notes.getNote Notes.getNoteRoute { name = "notes/42" }
    : Task Transcode.Error Note

Transcode.task config Notes.summarize ??? -- no route value exists: compile error
```

## 3. Generated types  *(mostly Decided; items marked otherwise)*

### 3.1 Modules

- One Elm module per proto **package**: `notes.v1` → `Notes.V1`.
  *(Decided.)* Per-file modules leak the server's file layout into the
  client and make cross-file references within a package awkward.
- Elm forbids import cycles; proto allows cycles between packages across
  files. The generator detects a package-level cycle and reports it as a
  diagnostic naming the files involved. *(Proposed.)* Alternative: fold
  the strongly-connected packages into one module. Rejected for 1.0
  because it changes module names based on a property users cannot see
  in their protos.
- An optional `module_prefix` option (`Api.Notes.V1`). *(Decided.)*
- The set of files to generate must be closed under package references:
  a generated package may refer only to types in generated packages or
  to supported well-known types, and a reference to any other package is
  a diagnostic naming both sides. The CLI generates the closure of its
  inputs; protoc users list all the files. *(Proposed.)* `google.protobuf`
  is never generated as a package.

### 3.2 Messages

- A record type alias per message. Nested messages are flattened into
  the package module with the outer name as a prefix
  (`Outer.Inner` → `OuterInner`). *(Decided.)*
- Scalars use proto3 zero values directly, not `Maybe`. *(Decided.)* A
  missing JSON field decodes to the zero value, and `null` decodes to
  the zero value, matching proto3 JSON.
- Message-typed fields are `Maybe`. proto3 `optional` fields are
  `Maybe`. *(Decided.)*
- `repeated` → `List`. `map<K, V>` → `Dict K V` with `K` restricted to
  `String` and `Int` as proto allows. *(Decided.)* Note that `int64`
  map keys will become `Dict String V` under §3.4.
- Empty messages (zero fields) become `type alias Foo = {}`. *(Decided.)*
- Recursive messages: `type alias Node = { children : List Node }` is
  illegal in Elm. Wrap with a custom type as protoc-gen-elm does
  (`type Node_ = Node_ Node`). *(Proposed.)* Diagnostic when a recursive
  message is detected, pointing at the wrapper in the output.

### 3.3 Enums

- A custom type per enum. Constructor names are the enum name plus the
  value name with the conventional prefix stripped:
  `enum Status { STATUS_UNSPECIFIED = 0; STATUS_ACTIVE = 1; }` →
  `StatusUnspecified | StatusActive`. *(Decided.)*
- Encoding uses the proto name string. Decoding accepts the name and
  also the integer form, as the JSON spec allows. *(Decided.)*
- **Unknown values.** *(Open.)* Two candidates:
  - (a) decode to the zero-value constructor. Forward-tolerant: a stale
    client survives a server that added a value. Lossy: re-encoding
    sends `UNSPECIFIED` back. This is what the in-house generator does.
  - (b) add an `StatusUnrecognized String` constructor. Faithful and
    forward-tolerant, re-encodes what was received, but every `case` on
    an enum gains a branch nobody wants to think about.
  **Starting position (2026-10-10):** (a), as the best guess; to be
  reviewed against the corpus output. A generator option for (b) stays
  on the table.

### 3.4 Scalars

| proto | Elm | why |
|---|---|---|
| `double`, `float` | `Float` | |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | `Int` | |
| `int64`, `sint64`, `sfixed64`, `uint64`, `fixed64` | `String` | proto3 JSON encodes them as strings; Elm's `Int` loses precision past 2^53 |
| `bool` | `Bool` | |
| `string` | `String` | |
| `bytes` | `String` (base64, as on the wire) | *(Proposed.)* Alternative: `Bytes.Bytes` via elm/bytes with base64 in the runtime. Rejected for 1.0: adds a dependency and a decode step for a field most JSON APIs never use. |

64-bit as `String` is *(Proposed)* with an option `int64=int` for users
who accept the 2^53 limit and want arithmetic. Decoding under the
option accepts both JSON number and string forms.

### 3.5 Well-known types

The runtime provides the Elm types. *(Proposed; each row is open to
argument.)*

| proto | Elm | notes |
|---|---|---|
| `google.protobuf.Timestamp` | `Time.Posix` | RFC 3339 parse/print in the runtime; no third-party date package |
| `google.protobuf.Duration` | `Connect.Duration` (opaque; `seconds : Float` accessor) | Elm has no duration type; `"1.5s"` on the wire |
| `google.protobuf.FieldMask` | `List String` | comma-separated on the wire |
| `google.protobuf.Empty` | `()` | |
| `google.protobuf.Struct`, `Value`, `ListValue` | `Json.Encode.Value` | they *are* JSON |
| `google.protobuf.*Value` wrappers | `Maybe` of the scalar | null or the value on the wire |
| `google.protobuf.Any` | unsupported; diagnostic | needs a type registry; no demand |

The in-house generator mapped `Timestamp` to `String` to avoid a
dependency. With a runtime package required anyway (for the transports),
the parser lives there and `Time.Posix` is the right type.

### 3.6 Oneof

*(Decided; see below.)* Two shapes were considered:

- (a) A custom type with an `Unset` constructor, field typed as the
  custom type: `message : NoteEventKind` where
  `NoteEventKind = NoteEventKindUnset | NoteEventKindCreated Created | ...`.
- (b) A custom type without `Unset`, field typed `Maybe NoteEventKind`.

(b) is more idiomatic Elm and composes with `Maybe.map`. (a) puts every
case in one `case`. The in-house generator uses (a).

**Decided (2026-10-10):** (a). A plain union with the unset case as a
constructor of the union itself, no `Maybe` wrapper.

### 3.7 Naming

- Field names → lowerCamelCase from the proto name (not `json_name`;
  `json_name` only affects the wire). Elm reserved words get a trailing
  underscore (`type` → `type_`). *(Decided.)*
- Collisions after casing (`foo_bar` and `fooBar` in one message) are a
  diagnostic, not a silent rename. *(Decided.)*
- Type names that collide after nested-message flattening are a
  diagnostic. *(Decided.)*

## 4. Method descriptors  *(Proposed)*

```elm
-- in the runtime
type Method req res          -- opaque
method :
    { service : String, name : String, idempotent : Bool
    , encodeRequest : req -> Json.Encode.Value
    , decodeResponse : Json.Decode.Decoder res }
    -> Method req res

type Route req               -- opaque; parsed google.api.http rule
```

- `idempotent` is true when the proto declares
  `option idempotency_level = NO_SIDE_EFFECTS`. Connect uses it to allow
  GET. Transcode ignores it (the HTTP verb comes from the rule).
- A `Route req` is emitted only for methods with an HTTP rule. The
  route is data: verb, path template as parsed segments, body field,
  query-parameter policy. The generator parses the template; the
  runtime only walks the parsed form.
- Additional bindings on a rule are emitted as `getNoteRoute2`, etc.
  *(Open: naming.)*

Open question whether to fuse method and route into one value for the
transcoding case (`Transcode.Call req res`) so call sites pass one
thing. Leaning yes: `Notes.getNoteHttp : Transcode.Call GetNoteRequest Note`.

## 5. Runtime  *(Proposed)*

**Status of the package itself (2026-10-10):** the type layer is being
built against a runtime package from day one, because the JSON pipeline
helpers and the well-known-type codecs would otherwise be inlined into
every generated module. Whether the package is *kept* is an open
question: once it exists, we look at what it contains and what that buys
over inlining, and decide. Nothing below assumes the answer.

### 5.1 Config

```elm
type alias Config =
    { baseUrl : String
    , headers : List Http.Header   -- e.g. Authorization
    , timeout : Maybe Float        -- ms; Connect sends Connect-Timeout-Ms
    }
```

No interceptors, no retry policy, no token refresh. Those are
application concerns and Elm applications already own the `Task`
pipeline where they belong.

### 5.2 Connect

```elm
task : Config -> Method req res -> req -> Task Error res
send : Config -> Method req res -> req -> (Result Error res -> msg) -> Cmd msg

type Error
    = Rpc { code : Code, message : String, details : List Json.Encode.Value }
    | Transport Http.Error      -- network, timeout, non-Connect response

type Code = Canceled | Unknown | InvalidArgument | ... | Unauthenticated
```

- Unary only. POST with `Content-Type: application/json` and
  `Connect-Protocol-Version: 1`. GET with the `message` query encoding
  when the method is idempotent, behind a `Config` flag. *(Open: default
  on or off.)*
- Errors follow the protocol's JSON body; a non-200 without a parsable
  body maps from HTTP status as the spec says.
- Error details are kept as raw JSON values. Typed details need
  `google.protobuf.Any`, which §3.5 excludes.

### 5.3 Transcode

```elm
task : Config -> Method req res -> Route req -> req -> Task Error res

type Error
    = Rpc { code : Int, status : Code, message : String, details : List Json.Encode.Value }
    | Transport Http.Error
```

- Path from the template and the request; body from the `body` field
  (`*`, a named field, or none); remaining request fields as query
  parameters on GET and DELETE, omitting zero values. *(Decided for
  omission: the in-house generator sent them, which was harmless but
  noisy.)*
- Errors decode `google.rpc.Status` (integer `code`, `message`,
  `details`) as grpc-gateway and Envoy emit it.

### 5.4 Why two error types

They are different on the wire (`"code": "not_found"` versus
`"code": 5`) and a server may add transport-specific detail. Mapping
both onto one type would hide the one piece of information that tells a
developer which side of the system misbehaved. The `Code` custom type is
shared.

## 6. Generator  *(Decided unless marked)*

- Rust. One workspace: `elm-connect-gen` (library), `protoc-gen-elm-connect`
  (protoc plugin, reads `CodeGeneratorRequest` on stdin), `elm-connect`
  (standalone CLI on `protox`, compiles `.proto` directly; no protoc).
- Output is produced from a typed Elm AST and a Wadler-style pretty
  printer tuned to match `elm-format`. The conformance suite runs
  `elm-format --validate` on every golden file to keep that true.
  *(Proposed.)* Built so far (`elm-connect-gen::elm`): no Wadler-style
  printer was needed; fixed rules choose one line or several per
  construct, laid out on a port of elm-format's own block model (text,
  tab stops, prefix, indent), and a corpus test holds the output to
  `elm-format --validate` and `elm make`.
- Options (`--elm-connect_opt=` or CLI flags):
  `transports=connect,transcode` (default both; limits emitted
  descriptors and imports), `module_prefix=`, `int64=string|int`,
  `enum_unknown=zero|variant` (if §3.3 lands with an option).
- Diagnostics carry spans from `SourceCodeInfo` and render in the style
  of Elm's compiler. First catalogue: route variable names a field the
  request does not have; route body names a non-message field; map key
  of an unsupported type; package import cycle; name collision after
  casing; `Any` field; recursive message (informational).

## 7. Conformance  *(Decided)*

- `conformance/<case>/input/*.proto` and `expected/*.elm`. A test
  regenerates and diffs; a second test runs `elm make` over all expected
  output against the runtime at the repo's version; a third runs
  `elm-format --validate`.
- Route fixtures: a JSON file of `(template, request) → (path, query,
  body)` expectations, checked against the generator's parser. The same
  file is intended to be consumable by a server-side implementation so
  the two ends can prove agreement without sharing code.

## 8. Compatibility and versioning

- Elm 0.19.2 is the development target; 0.19.1 is checked in CI.
  *(Decided.)* Decoders for messages with more than eight fields use the
  runtime's pipeline helpers rather than `map8` chunking.
- Generated code states the runtime major it needs in a header comment;
  a mismatch surfaces as an Elm compile error against the runtime's
  types. Generator major == runtime major. *(Decided.)*
- Elm package versions follow Elm's enforced semver. Crate versions
  follow Cargo's.

## 9. Open questions, collected

1. Enum unknown values (§3.3): starting with zero-value; review pending.
2. Whether the runtime package is kept (§5) once its contents exist.
3. Fuse method and route for transcoding (§4).
4. Connect GET for idempotent methods: default on or off (§5.2).
5. Naming of additional-binding routes (§4).
6. `bytes` as `String` versus `Bytes.Bytes` (§3.4).

## 10. Out of scope but recorded

Streaming (both transports), binary protobuf, gRPC-web, proto2, `Any`,
interceptors, retries, server generation. Each has a sentence above
saying why; none is a permanent no.
