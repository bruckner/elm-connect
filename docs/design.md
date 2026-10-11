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
  Built as `generate::import_cycle` (`packages_cycle` case): it names
  each package with its files and points at a reference along the
  cycle in each.
- An optional `module_prefix` option (`Api.Notes.V1`). *(Decided.)*
- The set of files to generate must be closed under package references:
  a generated package may refer only to types in generated packages or
  to supported well-known types, and a reference to any other package is
  a diagnostic naming both sides. The CLI generates the closure of its
  inputs; protoc users list all the files. *(Proposed.)* `google.protobuf`
  is never generated as a package.
  Built as `generate::not_generated` (`packages_not_generated` case),
  which points at the referring field and names the file to add. A
  reference to another generated package is qualified with its module
  (`Users.V1.User`, `Users.V1.RoleUnspecified`), which is imported
  plainly, without an alias or an exposing list (`packages` case).

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
  Built: `string` and 64-bit integer keys give `Dict String V`, 32-bit
  integer keys `Dict Int V`. JSON object keys are strings, so integer
  keys are read from their decimal strings (`Connect.Json.intDict`, which
  fails on any other key) and written with `String.fromInt`. A `bool`
  key has no `Dict` (Elm's `Bool` is not `comparable`) and is the
  `types::map_key` diagnostic; mapping it to `Dict String V` with keys
  `"true"` and `"false"` would work but hide the proto type, and `bool`
  map keys are rare enough that asking for a `string` key costs little.
  An absent or `null` map decodes as `Dict.empty`.
- Empty messages (zero fields) become `type alias Foo = {}`. *(Decided.)*
- Recursive messages: `type alias Node = { children : List Node }` is
  illegal in Elm. Wrap with a custom type as protoc-gen-elm does.
  *(Decided, 2026-10-10.)* The shape:

  ```elm
  type alias Node =
      { label : String
      , children : List Node_
      }

  type Node_
      = Node_ Node
  ```

  - A message is recursive when it reaches itself through fields
    (singular, optional, repeated or map values), directly or through
    other messages. Each recursive message gets the wrapper `<Name>_`,
    whose one constructor has the same name, with `encode<Name>_` and
    `decode<Name>_`. Generated type names never contain an underscore
    otherwise, so the name is always free.
  - Exactly the fields that close a cycle hold the wrapper: a field
    whose message type reaches back to the message holding it. In a
    mutual pair (`Person.employer : Maybe Company_`,
    `Company.staff : List Person_`) both sides are wrapped, so the rule
    needs no choice of where to cut. A message off the cycle that refers
    to a recursive one (`Forest.trees : List Node`) holds the plain
    record.
  - The wrapper's decoder reads the message through
    `Json.Decode.lazy`, which keeps the decoders of a cycle from being
    defined directly in terms of each other.
  - A cycle through a oneof member needs no wrapper (the oneof's custom
    type already breaks the alias cycle), but its decoders still refer
    to each other, so the member that closes the cycle decodes through
    `Json.Decode.lazy`.
  - No diagnostic: the wrapper is in the generated output, where the
    Elm compiler points at it the first time a record is built without
    it. A note at generation time would repeat what the types already
    say.

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
  Built as (a): the `enums` conformance case shows the output to
  review.
- Generated shape *(Proposed; built)*: the encoder is a `case` with one
  `Json.Encode.string "NAME"` branch per constructor, so the compiler
  checks it is total. The decoder is one call to the runtime's
  `Connect.Json.enum`, given the zero constructor and a
  `( "NAME", number, Constructor )` row per value. Inlined, the decoder
  would need two `case` expressions (one over names, one over numbers)
  with a fallback branch each, about three times the lines per value
  and nothing a reader learns from them.
- Aliases (`allow_alias`): each value name is its own constructor and
  encodes as its own name. A number decodes to the first value declared
  with it, so `URGENT = 2` after `HIGH = 2` decodes from `2` as `HIGH`
  but from `"URGENT"` as `URGENT`.
- Values are in declaration order, the zero value first, whatever their
  numbers.

### 3.4 Scalars

| proto | Elm | why |
|---|---|---|
| `double`, `float` | `Float` | |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | `Int` | |
| `int64`, `sint64`, `sfixed64`, `uint64`, `fixed64` | `String`, or `Int` under `int64=int` | proto3 JSON encodes them as strings; Elm's `Int` loses precision past 2^53 *(Decided; see below)* |
| `bool` | `Bool` | |
| `string` | `String` | |
| `bytes` | `String` (base64, as on the wire) | *(Decided; see below.)* |

Encoders emit every field, default values included, which proto3 JSON
allows. *(Current rule, not yet reviewed.)* A field with presence
(`Maybe`) encodes `Nothing` as `null`, which parsers read as absent.

Decoders accept every form proto3 JSON requires a parser to accept, not
just the form encoders write. *(Proposed; built.)*

- 32-bit integers as numbers or strings, in exponent notation too
  (`42`, `"42"`, `1e2`, `"1e2"`), through `Connect.Json.int32` (`int32`,
  `sint32`, `sfixed32`) and `Connect.Json.uint32` (`uint32`, `fixed32`).
  A fractional value fails, and so does one outside the proto type's
  range: −2^31 to 2^31 − 1 signed, 0 to 2^32 − 1 unsigned. *(Decided.)*
- Floats as numbers, numeric strings, and `"NaN"`, `"Infinity"`,
  `"-Infinity"`; 64-bit integers as strings or numbers. A 64-bit string
  in exponent notation (`"1e2"`) is not accepted yet.
- A field under its JSON name or under its proto field name. The
  generated step names the field once when the two are equal and twice
  when they differ, JSON name first:

  ```elm
  |> Connect.Json.field "title" "" Json.Decode.string
  |> Connect.Json.fieldEither "displayName" "display_name" "" Json.Decode.string
  ```

  When an object has both keys, the JSON name wins. The two names are
  equal only for one-word fields without an explicit `json_name`, so in
  practice most multi-word fields use `fieldEither`. A list of names
  (`field [ "title" ]`) was the alternative; it puts brackets on every
  line to serve the minority case, and two names are the most there can
  be.
- One step serves every cardinality. Its second argument is the value
  an absent or `null` field reads as, so a field with presence reads
  `field "author" Nothing (Json.Decode.map Just decodeAuthor)` and a
  repeated one `field "tags" [] (Json.Decode.list Json.Decode.string)`.
  Separate `optional` and `list` steps would read a little shorter but
  double the step functions (each needs a two-name form too) and hide
  the zero value the reader otherwise sees.

**Bytes** *(Decided.)* A `bytes` field is a `String` holding the base64
text exactly as received; nothing normalises it. `Connect.Json.bytes`
validates it at decode time, with no new dependency: the standard
alphabet (`A`–`Z`, `a`–`z`, `0`–`9`, `+`, `/`) or the URL-safe one (`-`,
`_`), not both in one string, with or without `=` padding. It fails on
any other character, on a length no base64 has (after stripping the
padding, length mod 4 is 1), and on padding that does not complete the
last group to four characters. The encoder writes the string unchecked.
A `Bytes.Bytes`-typed option and `Connect.Bytes` helpers (base64 to and
from elm/bytes) would live in a separate optional package, such as
`elm-connect-bytes`, depending on elm/bytes, so the runtime keeps its
dependencies; not prioritised.

**64-bit integers** *(Decided.)* The rule:

- By default the five 64-bit kinds are `String`, the decimal integer,
  exact for every value. Their zero value is `"0"`, which re-encodes as
  a valid int64. The runtime's `Connect.Int64` converts (`toInt`, which
  gives `Nothing` outside ±(2^53 − 1), and `fromInt`).
