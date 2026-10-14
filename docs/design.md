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
- Generated code is transport-neutral: a call is data, and the
  transport is chosen in the config it is sent with (§2). Every method
  can be called over either transport; a method without a
  `google.api.http` rule goes over the implicit route (§4).
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

## 2. The layering  *(Decided; reshaped 2026-10-13)*

Generated code carries no transport. Three layers, the first two data:

1. **Types and JSON codecs.** Records for messages, custom types for
   enums and oneofs, `encode*` and `decode*` for each, in the package's
   module (`Notes.V1`). Identical under either transport because both
   use proto3 JSON.
2. **Calls are data.** One module per service (`Notes.V1.NotesService`),
   with one function per method that, applied to a request, gives an
   `Rpc.Call req res`: the service and method names, idempotency, the
   request and response codecs, and the method's `google.api.http`
   bindings, all as data (§4). Nothing in a call picks a transport.
3. **Config is data, and one runtime module sends.** An `Rpc.Config`
   says where and how: the transport and its options, base URL,
   headers, timeout, credentials and retry, with no function in it
   (§5.1). The runtime's one module, `Rpc`, takes a config and a call
   and sends it as a `Task` or a `Cmd`, or gives the HTTP request it
   stands for and reads the answer without sending anything (§5.2).

This is the shape connect-es arrived at in v2 (service descriptors from
`protoc-gen-es`, transport in the runtime) and the shape anmolitor's
protoc-gen-elm uses (service module as data, elm-grpc as transport). It
dissolves the "one plugin or two" question: one plugin emits layers 1
and 2; the transport choice is made in the config, which an
application builds once or per call.

Every method can be called over either transport. A method without an
HTTP rule goes over the implicit route the transcoders serve (§4), so
whether a method has a rule is not in its type. *(Decided, 2026-10-13.)*
The first shape built made it one: a `Connect.Method` per method and a
`Transcode.Call` per binding, so a method without a rule could not be
passed to the transcoding transport at all. That split every helper an
application wrote around calls into two, to guard against a server
configuration the generator cannot see; `unbound_methods=error` (§6)
keeps the guard for the servers that need it.

### 2.1 Before and after

A small service, as a proto:

```proto
package notes.v1;

service NotesService {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option idempotency_level = NO_SIDE_EFFECTS;
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

Under this design the package module `Notes.V1` holds the types and
codecs, and the service gets a module of its own (§4):

```elm
-- Notes/V1/NotesService.elm (generated)


module Notes.V1.NotesService exposing (..)

import Notes.V1
import Proto.Descriptor
import Rpc


getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Rpc.call
        { request = Notes.V1.messageGetNoteRequest
        , response = Notes.V1.messageNote
        , descriptor =
            { service = "notes.v1.NotesService"
            , name = "GetNote"
            , idempotent = True
            , input = "notes.v1.GetNoteRequest"
            , output = "notes.v1.Note"
            , bindings =
                [ Proto.Descriptor.binding
                    { method = "GET"
                    , path =
                        [ Proto.Descriptor.literal "v1"
                        , Proto.Descriptor.variable [ "name" ] [ Proto.Descriptor.literal "notes", Proto.Descriptor.wildcard ]
                        ]
                    , customVerb = Nothing
                    , body = Proto.Descriptor.noBody
                    , responseBody = Nothing
                    , query = []
                    }
                ]
            }
        }


summarize : Notes.V1.SummarizeRequest -> Rpc.Call Notes.V1.SummarizeRequest Notes.V1.Summary
summarize =
    Rpc.call { …, descriptor = { …, bindings = [] } }   -- no rule: the implicit route
```

Application code applies a method to its request and sends the call
with a config:

```elm
import Notes.V1.NotesService as Notes
import Rpc


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


-- POST https://api.example.com/notes.v1.NotesService/GetNote
Notes.getNote { name = "notes/42" } |> Rpc.task config
    : Task Rpc.Error Note

-- GET https://api.example.com/v1/notes/42
Notes.getNote { name = "notes/42" } |> Rpc.task { config | transport = Rpc.Transcode }

-- POST https://api.example.com/notes.v1.NotesService/Summarize, the implicit route
Notes.summarize request |> Rpc.task { config | transport = Rpc.Transcode }
```

An application usually sends every call through one function of its
own, which derives the config from its state:

```elm
rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call
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
  keys are read from their decimal strings (`Proto.Json.intDict`, which
  fails on any other key) and written with `String.fromInt`.
  An absent or `null` map decodes as `Dict.empty`.
- `map<bool, V>` → `List ( Bool, V )`. *(Decided.)* The Elm form is an
  association list because `Bool` is not `comparable`; a map has at
  most two entries. The encoder (`Proto.Json.encodeBoolMap`) writes a
  JSON object keyed `"true"` and `"false"`; the decoder
  (`Proto.Json.boolMap`) reads one, fails on any key but exactly
  `"true"` or `"false"`, and gives the pairs in the object's key order.
  An absent or `null` map decodes as `[]`. A `bool` key was first a
  diagnostic, and `Dict String V` keyed by `"true"`/`"false"` was
  considered; both hid the proto type.
- Empty messages (zero fields) become `type alias Foo = {}`. *(Decided.)*
- Every message gets `defaultFoo`, so callers write
  `{ defaultFoo | title = "x" }` and
  `Maybe.withDefault defaultFoo.stars msg.stars` without knowing the
  proto default. *(Decided.)* `defaultFoo : Foo` holds every field at
  its proto3 default, the value it decodes to when absent: `0`, `0.0`,
  `False`, `""`, `"0"` for a 64-bit integer held as a `String` (`0` as
  an `Int`), an enum's zero constructor, `Nothing`, `[]`, `Dict.empty`,
  `()` for `Empty`, `Json.Encode.null` for `Value`, and each oneof's
  unset constructor. The name is the naming layer's (`default` + the
  type name), in the value namespace with the encoders and decoders,
  where it cannot collide (§3.7). The generated module gains a
  `-- DEFAULTS` section between its types and its encoders. A recursive
  message's default needs nothing special: a field that closes a cycle
  is a `Maybe`, `List` or `Dict` of the wrapper, so its default is
  empty, and the wrapper has no default of its own. Generated getters
  (`getStars : Note -> Int`, unwrapping a `Maybe` to its proto default)
  were the alternative; rejected, since the defaults give the same
  without a function per field.
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
- **Unknown values.** *(Decided, 2026-10-11.)* An unknown **number**
  decodes to the zero-value constructor: forward-tolerant, so a stale
  client survives a server that added a value, and lossy, since
  re-encoding sends the zero value's name back (§3.8). An unknown
  **name** fails the decode, as protobuf-go's protojson does:
  `Expecting a value of enum "Priority", but got "WHATEVER"`, the enum
  named as declared within its package (`Outer.Inner.Kind` when
  nested). A name is matched exactly. An `<Enum>Unrecognized Int`
  constructor, faithful and re-encoding what was received, is deferred
  until users ask for it: every `case` on an enum would gain a branch
  nobody wants to think about.