- The option `int64=int` makes them `Int`. The decoder
  (`Connect.Json.int64AsInt`) accepts a JSON number or a decimal string
  and fails on a non-integer or a value outside ±(2^53 − 1), where Elm's
  `Int` stops being exact; it never rounds silently. The encoder
  (`Connect.Json.encodeInt64AsInt`) writes the decimal string, proto3
  JSON's canonical form. The zero value is `0`.
- The standard field option `jstype` overrides the option per field:
  `[jstype = JS_NUMBER]` makes the field `Int` (range-checked) under
  `int64=string`, `[jstype = JS_STRING]` keeps it `String` under
  `int64=int`, and `JS_NORMAL` defers to the option. It applies to
  singular, `optional` and repeated fields and oneof members; protobuf
  allows it only on 64-bit integer fields, and the generator ignores it
  anywhere else.
- The option reaches every 64-bit value without a `jstype`: map values
  and the `Int64Value`/`UInt64Value` wrappers too. Map **keys** stay
  `String` under either setting: they are strings on the wire, and a
  `Dict String V` keyed by decimal text needs no range check.
- The unsigned kinds share the signed range check (a negative `uint64`
  decodes); the string form never checked sign either.

### 3.5 Well-known types

The runtime provides the Elm types. *(Proposed; each row is open to
argument.)*

| proto | Elm | notes |
|---|---|---|
| `google.protobuf.Timestamp` | `Time.Posix` | RFC 3339 parse/print in the runtime; no third-party date package |
| `google.protobuf.Duration` | `Connect.Duration` (opaque; `seconds : Float` accessor) | Elm has no duration type; `"1.5s"` on the wire |
| `google.protobuf.FieldMask` | `List String` | comma-separated on the wire |
| `google.protobuf.Empty` | `()`, without presence | *(Decided; see below)* |
| `google.protobuf.Struct`, `Value`, `ListValue` | `Json.Encode.Value` | they *are* JSON |
| `google.protobuf.*Value` wrappers | `Maybe` of the scalar | null or the value on the wire |
| `google.protobuf.Any` | unsupported; diagnostic | needs a type registry; no demand |

The in-house generator mapped `Timestamp` to `String` to avoid a
dependency. With a runtime package required anyway (for the transports),
the parser lives there and `Time.Posix` is the right type.

Built as proposed, with these details *(each Proposed)*:

- A field of `Timestamp`, `Duration` or `FieldMask` is a message
  field, so a singular one is a `Maybe` (§3.2): `Maybe Time.Posix`,
  `Maybe Duration`, `Maybe (List String)`.
- `Empty` carries nothing, presence included. *(Decided.)* A singular
  field of it, `optional` or not, is `()`: encoded as `{}` always,
  decoded as `()` whether the key holds an object, holds `null` or is
  absent. Repeated it is `List ()`, as a map value `Dict K ()`. A oneof
  member of it is a constructor without an argument (`ActionClear`, not
  `ActionClear ()`), encoded as `{"clear": {}}` and decoded from the
  member's key holding an object; a member present as `null` reads as
  unset, as for any member (`Connect.Json.emptyMember`). Whether such a field was sent is lost
  (§3.8).
- A wrapper is `Maybe` of its scalar directly (`Maybe Int`, never
  `Maybe (Maybe Int)`); repeated or as a map value it is the bare scalar.
- `Struct`, `Value` and `ListValue` fields are `Json.Encode.Value`
  without `Maybe`: an absent field reads as `null`, and the value is
  passed through as received (`Json.Decode.value`, written back as is).
  A `Value` member of a oneof that arrives as `null` reads as unset,
  like any other member, although proto3 JSON reads it as `NullValue`.
- `Timestamp` (`Connect.Timestamp`, elm/time): RFC 3339 with a fraction
  of up to nine digits and `Z` or an offset, which is applied; years 1
  to 9999. `Time.Posix` counts milliseconds, so finer digits are dropped
  (toward the past) and a timestamp prints with no fraction or three
  digits; protobuf's six and nine never arise. A leap second
  (`23:59:60`), which proto3 JSON parsers must accept, is read as
  `23:59:59` with its fraction.