- Generated shape *(Decided)*: the encoder is a `case` with one
  `Json.Encode.string "NAME"` branch per constructor, so the compiler
  checks it is total. The decoder is one call to the runtime's
  `Proto.Json.enum`, given the enum's proto name, the zero
  constructor and a `( "NAME", number, Constructor )` row per value
  name. Inlined, the decoder would need two `case` expressions (one over
  names, one over numbers) with a fallback branch each, about three
  times the lines per value and nothing a reader learns from them.
- Aliases (`allow_alias`) collapse. *(Decided, 2026-10-11.)* The values
  sharing a number are one constructor, named for the first declared
  value with that number, which the encoder writes. The decoder accepts
  every alias name and the number: each alias is a row of its own,
  after its constructor's, so `URGENT = 2` after `HIGH = 2` adds
  `( "URGENT", 2, PriorityHigh )`. An alias claims no constructor name,
  so it cannot collide with one (§3.7). A constructor per name was the
  first build; it made `HIGH` and `URGENT` distinct in Elm when they
  are one value on the wire and in every other protobuf runtime, and a
  number could decode to only one of them.
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
  (`42`, `"42"`, `1e2`, `"1e2"`), through `Proto.Json.int32` (`int32`,
  `sint32`, `sfixed32`) and `Proto.Json.uint32` (`uint32`, `fixed32`).
  A fractional value fails, and so does one outside the proto type's
  range: −2^31 to 2^31 − 1 signed, 0 to 2^32 − 1 unsigned. *(Decided.)*
- Floats as numbers, numeric strings, and `"NaN"`, `"Infinity"`,
  `"-Infinity"`; 64-bit integers as strings or numbers, in exponent
  notation too (`"1e3"`, `"1.5e3"`, `1E2`, `"-2e0"`). *(Decided.)* The
  `String` form (`Proto.Json.int64`) is always the canonical decimal
  string (`"1000"`, `"1500"`, `"100"`, `"-2"`; `"007"` reads as `"7"`),
  found by moving the decimal point as text, never through a `Float`,
  so a string past 2^53 keeps every digit. A value that is not an
  integer (`"1.5e0"`) fails, and so does one of more than 20 digits,
  past every 64-bit integer, which also bounds the text an exponent can
  ask for. `Proto.Json.int64AsInt` reads the same forms within its
  range. A 64-bit map key is kept as the text received (§3.2).
- A field under its JSON name or under its proto field name. The
  generated step names the field once when the two are equal and twice
  when they differ, JSON name first:

  ```elm
  |> Proto.Json.field "title" "" Json.Decode.string
  |> Proto.Json.fieldEither "displayName" "display_name" "" Json.Decode.string
  ```

  An object holding both keys fails, naming them (`Expecting
  "displayName" or "display_name", but got both`), even when one of them
  is `null`: protobuf's own parsers (protobuf-go's protojson) reject it
  as a duplicate field. *(Decided.)* The same holds for every two-name
  helper (`memberEither`, `emptyMemberEither`, `valueMemberEither`). The
  two names are equal only for one-word fields without an explicit
  `json_name`, so in practice most multi-word fields use `fieldEither`. A list of names
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
text exactly as received; nothing normalises it. `Proto.Json.bytes`
validates it at decode time, with no new dependency: the standard
alphabet (`A`–`Z`, `a`–`z`, `0`–`9`, `+`, `/`) or the URL-safe one (`-`,
`_`), not both in one string, with or without `=` padding. It fails on
any other character, on a length no base64 has (after stripping the
padding, length mod 4 is 1), and on padding that does not complete the
last group to four characters. The encoder writes the string unchecked.
A `Bytes.Bytes`-typed option and `Proto.Bytes` helpers (base64 to and
from elm/bytes) would live in a separate optional package, such as
`elm-connect-bytes`, depending on elm/bytes, so the runtime keeps its
dependencies; not prioritised.

**64-bit integers** *(Decided.)* The rule:

- By default the five 64-bit kinds are `String`, the decimal integer,
  exact for every value. Their zero value is `"0"`, which re-encodes as
  a valid int64. The runtime's `Proto.Int64` converts (`toInt`, which
  gives `Nothing` outside ±(2^53 − 1), and `fromInt`).
- The option `int64=int` makes them `Int`. The decoder
  (`Proto.Json.int64AsInt`) accepts a JSON number or a decimal string
  and fails on a non-integer or a value outside ±(2^53 − 1), where Elm's
  `Int` stops being exact; it never rounds silently. The encoder
  (`Proto.Json.encodeInt64AsInt`) writes the decimal string, proto3
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
| `google.protobuf.Duration` | `Proto.Duration` (opaque; `seconds : Float` accessor) | Elm has no duration type; `"1.5s"` on the wire |
| `google.protobuf.FieldMask` | `List String` | comma-separated on the wire |
| `google.protobuf.Empty` | `()`, without presence | *(Decided; see below)* |
| `google.protobuf.Struct` | `Dict String Json.Encode.Value` | a JSON object; *(Decided; see below)* |
| `google.protobuf.ListValue` | `List Json.Encode.Value` | a JSON array; *(Decided; see below)* |
| `google.protobuf.Value` | `Json.Encode.Value` | it *is* JSON |
| `google.protobuf.*Value` wrappers | `Maybe` of the scalar | null or the value on the wire |
| `google.protobuf.Any` | in scope; a diagnostic until designed | needs the descriptor layer (§9) |

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
  unset, as for any member (`Proto.Json.emptyMember`). Whether such a field was sent is lost
  (§3.8).
- A wrapper is `Maybe` of its scalar directly (`Maybe Int`, never
  `Maybe (Maybe Int)`); repeated or as a map value it is the bare scalar.
- `Struct` is `Dict String Json.Encode.Value` and `ListValue` is
  `List Json.Encode.Value`. *(Decided.)* They are messages, so presence
  is kept: a singular field of either is a `Maybe` like any message
  field, and an absent or `null` field (`Nothing`) is distinct from an
  empty object or array (`Just Dict.empty`, `Just []`). Their decoders
  (`Proto.Json.struct`, `Proto.Json.listValue`) check the JSON shape
  and fail on anything but an object or an array; their encoders are
  `Proto.Json.encodeStruct` and `encodeListValue`. The members and
  elements are passed through as received.