- `Duration` (`Connect.Duration`, opaque): held exactly, as seconds and
  nanoseconds like protobuf, rather than as a `Float` of seconds. The
  `Float` views (`fromSeconds`, `seconds`) are exact to the nanosecond
  only below 2^53 ns (about 104 days); `fromMilliseconds` and
  `milliseconds` are exact. Printed with 0, 3, 6 or 9 fractional
  digits, the fewest that keep every nanosecond, as protobuf does;
  `-0s` reads as zero and prints `0s`. The range is protobuf's,
  ±315,576,000,000 s.
- `FieldMask`: the Elm list holds paths with proto field names
  (`"author.email_address"`); the wire form joins them with commas and
  writes each field name in lowerCamelCase, as proto3 JSON requires.
- `Any` is the `types::any` diagnostic (`any_field` case).

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

Built *(Proposed in its details)*:

- The record holds the oneof's field where its first member was
  declared, so the record constructor's argument order follows the
  proto.
- The oneof's encoder gives the set member as a one-element list of
  `( jsonName, value )`, or `[]` when unset, and the message's encoder
  appends it to its fields: `Json.Encode.object ([ ... ] ++
  encodeNoteEventKind value.kind)`.
- The oneof's decoder is `Json.Decode.oneOf` over a
  `Connect.Json.member` per member (`memberEither` when the JSON and
  proto names differ), then `Json.Decode.succeed NoteEventKindUnset`.
  The message's decoder reads it with a `Connect.Json.oneof` step. A
  member present as `null` reads as unset, and when several members are
  present the first declared wins.
- A member of `google.protobuf.Empty` is a constructor without an
  argument (`NoteEventKindArchived`), encoded as `{"archived": {}}` and
  decoded by `Connect.Json.emptyMember`, which reads the key as set when
  it holds an object; `null` reads as unset, as for any member.
  *(Decided; §3.5.)*
- **Known weakness:** a member that is present but malformed
  (`{"title": 1}` for a string member) also reads as unset, because
  `Json.Decode.oneOf` moves on to the next alternative and the last one
  always succeeds. A plain field with a malformed value fails the whole
  message, so a oneof is the one place malformed input passes silently.
  A fix that keeps `Json.Decode.oneOf` ends the list with a decoder that
  succeeds only when no member key is present, instead of
  `Json.Decode.succeed`. *(Open.)*

### 3.7 Naming

- Field names → lowerCamelCase from the proto name (not `json_name`;
  `json_name` only affects the wire). Elm reserved words get a trailing
  underscore (`type` → `type_`). *(Decided.)*
- Collisions after casing (`foo_bar` and `fooBar` in one message) are a
  diagnostic, not a silent rename. *(Decided.)*
- Type names that collide after nested-message flattening are a
  diagnostic. *(Decided.)*

Built, as the `naming` and `naming_collision` cases show:

- The reserved words are the fourteen of Elm 0.19.2's parser (`if`,
  `then`, `else`, `case`, `of`, `let`, `in`, `type`, `module`, `where`,
  `import`, `exposing`, `as`, `port`). `alias` and `infix` are legal
  field names and stay as they are. Oneof names follow the field rule
  (`oneof case` → `case_`); member constructors are PascalCase, so a
  reserved word needs no escape there (`TagCaseThen`).
- Casing keeps digits and capitals as written: `http_url` → `httpUrl`,
  `v2_count` → `v2Count`; enum value `SHAPE_2D` → `Shape2d`,
  `SHAPE_V3_MESH` → `ShapeV3Mesh`. A value without the conventional
  prefix gains the enum's name (`CUBE` → `ShapeCube`); the prefix of a
  multi-word enum is matched word by word (`HTTP_METHOD_GET` →
  `HttpMethodGet`).