- `Value` fields are `Json.Encode.Value` without `Maybe`: an absent
  field reads as `null`, and the value is passed through as received
  (`Json.Decode.value`, written back as is). A `Value` member of a oneof
  that arrives as `null` is set and holds `null`, as protojson reads it,
  unlike any other member (§3.6).
- `Timestamp` (`Proto.Timestamp`, elm/time): RFC 3339 with a fraction
  of up to nine digits and `Z` or an offset, which is applied; years 1
  to 9999. `Time.Posix` counts milliseconds, so finer digits are
  truncated (toward the past, never rounded up; §3.8) and a timestamp prints with no fraction or three
  digits; protobuf's six and nine never arise. A leap second
  (`23:59:60`), which proto3 JSON parsers must accept, is read as
  `23:59:59` with its fraction.
- `Duration` (`Proto.Duration`, opaque): held exactly, as seconds and
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
- `Any` is in scope for the library *(Decided, 2026-10-11)*, its
  design pending the descriptor layer (§9); until then a field of it is
  the `types::any` diagnostic (`any_field` case).

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
- The oneof's decoder is `Proto.Json.members "kind"
  NoteEventKindUnset [ ... ]`, given the oneof's proto name (for error
  messages), its unset constructor and a `Proto.Json.member` per
  member (`memberEither` when the JSON and proto names differ). The
  message's decoder reads it with a `Proto.Json.oneof` step.
- Decoding is strict, as protobuf-go's protojson is. *(Decided.)*
  - A member is present when its key holds a value other than `null`;
    a member present as `null` reads as absent. The exception, as in
    protojson, is a member of `google.protobuf.Value`: `null` is a
    value of it, so a member present as `null` is set and holds the
    JSON `null` (`Proto.Json.valueMember`).
  - No member present decodes as the unset constructor.
  - A member present with a value its decoder rejects (`{"title": 1}`
    for a string member) fails the message, as a malformed plain field
    does; it never reads as unset.
  - More than one member present fails, naming the keys found, in
    declaration order: `Expecting at most one member of oneof "kind",
    but got "created" and "titleChanged"`. Members present as `null`
    do not count (a `Value` member does).
  - A member written under both its JSON name and its proto name fails
    as a duplicate (§3.4).
- A member of `google.protobuf.Empty` is a constructor without an
  argument (`NoteEventKindArchived`), encoded as `{"archived": {}}` and
  decoded by `Proto.Json.emptyMember`, which reads the key as set when
  it holds an object; `null` reads as unset, as for any member, and any
  other value fails. *(Decided; §3.5.)*
- `Json.Decode.oneOf` over the members, ending in
  `Json.Decode.succeed` the unset constructor, was the first build. It
  let a malformed member read as unset and took the first of several
  members, and it cannot see two members at once, so it gave way to
  `members`.

### 3.7 Naming

- Field names → lowerCamelCase from the proto name (not `json_name`;
  `json_name` only affects the wire). Elm reserved words get a trailing
  underscore (`type` → `type_`). *(Decided.)*
- Collisions after casing (`foo_bar` and `fooBar` in one message) are a
  diagnostic, not a silent rename. *(Decided.)*
- Nested messages and enums are flattened into their package's module,
  prefixed with the names of the messages enclosing them:
  `Outer.Inner` → `OuterInner`, `Outer.Inner.Kind` → `OuterInnerKind`.
  *(Decided, 2026-10-11.)* A submodule per message (`Pkg.Outer.Inner`)
  was considered and rejected: a parent referring to its own nested
  type would be an Elm module cycle.
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
- An enum claims one constructor per number: an alias (§3.3) has no
  constructor, so its would-be name (`PRIORITY_LOW` beside `LOW`, both
  `PriorityLow`) is not a collision.
- Top-level values are a prefix and a type name: `encodeFoo`,
  `decodeFoo`, `defaultFoo`, `messageFoo` and `enumFoo` (§3.9). Type
  names are unique in a module and start with an uppercase letter, and
  no prefix is another's, so these never collide. The one other,
  `registry`, is all lowercase, so it is none of them. A suffix scheme was
  rejected for the typed records: `encodeFooMessage` would be both the
  encoder of `FooMessage` and the record of `EncodeFoo`.
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

- **Sub-millisecond timestamp precision.** A `Timestamp` is
  `Time.Posix`, which counts milliseconds (§3.5): a fraction of up to
  nine digits is read and truncated, and the finer digits are not
  re-emitted. An option mapping `Timestamp` to an exact seconds and
  nanoseconds type, as `Duration` is held, could cover the rare case it
  matters; not built.
- **Unknown enum numbers** read as the zero value (§3.3), so a value
  the client does not know is indistinguishable from the zero value,
  and re-encoding sends the zero value's name.
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
- **Names with no Elm form**: a package segment, type, field or method
  whose converted name is not a valid Elm identifier
  (`naming::invalid_module`, `naming::invalid_type`,
  `naming::invalid_field`, `naming::invalid_method`, `services_invalid`
  case), and a file without a package declaration
  (`naming::invalid_module`).
- **`google.protobuf.Any` fields** (`types::any`, `any_field` case), and
  any other `google.protobuf` type without a mapping
  (`types::unsupported_well_known`).
- **Package import cycles** (`generate::import_cycle`, `packages_cycle`
  case): Elm forbids import cycles.
- **A generate set not closed under package references**
  (`generate::not_generated`, `packages_not_generated` case), the
  request and response types of methods included (`services_invalid`
  case).
- **Streaming methods** (`services::streaming`, `services_streaming`
  case): client, server and bidirectional (§1.3).
- **HTTP rules a client cannot follow** (`route::*`, `routes_invalid`
  case): a template that does not parse or has a bare wildcard, a path
  variable, `body` or `response_body` naming no suitable field, a
  request field with no query form, a rule without a path, nested
  additional bindings (§4, §5.3; with `services_invalid`).
- **Method values that collide**: two methods of one service whose
  values have one name (`GetSettings` and `Get_Settings`;
  `naming::value_collision`, `services_value_collision` case).
- **Modules that collide**: two services of one package whose module
  names coincide (`Archive` and `archive`), a service module that is
  also a package's (`NotesService` in `notes.v1` beside the package
  `notes.v1.notes_service`), and two packages with one module name
  (`naming::module_collision`, `services_module_collision` case); and a
  service whose name has no module form (`naming::invalid_service`,
  `services_invalid` case).
- **Methods without an HTTP rule, when asked**: under
  `unbound_methods=error`, each one is `services::unbound_method`
  (`services_unbound_error` case; §4).

### 3.9 Descriptors  *(Decided, 2026-10-13)*

Every message and enum gets a typed record, a value holding its codecs
and its descriptor together, in a `-- DESCRIPTORS` section between the
defaults and the encoders:

```elm
messageNote : Proto.Message.Message Note
messageNote =
    { encodeJson = encodeNote
    , jsonDecoder = decodeNote
    , default = defaultNote
    , descriptor =
        { typeName = "notes.v1.Note"
        , fields =
            [ { name = "name", jsonName = "name", number = 1, cardinality = Proto.Descriptor.Singular, kind = Proto.Descriptor.Scalar Proto.Descriptor.String, oneof = Nothing }
            , { name = "visibility", jsonName = "visibility", number = 3, cardinality = Proto.Descriptor.Singular, kind = Proto.Descriptor.Enum "notes.v1.Visibility", oneof = Nothing }
            , …
            ]
        , oneofs = []
        }
    }