- Two plain fields cannot collide in practice: protoc and protox reject
  a message whose fields' JSON names clash, and the Elm name is the
  default JSON name. The collision a user meets is a field and a oneof
  (`display_name` and `oneof displayName`), which
  `naming::field_collision` reports with both sites.

### 3.8 Dead ends

Valid proto constructs whose Elm form drops a distinction the proto
makes, or that the generator refuses with a diagnostic. This is a
record of fact; the policy for them is not designed yet.

Dropped distinctions:

- **Presence of an `Empty` field.** A singular `google.protobuf.Empty`
  field is `()` (§3.5), so a message that sent `{}` and one that left
  the field out decode alike, and the encoder always sends `{}`.

Refused (each a diagnostic, pinned in the conformance corpus where a
case names it):

- **Names that collide in Elm**: two types after nested-message
  flattening (`naming::type_collision`), two constructors in one module,
  such as enum values or oneof members (`naming::constructor_collision`),
  and a field and a oneof of one message (`naming::field_collision`,
  `naming_collision` case).
- **Names with no Elm form**: a package segment, type or field whose
  converted name is not a valid Elm identifier (`naming::invalid_module`,
  `naming::invalid_type`, `naming::invalid_field`), and a file without a
  package declaration (`naming::invalid_module`).
- **`bool` map keys** (`types::map_key`, `map_bool_key` case): Elm's
  `Bool` is not `comparable`.
- **`google.protobuf.Any` fields** (`types::any`, `any_field` case), and
  any other `google.protobuf` type without a mapping
  (`types::unsupported_well_known`).
- **Package import cycles** (`generate::import_cycle`, `packages_cycle`
  case): Elm forbids import cycles.
- **A generate set not closed under package references**
  (`generate::not_generated`, `packages_not_generated` case).

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
  Built so far: `int64` (§3.4; `--elm-connect_opt=int64=int`, or
  `elm-connect gen --int64 int`). The plugin parameter is
  comma-separated `key=value` pairs; an unknown key or value, or a key
  given twice, is an error. A conformance case sets options with an
  `options.txt` holding that parameter.
- Diagnostics carry spans from `SourceCodeInfo` and render in the style
  of Elm's compiler. First catalogue: route variable names a field the
  request does not have; route body names a non-message field; map key
  of an unsupported type (built: `types::map_key`, for `bool`); package
  import cycle; name collision after casing; `Any` field. A recursive
  message was listed as an informational diagnostic; it is dropped,
  since the wrapper type in the output says the same (§3.2).

## 7. Conformance  *(Decided)*

The harness is *(Decided and built)*: `conformance/cases/` and the
`conformance` test of `elm-connect-gen`, described in
`conformance/README.md`.

- `conformance/cases/<case>/input/*.proto` and `expected/*.elm`. A test
  regenerates and diffs; a second test runs `elm make` over all expected
  output against the runtime at the repo's version; a third runs
  `elm-format --validate`.
- Route fixtures: a JSON file of `(template, request) → (path, query,
  body)` expectations, checked against the generator's parser. The same
  file is intended to be consumable by a server-side implementation so
  the two ends can prove agreement without sharing code.

## 8. Compatibility and versioning

- Elm 0.19.2 is the development target; 0.19.0 and 0.19.1 are checked
  in CI. *(Decided.)* Built: a CI job per earlier release installs the
  official Linux binary (checksum pinned) and runs
  `conformance/compile-with.sh`, which compiles the runtime package (with
  `--docs`) and every case's expected output against a copy of the
  harness set to that release. Nothing the 0.19.2 output needs is refused
  by 0.19.0 or 0.19.1 so far. Decoders for messages with more than eight
  fields use the runtime's pipeline helpers rather than `map8` chunking.
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

## 10. Out of scope but recorded

Streaming (both transports), binary protobuf, gRPC-web, proto2, `Any`,
interceptors, retries, server generation. Each has a sentence above
saying why; none is a permanent no.