enumVisibility : Proto.Enum.Enum Visibility
enumVisibility =
    { encodeJson = encodeVisibility
    , jsonDecoder = decodeVisibility
    , values =
        [ { name = "VISIBILITY_UNSPECIFIED", number = 0, value = VisibilityUnspecified }
        , …
        ]
    , descriptor = { typeName = "notes.v1.Visibility", values = [ … ] }
    }


registry : Proto.Registry.Registry
registry =
    Proto.Registry.union
        (Proto.Registry.fromDescriptors [ messageNote.descriptor, … ] [ enumVisibility.descriptor ])
        (Proto.Registry.union Users.V1.registry Proto.Registry.wellKnown)
```

- The naming: "`Thing`Descriptor" is the data-only tree, "`Thing` a"
  the typed record carrying it in its `descriptor` field:
  `MessageDescriptor` and `Message a`, `EnumDescriptor` and `Enum a`,
  `MethodDescriptor` and `Method req res` (§4).
- The trees (`Proto.Descriptor`) are faithful to the proto, not to the
  Elm mapping: a message's full name, its fields in declaration order
  (name, JSON name, number, cardinality, kind, oneof) and its oneofs'
  names; an enum's full name and its value names in declaration order,
  an alias an entry of its own. A singular message field is `Singular`
  of `Message "…"` though Elm holds it as a `Maybe`; a proto3
  `optional` field is `Optional`, its synthetic oneof not listed. Types
  refer to each other by full name, never by value, since Elm forbids
  cyclic values; a `Proto.Registry` resolves the names.
- An enum record's `values` lists every value name in declaration
  order with its number and constructor, an alias with the constructor
  of its number's first name; `Proto.Enum` reads names and numbers
  through it (`toName`, `fromName`, `toNumber`, `fromNumber`).
- The well-known types' records are the runtime's, in
  `Proto.WellKnown` (`empty`, `timestamp`, `duration`, `fieldMask`,
  `struct`, `value`, `listValue` and the wrappers, the 64-bit ones in
  both `int64` forms), and `Proto.Registry.wellKnown` holds their
  trees. They live apart from `Proto.Message` so that a record for
  `google.protobuf.Any` can join them without an import cycle.
- No service, file or package descriptor: nothing consumes one, and a
  service module's namespace is its methods' names, so any fixed value
  name could collide with a method.
- **The registry.** Each package module ends its descriptors section
  with `registry : Proto.Registry.Registry`, transitive: the package's
  own descriptors, then the registries of the generated packages its
  module imports (each holding its own imports'), then
  `Proto.Registry.wellKnown`, joined with `Proto.Registry.union`, which
  keeps the left one of two with one name (diamonds hold each type
  once). Packages a service refers to but the package's types do not are
  not in it: importing them could make a cycle Elm rejects. It is a
  top-level constant, built once at start-up and dropped by dead-code
  elimination when nothing uses it. A package without types has a
  module holding its registry alone.
- **`descriptors=off`** (§6) writes every tree empty (`fields = []`,
  `oneofs = []`, `values = []`; the full name kept) and no registry,
  for an application that wants smaller generated modules. The typed
  records stay, since calls are built from them (§4). A package of
  services alone then has nothing for its package module to declare,
  and Elm rejects a module without declarations, so that module is not
  written; nothing would import it.
- **Cost** *(measured 2026-10-14, Elm 0.19.2, Apple M4)*: a synthetic
  package of 300 messages of eight fields and ten enums gives a package
  module of 25,434 lines (1.13 MB) with descriptors and 22,277 lines
  (0.66 MB) without. A cold `elm make` of a program using every decoder
  takes the same time either way (5.2–6.6 s over three runs each, the
  spread larger than the difference). The optimized program is 677 KB
  (46 KB gzipped) without descriptors, the same with them when the
  registry is unused, since dead-code elimination drops the trees, and
  1,655 KB (73 KB gzipped) when it uses the registry. So the default is
  `on`: the cost falls on applications that use the descriptors.

## 4. Calls  *(Decided, 2026-10-13; built)*

Each service is an Elm module of its own, `Notes.V1.NotesService`
beside the package's `Notes.V1`, holding one function per method from
its request to an `Rpc.Call` (§5.2). The `services` conformance case
pins the output:

```elm
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Rpc.call
        { request = Notes.V1.messageGetNoteRequest
        , response = Notes.V1.messageNote
        , descriptor =
            { service = "notes.v1.NotesService"
            , name = "GetNote"
            , idempotent = True
            , input = "notes.v1.GetNoteRequest"
            , output = "notes.v1.Note"
            , bindings =
                [ Proto.Descriptor.binding
                    { method = "GET"
                    , path =
                        [ Proto.Descriptor.literal "v1"
                        , Proto.Descriptor.variable [ "name" ] [ Proto.Descriptor.literal "notes", Proto.Descriptor.wildcard ]
                        ]
                    , customVerb = Nothing
                    , body = Proto.Descriptor.noBody
                    , responseBody = Nothing
                    , query = []
                    }
                , Proto.Descriptor.binding { … }   -- the additional binding
                ]
            }
        }
```

- The service module imports `Rpc`, `Proto.Descriptor` (for the
  bindings), the package module and the modules of any other package
  its request and response types come from (`Proto.WellKnown` for a
  well-known type), and refers to every one of them qualified. Each method is written
  point-free, `getNote = Rpc.call { … }`, binding no local name. So a
  method's name can clash with nothing but another method of its
  service, whatever it is: `value`, `identity` or `encodeNote` are all
  fine method names (the namespace rule is in the IR bullets below).
- `Rpc.call` takes the method's `Proto.Method.Method req res` (§3.9):
  `request` and `response` are the typed records of its types
  (`Notes.V1.messageNote`, which hold their codecs; for a well-known
  type the runtime's, `Proto.WellKnown.empty` for `Empty`, and
  `int64ValueAsInt` for `Int64Value` under `int64=int`), and
  `descriptor` its `Proto.Descriptor.MethodDescriptor`: `service` is
  the fully-qualified service name and `name` the method's as
  declared, together its Connect path, and `input` and `output` the
  full names of its types. No separate method value is generated;
  `Rpc.method` and `Rpc.descriptor` read them back from any call of the
  method. *(Decided, 2026-10-13.)* The first shape put the codecs
  themselves in a descriptor record of `Rpc`'s; the typed records keep
  them, with each type's descriptor, in one place both the call and
  `google.protobuf.Any` (§3.5) can use.
- `idempotent` is true when the proto declares
  `option idempotency_level = NO_SIDE_EFFECTS`. Connect uses it to allow
  GET, and a retry policy with `idempotentOnly` to allow a retry.
  Transcoding takes its verb from the rule.
- **Bindings are data.** `bindings` is the method's `google.api.http`
  rule as the generator parsed it (§4 routes, below): the rule's own
  binding first, then its `additional_bindings` in order, each a
  `Proto.Descriptor.binding` of the verb, the path as literals and variables, the
  custom verb, the body, the response body and the query parameters.
  The runtime walks them and never parses a template. A call picks an
  additional binding with `Rpc.viaBinding n`, `Nothing` for a number
  the method has no binding of, so additional bindings need no names of
  their own.
- **The implicit route.** A method without a rule has `bindings = []`,
  and nothing else is generated for it: under the Transcode transport
  the runtime sends it as `POST /<package>.<Service>/<Method>` with the
  request as its JSON body (§5.3), which grpc-gateway
  (`generate_unbound_methods`), Envoy's transcoder (`auto_mapping`) and
  Vanguard (always) serve. That request is exactly the one Connect
  POSTs.
- **`unbound_methods`** (§6) is `implicit` by default, the behaviour
  above. With `error`, each method without a rule is
  `services::unbound_method`, pointing at the method, for a server that
  serves rules alone. Lenient is the default because the three common
  transcoders serve the implicit route (Vanguard without being asked),
  a server with a Connect handler serves it too, and an API whose
  every method has a rule loses nothing either way; strict is one
  option away for the rest.
- `Rpc.Call req res` keeps the request type, not just the response
  type. A call is a value an application can hold, log
  (`Rpc.toJson`), read back (`Rpc.requestMessage`) and send again, so
  a retry or token-refresh wrapper closes over it, and a queue can
  store it; `req` keeps those uses typed.

The first shape built was different: one module per package holding,
after the codecs, a `Connect.Method` per method (`getNote`) and a
`Transcode.Call` per binding (`getNoteHttp`, `getNoteHttp2`, …), a
`transports=` option choosing which. It put route presence in the type
(§2), named additional bindings by number, and put method values in one
namespace with the codecs; the module per service, calls as data and
`viaBinding` replace all three.

Built so far, in the IR (`ir::Service`, `ir::Method`) *(each Proposed)*:

- Every service of a generated package, and each of its methods: the
  proto name, the Elm value name, the request and response types, the
  idempotency, and the `google.api.http` rule as written (verb, path
  template, `body`, `response_body`, additional bindings).
- Each service is an Elm module of its own, inside its package's:
  `Notes.V1.NotesService` for the service `NotesService` of `notes.v1`
  (`ir::Service::module`, from `naming::service_module`). The service
  name is converted to PascalCase as a package segment is (`notes`
  → `Notes`), so a conventionally named service keeps its name, and a
  name whose PascalCase form does not start with a letter is
  `naming::invalid_service`. The package module holds the types and
  codecs only. *(Decided, 2026-10-13.)* One module for a package's
  types and every service's methods was the first shape built; it put
  method values in one namespace with each other across services and
  with the codecs and defaults, so `DefaultSettings` beside a message
  `Settings` clashed, and two services could not both have a `Get`.
- A method's value is its name with the first letter lowercased and
  underscores dropped as for a field (`GetNote` → `getNote`), a reserved
  word escaped (`Type` → `type_`). It shares a namespace only with the
  other methods of its service: two that coincide (`GetNote` and
  `Get_Note`) are `naming::value_collision`, never a rename. A method
  `DefaultSettings` beside a message `Settings`, or a `Get` in two
  services, is fine.
- Module names are unique across the build: a service module that is
  also a package's module (`NotesService` in `notes.v1` beside the
  package `notes.v1.notes_service`), two services whose module names
  coincide (`Archive` and `archive`), or two packages whose do
  (`notes.v1` and `notes.V1`) are `naming::module_collision`, each
  site labelled. A service named like a type of its package needs no
  check: proto forbids the same name, and an Elm module and a type
  with one name do not clash.
- A method of `google.protobuf.Empty` or another supported well-known
  type takes or gives that type's Elm form (`()` for `Empty`), through
  the runtime's typed record of it (`services_types` case). Any other
  type outside the generate set is `generate::not_generated`, worded for
  the method ("The request of `notes.v1.Notes.Get` refers to ...").
- A streaming method is `services::streaming`, pointing at its
  `stream` keyword, rather than being skipped.
- `google/api/http.proto` and `google/api/annotations.proto` are
  embedded in `elm-connect-gen` (`googleapis` module; Apache-2.0,
  `THIRD_PARTY.md`). The CLI resolves imports from its include paths
  first, then protox's `google/protobuf` files, then these, so a proto
  importing `google/api/annotations.proto` compiles without a googleapis
  checkout. The protoc plugin needs no copy: protoc sends every import.
  It builds its descriptor pool from the request's encoded files rather
  than from `prost_types`, which drops extension options such as
  `google.api.http`.

Routes *(Proposed; built in `elm-connect-gen::route`)*: each binding of
a rule (the rule's own, then each additional binding) is parsed and
checked against the request and response messages at generation time,
and becomes a `route::Route`: the verb, the path as literals and
variables, the custom verb, the body, the response body and the query
parameters, every field by its proto path and its JSON path. The runtime
gets exactly this as data and never parses a template.

- The template grammar is `google/api/http.proto`'s. A literal may not
  hold `{`, `}`, `*`, `=` or `:`, nor be empty; a variable may not nest
  another; `**` is the last segment only; the custom verb is the text
  after the last `:` that follows the last `/` outside braces.
- A bare `*` or `**` outside a variable is refused (`route::template`):
  a server can match it, but a client has no field to fill it from.
- A path variable names a non-repeated scalar or enum field, possibly
  through singular fields of generated messages (`{sub.subfield}`); not
  through a well-known type, whose fields have no JSON form of their own.
  A field bound twice is refused. Each violation is `route::path_field`.
- The client does not check a value against the variable's template
  (`notes/42` against `notes/*`): the server matches, and a mismatch is
  its 404.
- `body` is empty, `*`, or a top-level singular message field
  (`route::body_field` otherwise). A path variable inside the body field
  (`patch: "/v1/{book.name=books/*}" body: "book"`, AIP-134's update
  shape) is allowed: the field is in both, the body is sent whole, and
  the server takes the path's value. That is the one way a field can be
  in both, so "a field in both path and body" is not a diagnostic.
- `response_body` is any top-level field of the response
  (`route::response_body` otherwise).
- A request of a well-known type other than `Empty` has no fields of
  its own to put in a query (its JSON is not an object of its fields),
  so a rule for one has `body: "*"` (`route::query_field` otherwise).
  `Empty` sends nothing either way.
- Additional bindings follow the same rules and may not nest
  (`route::rule`, as is a rule with no pattern).

## 5. Runtime  *(Decided unless marked)*

**The package is kept.** *(Decided, 2026-10-11.)* The type layer was
built against a runtime package from day one, because the JSON pipeline
helpers and the well-known-type codecs would otherwise be inlined into
every generated module, with the question of keeping it left open until
its contents existed. They settle it: a shared type (`Duration`)
must be one type across every generated module and the application,
which inlining cannot give; the codecs for timestamps as `Time.Posix`
and the `Int64` helpers are one copy rather than one per module; and
the coming transports belong in it too.

### 5.1 Config  *(Decided, 2026-10-13; built)*

```elm
type alias Config =
    { transport : Transport
    , baseUrl : String                    -- a trailing "/" is dropped
    , headers : List ( String, String )   -- e.g. ( "Authorization", "Bearer …" )
    , timeout : Maybe Float               -- ms; Connect also sends Connect-Timeout-Ms
    , withCredentials : Bool              -- Http.riskyRequest when True
    , retry : Maybe Retry
    }

type Transport
    = Connect { useGet : Bool, maxGetUrl : Maybe Int }
    | Transcode                     -- no options yet

type alias Retry =
    { attempts : Int, backoff : Float, codes : List ErrorCode, idempotentOnly : Bool }

config : String -> Config   -- Connect, POST only, nothing else set
connect : Transport         -- Connect { useGet = False, maxGetUrl = Nothing }
```

The config is data: a record with no function in it, transport options
inside the `Transport` constructor. That is the point of it. Elm 0.19
throws at run time on `==` over functions, so a config holding one
could not be compared, kept in a model safely, or passed through
`Html.Lazy`; data can also be printed, stored, and built per call from
an application's shared state with record syntax
(`{ base | headers = auth shared }`).

So there are no interceptors, no token provider and no logger in it.
Every use of an interceptor maps onto something else:

- onto data: headers, timeout, credentials and retry are fields;
- onto update-time handling: logging reads the `Trace` (§5.2) a
  traced send returns, and refreshing a token is the application
  shell's job, single-flight, before it builds the config;
- onto the pure halves: arbitrary rewriting of a request is
  `Rpc.request`, then any change, then `Rpc.taskFromRequest`.

The docs owe the wrapper pattern this asks of an application: one
function, `rpc shared call = Rpc.task (config shared) call`, through
which every call goes, and a generic retry or refresh wrapper that
closes over the call value, which is data and can be sent again. If a
need for hooks appears, an opaque `Rpc.Client` built from a `Config`
plus hooks can be added beside `task : Config -> …` without breaking
it.

- Headers are name–value pairs rather than `Http.Header`, which is
  opaque, so a built request can be inspected and compared.
- `useGet` is off by default, as in connect-es: a GET is only worth it
  where a cache sits in front of the server, and the application knows
  that, not the generator. *(Decided, 2026-10-11.)* `maxGetUrl` POSTs a
  call whose GET URL would be longer than that many characters, for
  servers and proxies that cap URL length.
- A timeout is also the elm/http timeout, so the client gives up at the
  same moment it asked the server to.
- Retry waits `backoff` ms before the second attempt and doubles it
  before each one after, up to `attempts` tries in all. It applies only
  to an `Rpc` error with one of `codes`, never to a transport error, and
  with `idempotentOnly` only to idempotent calls.

### 5.2 Rpc  *(Decided, 2026-10-13; built)*

The runtime has two roots: `Proto.*` is the data, `Rpc.*` the calling.
*(Decided, 2026-10-13.)* `Rpc` is the one module that sends, beside
`Rpc.Code` and `Rpc.ErrorCode` (§5.4); its internals live under
`Rpc.Internal.*`. The data modules, which generated code calls whatever
the transport, are the codecs (`Proto.Json`, `Proto.Timestamp`,
`Proto.Duration`, `Proto.Int64`), the descriptor trees and HTTP
bindings (`Proto.Descriptor`), the typed records (`Proto.Message`,
`Proto.Enum`, `Proto.Method`), the well-known types' records
(`Proto.WellKnown`) and `Proto.Registry` (§3.9). They were `Connect.*` at first, a name that tied proto3
JSON to one of the two transports; no public `Connect` module remains.

```elm
type Call req res      -- opaque: method, request, binding, per-call adjustments
call : Proto.Method.Method req res -> req -> Call req res

-- per call
withHeaders : List ( String, String ) -> Call req res -> Call req res   -- after the config's
withTimeout : Float -> Call req res -> Call req res                     -- replaces the config's
withTracker : String -> Call req res -> Call req res                    -- send without retry only
viaBinding : Int -> Call req res -> Maybe (Call req res)                -- transcoding only

-- reading
method : Call req res -> Proto.Method.Method req res
descriptor : Call req res -> Proto.Descriptor.MethodDescriptor
serviceName, methodName, idempotent, requestMessage, requestJson
toJson : Call req res -> Json.Encode.Value   -- {"service","method","request"}

-- sending
task : Config -> Call req res -> Task Error res
send : Config -> Call req res -> (Result Error res -> msg) -> Cmd msg
taskTraced : Config -> Call req res -> Task Never ( Trace, Result Error res )
sendTraced : Config -> Call req res -> (Trace -> Result Error res -> msg) -> Cmd msg

-- pure halves
type alias Request =
    { method : String, url : String, headers : List ( String, String )
    , body : Maybe String, timeout : Maybe Float, withCredentials : Bool }
request : Config -> Call req res -> Request
response : Config -> Call req res -> Http.Response String -> Result Error res
taskFromRequest : Config -> Call req res -> Request -> Task Error res
```

- A call is data: a generated function per method applied to the
  request (§4). Per-call adjustments ride on it; `toJson` gives it a
  stable JSON form for logs, deduplication keys and queues.
- The codecs are the typed records' `encodeJson` and `jsonDecoder`,
  named for their encoding so that binary codecs can sit beside them
  later without a rename. *(Decided, 2026-10-13.)*
- The accessors are `method` (the `Method` record), `descriptor` (its
  descriptor), `serviceName`, `methodName` and `idempotent`; the
  string accessors were `service` and `method` until `method` named
  the record. *(Decided, 2026-10-13.)*
- `viaBinding n` is `Just` the call over binding `n` when the
  descriptor has one (`0` the rule's own, `1` and up its additional
  bindings), `Nothing` otherwise; a method without a rule gives
  `Nothing` for every number, and its unadjusted call takes the
  implicit route (§5.3). A call therefore always has a route, and
  sending never fails for want of a binding. *(Decided, 2026-10-13.)*
- `Request` is the data form of the record `Http.request` takes,
  without `expect` and `tracker`: elm/http has no request value of its
  own, and its headers and body are opaque. Headers are pairs, the body
  the JSON string, and `withCredentials` picks `Http.request` or
  `Http.riskyRequest`.
- `task` is `taskFromRequest` of `request`; the retry loop lives in
  `taskFromRequest`, between attempts `Process.sleep`, so a rewritten
  request is retried too.
- `send` without a retry policy is one `Http.request`, carrying the
  call's tracker; with one, it is `Task.attempt` over `task`, and the
  tracker does not apply, since elm/http tracks commands only and
  retrying needs a task. The traced forms are tasks too.
- `Trace` is `{ service, method, binding, request, httpStatus, code,
  duration, attempts }`: `binding` is `Nothing` when no binding was used
  (Connect, the implicit route), `httpStatus` the last answer's HTTP
  status, `code` how the call ended (`Just Ok` on success,
  `Just (Failed c)` on an `Rpc` error, `Nothing` on a transport
  failure), `duration` milliseconds by `Time.now` before the first
  attempt and after the last. *(`httpStatus` and `code` decided,
  2026-10-13.)*
- Only the pure halves are unit-tested; elm-test cannot run a `Task`,
  so `task`, `send`, the traced forms and the retry loop are checked by
  the compiler and by the retry policy's own tests.

### 5.3 Transports

#### Connect  *(Decided; built)*

- Unary only. POST to `baseUrl/<service>/<Method>` with the request's
  JSON as an `application/json` body and `Connect-Protocol-Version: 1`.
  With `useGet`, an idempotent call is a GET of the same URL with
  `?connect=v1&encoding=json&message=<JSON>`, the JSON percent-encoded
  (every byte but RFC 3986's unreserved characters), in the order the
  protocol recommends; no protocol-version header, which GET carries in
  the query.
- `Connect-Timeout-Ms` is the timeout rounded up to a whole
  millisecond, between 1 and 9,999,999,999 (ten digits).
- Success is status 200 with a body the response decoder accepts; a 200
  whose body it rejects is `Transport (Http.BadBody _)`. Any other
  answer is read as an error (§5.4).
- Bindings are carried on the call and ignored, `viaBinding` too:
  Connect has one route per method.
- The runtime's dependencies beyond core, json and time: elm/http
  (which brings elm/bytes and elm/file). Percent-encoding is written out
  in the runtime rather than taken from elm/url, whose `percentEncode`
  keeps `!*'()`, which the transcoding rules require escaped.

#### Transcode  *(Decided, 2026-10-13; built)*

The bindings a generated call carries (`Proto.Descriptor.binding`, with
`literal`, `variable`, `wildcard`, `doubleWildcard`, `noBody`,
`wholeBody`, `bodyField` and `param`) are the parsed `google.api.http`
rule, the rule's own binding first and its
`additional_bindings` after; `Rpc.viaBinding n` picks one, `0` by
default, and is `Nothing` for a number the method has no binding of
(§5.2).

- **The implicit route.** A method without a rule has no bindings, and
  is called as `POST /<package>.<Service>/<Method>` with the request as
  its JSON body, which grpc-gateway (`generate_unbound_methods`), Envoy
  (`auto_mapping`) and Vanguard all serve. That is exactly the request
  Connect POSTs, `Connect-Protocol-Version: 1` and `Connect-Timeout-Ms`
  included, so the runtime builds it from the descriptor and the
  generated code carries nothing for it; whether a method has a rule is
  not in the type. Its answer is read as a transcoder's (any 2xx).
- Every call has a route: its binding, or the implicit route when the
  method has no rule. An earlier build let `viaBinding` take any
  number and failed at send time for one with no binding; making the
  choice a `Maybe` moved that failure to where the number is chosen.
  *(Decided, 2026-10-13.)*
- Success is any 2xx; an empty body reads as `{}`, and with
  `response_body` the answer is that field of the response.
- Path variables are percent-encoded (every byte but RFC 3986's
  unreserved characters); a variable matching one segment (`{name}`,
  `{name=*}`) escapes `/` as `%2F`, any other keeps it. A wildcard
  outside a variable never reaches the runtime (`route::template`).
- Path from the template and the request; body from the `body` field
  (`*`, a named field, or none); remaining request fields as query
  parameters on GET and DELETE, omitting zero values. *(Decided for
  omission: the in-house generator sent them, which was harmless but
  noisy.)*
- Query parameters, as built *(Proposed)*: unless `body` is `*`, every
  leaf of the request that is not bound by the path and not under the
  body field, in declaration order, depth first through singular
  message fields (http.proto's rule, whatever the verb). A parameter is
  named by the dotted proto field path (`sub.subfield`,
  `page_size`), which http.proto prescribes and every transcoder
  accepts; JSON names (`pageSize`) are accepted by grpc-gateway but not
  by every transcoder. A field without presence is left out at its
  proto3 default (`""`, `0`, `false`, an enum's zero value), a field
  with presence (`optional`, a oneof member, a wrapper, a timestamp)
  only when unset, and a repeated field sends one parameter per element.
  Values are written as proto3 JSON writes them, unquoted: enums by
  name, 64-bit integers in decimal, timestamps in RFC 3339, field masks
  comma-joined.
- Fields with no query form are refused rather than dropped
  (`route::query_field`): maps, repeated messages, `Struct`, `Value`
  and `ListValue`, and a message that contains itself. `Empty` carries
  nothing and has no parameter.

### 5.4 Errors  *(Decided, 2026-10-13; built)*

```elm
type Error
    = Rpc { code : ErrorCode, message : String, details : List Json.Encode.Value, source : Source }
    | Transport Http.Error      -- bad URL, timeout, network, undecodable success

type Source
    = ConnectBody               -- {"code": "not_found", …}
    | StatusBody Int            -- google.rpc.Status, {"code": 5, …}; the number as received
    | GrpcHeaders               -- grpc-status / grpc-message headers
    | HttpStatus Int            -- inferred from the status by Connect's table
```

```elm
-- Rpc.ErrorCode
type ErrorCode = Canceled | Unknown | … | Unauthenticated   -- gRPC's 1 to 16

-- Rpc.Code
type Code = Ok | Failed ErrorCode
```

Each module has `toString` / `fromString` (Connect's names), `toInt` /
`fromInt` (gRPC's numbers), `toHttpStatus` and `fromHttpStatus`; for
`Code`, `Ok` is `"ok"`, `0` and any 2xx. *(Decided, 2026-10-13.)* `Ok`
is in `Code` so that a status can be reported whole (a `Trace`'s
`code`), but an `Rpc` error carries an `ErrorCode`, so an error
claiming `Ok` cannot be written; a failed answer whose body says `ok`
or `0` reads as `Unknown`. The two types first shared `Rpc.Code`, the
helpers for `Code` prefixed (`codeToString`, …); a module each gives
both the plain names.

- `toHttpStatus` is the status a Connect server sends with a code, the
  Connect protocol's table, which is `google/rpc/code.proto`'s HTTP
  mapping (`InvalidArgument` 400, `NotFound` 404, `Unavailable` 503,
  …). `fromHttpStatus` is not its inverse: it is gRPC's mapping
  (`doc/http-grpc-status-mapping.md`) for an answer with no error body,
  where a 400 means a proxy or the transport refused the request, so it
  reads as `Internal`, not `InvalidArgument`.

- One error type for every transport. Two were built first, one per
  transport, on the grounds that the wire forms differ (`"code":
  "not_found"` against `"code": 5`) and that knowing which one arrived
  tells a developer which side misbehaved. `source` keeps that
  information without making every caller handle two types, and a
  server behind a transcoder can answer in either form.
- A failed answer is read by one reader whatever the transport, in
  order: a Connect error body (`code` a string the protocol names; an
  unknown name reads as `Unknown`; `message` `""` and `details` `[]`
  when absent); a `google.rpc.Status` body as grpc-gateway and Envoy
  send it (`code` an integer; one outside 1 to 16, `0` included, is
  `Unknown`, the number kept in the source); the `grpc-status` and
  `grpc-message` headers, when the browser exposes them (the message
  percent-decoded, the status text when absent); then the HTTP status by the protocol's
  table, with the status text as the message (`HTTP <status>` when
  empty) and no details. The shape of `code` tells the two bodies
  apart, so a server behind either transport may answer in either
  form.
- Error details are kept as raw JSON values. Typed details need
  `google.protobuf.Any`, which is not designed yet (§3.5, §9).

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
- Options (`--elm-connect_opt=` or CLI flags): `int64=string|int`,
  `unbound_methods=implicit|error`, `descriptors=on|off`,
  `module_prefix=`, and later perhaps
  `enum_unknown=zero|variant` (§3.3 defers the variant). A
  `transports=` option, choosing which transports' values were
  generated, went with the shape it chose between (§4). *(Decided,
  2026-10-13.)*
  Built so far: `int64` (§3.4; `--elm-connect_opt=int64=int`, or
  `elm-connect gen --int64 int`), `unbound_methods` (§4;
  `--elm-connect_opt=unbound_methods=error`, or `elm-connect gen
  --unbound-methods error`) and `descriptors` (§3.9;
  `--elm-connect_opt=descriptors=off`, or `elm-connect gen
  --descriptors off`). The plugin parameter is
  comma-separated `key=value` pairs; an unknown key or value, or a key
  given twice, is an error. A conformance case sets options with an
  `options.txt` holding that parameter.
- Diagnostics carry spans from `SourceCodeInfo` and render in the style
  of Elm's compiler. First catalogue: route variable names a field the
  request does not have; route body names a non-message field; map key
  of an unsupported type (dropped: every key proto allows has an Elm
  form, `bool` an association list, §3.2); package
  import cycle; name collision after casing; `Any` field; streaming
  method; method value collision (§4); the `route::*` problems of
  HTTP rules (§4); a method without a rule under
  `unbound_methods=error` (§4). A recursive
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
  Built *(Decided; built)* as `conformance/routes/` (layout in
  `conformance/README.md`): `routes.proto` gives the request messages and
  the rules, since a request's JSON names fields by JSON name and the
  rule by proto name, and only the schema joins them; each fixture names
  a method and binding, repeats the rule (verb, template, body) and
  gives the request as proto3 JSON and the expected path, query pairs
  (percent-encoded, in order) and body. They cover http.proto's own
  examples, percent-encoding (`/` as `%2F` in a single-segment variable,
  kept by `**` and multi-segment ones, reserved characters, UTF-8),
  query names, value forms and omission (scalars, enums, 64-bit
  integers, bytes, repeated fields, presence, well-known types, nested
  messages, oneofs), typed path values, custom methods and verbs,
  bodies (`*` without nested path fields, a field sent whole, an unset
  field), and the implicit route of a method without a rule (`binding`
  and `rule` `null`; the expected headers carry
  `Connect-Protocol-Version: 1`, §4, §5.3).
  Both ends are checked: in Rust against a reference built on
  prost-reflect's proto3 JSON parser and field presence, independent of
  the JSON walk the runtime does, and in Elm by replaying each fixture
  through `Rpc.request` with a Transcode config, the call built by the
  generated service module and its binding chosen with
  `Rpc.viaBinding` (a fixture naming a binding the method lacks fails
  rather than falling back to the implicit route). Bodies compare with
  `null`s and defaults dropped.

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

1. Presence as companion data: instead of `Maybe` fields, generated
   records could carry a presence set plus helpers (`hasBar`), a
   pattern that would also give unknown fields a home; this trades
   "simple, idiomatic Elm records" for an abstract structure. Not
   decided; raised during the type-layer review.
2. `Any` (§3.5): the shape of pack and unpack, and its relation to the
   generated descriptors (§4). The operator has prior notes.

Settled 2026-10-13, with the client's shape (§2, §4, §5): whether to
fuse method and route for transcoding, and how to name additional
bindings. A call is data built per method, carrying every binding, so
there is nothing to fuse, and `Rpc.viaBinding n` picks a binding
without a name for it. Route presence left the type with them: a
method without a rule takes the implicit route, and
`unbound_methods=error` is the strict form. The config is data, so
interceptors, a token provider and a logger in it were rejected: a
function in a config makes it impossible to compare (Elm 0.19 throws
on `==` over functions), to keep safely in a model or under
`Html.Lazy`, and to print or build per call with record syntax, and
each use of one maps onto data (headers, timeout, retry), onto
update-time handling (logging from the `Trace`, token refresh
single-flight in the application's shell) or onto the pure halves
(rewriting a request between `Rpc.request` and `Rpc.taskFromRequest`).
If hooks are wanted after all, an opaque `Rpc.Client` built from a
`Config` plus hooks can be added beside `Rpc.task : Config -> …`
without breaking it.

## 10. Out of scope but recorded

Streaming (both transports), binary protobuf, gRPC-web, proto2,
interceptors (§9), server generation. Each has a sentence above
saying why; none is a permanent no.
