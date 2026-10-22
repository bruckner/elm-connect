# elm-connect — design

This is the design contract: each section says what the system does
and the rules it keeps. Why a rule is what it is, what else was
considered and what it replaced are in [decisions.md](decisions.md),
and what may come later is in [roadmap.md](roadmap.md). Change this
document by pull request; the PR discussion is the design record.

## 1. What this is

A code generator and a runtime that let an Elm application call a
protobuf-defined API over JSON. Two transports are supported from the
same generated code:

| Transport | Wire | Server side |
|---|---|---|
| **Connect** | `POST /<pkg>.<Service>/<Method>`, JSON body, Connect error JSON | connect-go, connect-es, connect-python, Envoy's Connect-gRPC bridge in front of a gRPC server |
| **Transcode** | REST paths from `google.api.http`, proto3 JSON, `google.rpc.Status` errors | grpc-gateway, Envoy's gRPC-JSON transcoder, Vanguard, any hand-written REST layer that honours the annotations |

The generator is written in Rust. The runtime is an Elm package,
`bruckner/elm-connect`. Both live in this repository.
The specifications behind both transports are listed in
[specs.md](specs.md).

The runtime is written for the browser and runs wherever elm/http
does: a headless program (`Platform.worker` under Node, given an
`XMLHttpRequest` of the shape the live suite's `xhr.mjs` provides)
calls the same way. So the client sits between connect-web, the
browser transport, and connect-node in what it can be asked to do, and
a knob only the Node clients have can still earn its place (§5.1).

### 1.1 Why it exists

The Elm ecosystem's main protobuf stack
([protoc-gen-elm](https://www.npmjs.com/package/protoc-gen-elm) with
[eriktim/elm-protocol-buffers](https://package.elm-lang.org/packages/eriktim/elm-protocol-buffers/latest/)
and [elm-grpc](https://package.elm-lang.org/packages/anmolitor/elm-grpc/latest/),
last released in 2024; [compared.md](compared.md) has the versions and
the older generators, as of 2026-10-20) is binary-first:
protoc-gen-elm can also generate proto3 JSON codecs, but elm-grpc, its
transport, sends gRPC-Web only, unary and in protobuf binary. Nobody generates Elm clients for
`google.api.http` transcoding, and nobody speaks the Connect protocol
from Elm. Those two server shapes are what most protobuf-backed web
services actually expose to browsers.

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
  enveloped frames; grpc-gateway streams newline-delimited JSON, and
  Envoy a JSON array by default. A streaming method is a diagnostic, or
  with `streaming=skip` is left out (§3.8). Server streaming is planned
  as a minor release ([roadmap.md](roadmap.md)); client and
  bidirectional streaming cannot be done from a browser.
- Binary protobuf. JSON only. Users who need `application/proto` have
  the existing stack; binary codecs are on the roadmap, as a minor.
- gRPC-web; unary gRPC-Web, over the binary codecs, is on the roadmap.
- proto2 syntax, and editions. A proto2 file to generate is
  `input::not_proto3`. A file that declares an edition
  (`edition = "2023";`) is `input::editions`, from either binary, before
  anything is generated, even where its features would reduce to proto3
  semantics: protox, under the CLI, does not parse editions, and the
  plugin answers protoc before building its descriptor pool, which
  cannot take an editions file. The plugin does not claim
  `FEATURE_SUPPORTS_EDITIONS`, so protoc says the same in its own words.
  Supporting the editions that reduce to proto3 is additive, an error
  becoming output (roadmap).
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
import Notes.V1.GetNoteRequest
import Proto.Http
import Proto.Method
import Rpc



-- CALLS


getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Rpc.call
        (Proto.Method.method Notes.V1.encodeGetNoteRequest
            Notes.V1.decodeNote
            descriptorGetNote
        )


summarize : Notes.V1.SummarizeRequest -> Rpc.Call Notes.V1.SummarizeRequest Notes.V1.Summary
summarize =
    Rpc.call
        (Proto.Method.method Notes.V1.encodeSummarizeRequest
            Notes.V1.decodeSummary
            descriptorSummarize
        )



-- DESCRIPTORS


descriptorGetNote : Proto.Method.Descriptor
descriptorGetNote =
    Proto.Method.descriptor "notes.v1.NotesService"
        "GetNote"
        Proto.Method.IdempotencyNoSideEffects
        "notes.v1.GetNoteRequest"
        "notes.v1.Note"
        [ Proto.Http.binding
            { method = "GET"
            , path =
                [ Proto.Http.literal "v1"
                , Proto.Http.variable
                    { fieldPath = [ Notes.V1.GetNoteRequest.name ]
                    , template = [ Proto.Http.literal "notes", Proto.Http.wildcard ]
                    }
                ]
            , customVerb = Nothing
            , body = Proto.Http.noBody
            , responseBody = Nothing
            , query = []
            }
        ]


descriptorSummarize : Proto.Method.Descriptor
descriptorSummarize =
    Proto.Method.descriptor "notes.v1.NotesService"
        "Summarize"
        …
        []   -- no rule: the implicit route
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

-- the same, as a command giving GotNote the result
Notes.getNote { name = "notes/42" } |> Rpc.send config GotNote
    : Cmd Msg

-- GET https://api.example.com/v1/notes/42
Notes.getNote { name = "notes/42" } |> Rpc.task { config | transport = Rpc.Transport.transcode }

-- POST https://api.example.com/notes.v1.NotesService/Summarize, the implicit route
Notes.summarize request |> Rpc.task { config | transport = Rpc.Transport.transcode }
```

An application usually sends every call through one function of its
own, which derives the config from its state:

```elm
rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call
```

## 3. Generated types  *(Decided)*

### 3.1 Modules

- **The runtime's modules** follow seven rules. *(Decided,
  2026-10-16; rules 4 and 5 2026-10-17; rule 6 2026-10-19; rule 7
  2026-10-21.)* (1) A module per proto concept
  holds whatever that concept has: its typed value if it has one, its
  descriptor, and the unions its descriptor holds. Several types to a
  module is the normal Elm shape (`Http`, `Html`). So `Proto.Message`
  holds `Message a` and `Descriptor`, `Proto.Enum` holds `Enum a` and
  `Descriptor`, `Proto.Method` holds `Method req res` and `Descriptor`,
  `Proto.Field` holds `Descriptor` with `Cardinality`, `Kind` and
  `Scalar`, and `Proto.EnumValue` holds `Descriptor`. (2) A builder is
  named for the type it builds, in every module: `message` builds a
  `Message`, `descriptor` a `Descriptor`. Readers are plain nouns
  (`name`, `fields`); a typed value's reader for its descriptor is
  `toDescriptor`, a conversion like `Url.toString`. `typeName` and
  `typeUrl` read the descriptor, not the typed value, so no reader name
  is shared by two types in one module. (3) A union's constructors carry
  the union's name as a prefix, without exception
  (`CardinalitySingular`, `KindMessage`, `ScalarString`), so any of them
  can be exposed with `(..)` beside another union's and beside
  `Rpc.Code(..)` without a clash. (4) An `Internal` module holds what
  the package needs but will not promise: a constructor two public
  modules must build or match (`Rpc.Internal.Call`, built by `Rpc`,
  read and modified by `Rpc.Call`; `Rpc.Internal.Trace`, built by
  `Rpc`, read by `Rpc.Trace`; `Rpc.Internal.Transport`,
  `Rpc.Internal.Retry`; `Proto.Internal.Binding`, built by
  `Proto.Http` and read by `Rpc`; `Proto.Internal.Any`), or
  implementation kept out of the public modules so that they read as API
  (`Rpc.Internal.Http`, the elm/http adapter; `Rpc.Internal.Route`,
  `Rpc.Internal.Wire` and `Rpc.Internal.Answer`, §5.2). A type one
  module both builds and reads is an ordinary opaque type in that module
  (`Rpc.Body`). The internal modules are one per shared type rather than
  one `Rpc.Internal`, because a single module would cycle: `Trace` holds
  a `Request`, which holds a `Body`. (5) A record several modules depend
  on lives in a leaf module that imports nothing above it, so that none
  of them imports the facade: `Rpc.Request` and `Rpc.Response`. The
  functions that make them stay in `Rpc`, because they take a `Config`
  and a `Call`: `Rpc.request` builds a `Request`, and `Rpc.response`
  reads an answer into the errors that keep a `Response`. (6) The JSON
  helpers (`Proto.Json`) are named by role: a decoder is a noun naming
  what it reads (`int64`, `timestamp`, `boolMap`, `any`), a value's
  encoder is `encode` and that noun (`encodeInt64`, `encodeBoolMap`,
  `encodeAny`), and a field's encoder, which gives `Nothing` to leave
  the field out, ends in `Field` (`implicitField`, `repeatedField`,
  `dictField`, `boolMapField`), with `objectOfFields` building a
  message's object from them. So a decoder and its encoders share a
  noun, and no helper shares a name with an elm/json function of
  another type (`Json.Encode.object`, `Json.Encode.dict`), as `object`,
  `dict` and `boolDict` did before. Every well-known type's codecs are
  there, `Any`'s included. (7) The imports point one way: no `Proto`
  module imports an `Rpc` one, and `Rpc` reads two internal modules of
  the `Proto` side, `Proto.Internal.Binding` and `Proto.Internal.Any`,
  and no others, so that the codecs could become a package of their own
  without changing ([decisions.md](decisions.md#no-package-split)).
- **Generated codecs are `encodeX` and `decodeX`.** *(Decided.)* A package module's codecs for a message or enum are the
  pair `encodeNote : Note -> Json.Encode.Value` and
  `decodeNote : Json.Decode.Decoder Note`, so a type's two codecs sit
  together in a search and the ENCODERS and DECODERS sections each read
  as one prefix. The noun convention of rule 6 applies to the runtime,
  whose decoders each read a kind; elm/json's spelling, `noteDecoder`,
  was considered and not taken.
- One Elm module per proto **package**: `notes.v1` → `Notes.V1`.
  *(Decided.)* Per-file modules leak the server's file layout into the
  client and make cross-file references within a package awkward.
- **Lists in generated code.** *(Decided.)* A list literal
  with elements puts each on its own line, a list of one too, so a list's
  layout does not change as it grows and every element is a line of its
  own in a diff. Four lists stay on one line where they fit, since each
  reads as one token of the proto source: a path variable's path of
  field descriptors and its template (`Proto.Http.variable { fieldPath =
  [ Notes.V1.GetNoteRequest.name ], template = [ Proto.Http.literal
  "notes", Proto.Http.wildcard ] }`), a query parameter's path of field
  descriptors (each path reads as the dotted field path the rule
  writes), and a field's behaviors (`Proto.Field.withBehavior [ … ]`).
  Layout is not API (§8.3): it can change in any release.
- **Values in the package module, descriptions beside it.** *(Decided.)* The package module holds what a program sends and
  receives: the types (messages, oneofs, recursion wrappers, enums),
  their defaults and codecs, the typed values (`messageNote`,
  `enumVisibility`) and the registry. What the proto says about a type
  lives in a module of the type's own inside the package's, named by
  its Elm type name: `Notes.V1.Note` holds one
  `Proto.Field.Descriptor` per field, named as its record field
  (`title`, `pageSize`; a oneof member for the end of its constructor,
  §3.7), and
  `descriptor : Proto.Message.Descriptor` built from them;
  `Notes.V1.Visibility` holds `descriptor : Proto.Enum.Descriptor`; a
  nested `Outer.Inner` is `Notes.V1.OuterInner`, flat as its type's
  name is (§3.7; confirmed 2026-10-19, so that one naming rule names
  both). Imports go one way:
  the package module imports its descriptor modules (for the typed
  values and the registry), a message's descriptor module imports the
  descriptor modules of the enums its fields hold (another package's
  included), and a service module imports the descriptor modules its
  routes name (§4); nothing imports a package module from below, so no
  cycle can form. Why: a field's descriptor is something a program can
  name (`Notes.V1.Note.title`), which routes build on (§5.3) and UI
  code can, and the package module of values reads as the API a
  program uses. The cost is a module per type (§3.9 measures it). A
  descriptor module is a generated module like any other: it opens
  with `elmConnectVersion_`, `module_prefix` applies to it, and its
  name is claimed with every other module's, so a message or enum
  named like a service of its package (`notes_service` beside
  `NotesService`), like a package nested in its own (`Note` beside
  `notes.v1.note`), or like another type but for case (`ShopItem`,
  `Shopitem`) is `naming::module_collision`, with `rename` the escape
  (`descriptors_module_collision` and `descriptors_module_case`
  cases).
- **A descriptor module's values.** *(Decided.)* Its
  values share a namespace with the message's field names, so the
  generator claims as few names there as it can. It claims one,
  `descriptor`, which the protobuf style guide already lists among the
  names a field should avoid
  (<https://protobuf.dev/programming-guides/style/#collisions>); a
  field named `descriptor` gets the value `descriptor_` instead, with
  no diagnostic, and keeps `descriptor` as its record field in the
  package module (`descriptors_value_escape` case). Any value the
  generator adds to a descriptor module later ends in `_`, as
  `elmConnectVersion_` does: a field's derived name ends in `_` only as
  the escape of one of the fourteen reserved words (`type_`) or as
  `descriptor_`, and a `rename` of a field, oneof or method to a name
  ending in `_` is `options::invalid_rename` (§3.7), so a later
  addition that avoids those fifteen cannot collide with a field, and
  adding one breaks no proto that generates.
- Elm forbids import cycles; proto allows cycles between packages across
  files. The generator detects a package-level cycle and reports it as a
  diagnostic naming the files involved. *(Decided.)* Alternative: fold
  the strongly-connected packages into one module. Rejected for 1.0
  because it changes module names based on a property users cannot see
  in their protos.
  It is `generate::import_cycle` (`packages_cycle` case): it names
  each package with its files and points at a reference along the
  cycle in each.
- An optional `module_prefix` option (`Api.Notes.V1`). *(Decided.)* It puts every module the run generates inside the prefix:
  each package's, a renamed one too (`rename=notes.v1:Memos` under
  `module_prefix=Api` gives `Api.Memos`), each service's inside its
  package's, and any other generated package's, such as `Google.Rpc`;
  file paths, imports, qualified references and the module names in
  diagnostics follow, while the runtime's modules (`Proto.*`, `Rpc`,
  `Rpc.*`) are never prefixed. The value is dot-separated Elm module segments,
  given at most once (`module_prefix` case, `tests/ir/module_prefix.rs`).
  A file-level `elm_package` file option (like `java_package` or
  `go_package`), if one is added, composes under the prefix: with both, a
  package's module is `<module_prefix>.<elm_package>`.
- **The runtime's namespaces.** *(Decided, 2026-10-21.)* The runtime's
  modules are `Rpc` and `Proto` and modules inside them, and it may add
  more there in any release (§8.3). A generated module that takes one
  of its modules' names is `naming::reserved_module`, an error. Any
  other generated module named `Rpc` or `Proto` or inside one (`Rpc.V1`
  from `package rpc.v1`, `Proto.Notes` from `package proto.notes`,
  every module under `module_prefix=Proto`) generates, with one
  `naming::runtime_namespace` warning per run listing them in sorted
  order: it compiles today, and a module the runtime adds later of the
  same name would make every import of it ambiguous. That is the
  user's risk, which `module_prefix` or a `rename` of the package
  avoids (`naming_runtime_namespace` and `module_prefix_runtime`
  cases). Why a warning and not an error: the root `Proto` is the
  runtime's, but nothing is wrong with the output until the runtime
  takes the name, and an application may accept that risk.
- **Modules of an application's packages.** *(Decided, 2026-10-21.)* A
  generated module named like a module of elm/html, elm/browser,
  elm/url, elm/svg, elm/file, elm/random, elm/regex, elm/parser or
  elm/virtual-dom (a fixed list of their exposed modules,
  `naming::APPLICATION_MODULES`, beside the dependencies'
  `DEPENDENCY_MODULES`) generates with a `naming::shadowing_module`
  warning, one per module (`naming_shadowing_module` case). Generated
  code imports none of those packages, so the module compiles, but an
  application that depends on the package cannot import it: Elm reports
  the import as ambiguous. A warning, not an error, because an
  application that never imports the package's module (a worker that
  never imports `Html`) is fine. Escape: `rename` the package or type,
  or `module_prefix`.
- Only packages with a requested file are generated: protoc's
  `file_to_generate`, or the files named to the CLI. *(Decided,
  2026-10-15.)* Each is generated in full, from every compiled file that
  declares it (protoc's `proto_file` holds every import): its types, its
  enums and its services, so a package's module is the same whichever of
  its files were asked for (`packages_whole` case). Before, a package
  was built from its requested files alone, and a field whose type was
  declared in an unrequested file of the same package was silently
  dropped. A file without a package is not one package with the other
  files without one; only requested ones are taken, each
  `naming::invalid_module`.
  A generated package that refers to a package with no requested file
  is `generate::not_generated` (`packages_not_generated` case), the
  request and response types of methods included (`services_invalid`
  case). It points at the reference, names the file to add, and names
  the ways to add it: `buf generate --include-imports`, the file on
  protoc's command line, or the CLI's `--include-imports` (§6), which
  adds the imported files declaring what the named files' packages
  refer to, transitively.
  `google.protobuf` is never generated as a package: its supported
  types map to the runtime (§3.5), and the rest are
  `types::unsupported_well_known`.
  Nor are the googleapis files that declare the options the generator
  reads, `google/api/http.proto`, `google/api/annotations.proto` and
  `google/api/field_behavior.proto`, the ones the CLI embeds
  (`googleapis::FILES`, §4; `googleapis::is_embedded`).
  The plugin drops them from `file_to_generate`, and the CLI's
  `--include-imports` never adds them, as it adds no file nothing refers
  to (§6). Why: they are options plumbing, not API types, and `buf
  generate --include-imports` asks for every import, so every API with
  HTTP rules would otherwise get a `Google.Api` module of `Http`,
  `HttpRule` and `CustomHttpPattern` that nothing refers to (and every
  API with field behaviors one of `FieldBehavior`). The rule
  is by file name and no wider: other `google/api` files, such as
  `httpbody.proto`, declare types APIs take and return, and generate
  when asked for. `just live-gen` runs the notes example under `buf
  generate --include-imports` and checks it gives the committed files.
  Why not generate the closure by default: a protoc plugin generates
  `file_to_generate` and resolves the rest from `proto_file`, and buf
  already offers the closure as an opt-in (`--include-imports`, and
  `--include-wkt` for the well-known types). Under buf's per-directory
  strategy each plugin run gets one directory's files; a plugin that
  also wrote its imports' packages would have two runs write the same
  module (`Users/V1.elm`), and buf rejects a duplicate output path.
  A reference to another generated package is qualified with its module
  (`Users.V1.User`, `Users.V1.RoleUnspecified`), which is imported
  plainly, without an alias or an exposing list (`packages` case).
- **Comments and declaration lines.** *(Decided, 2026-10-20.)* The
  declaration a proto element becomes is documented with the proto's
  comment for it and the element's one-line declaration, as a reader of
  Java's, C++'s or protobuf-es's generated code finds them (a method's
  and a service's: §4). Every doc gives the comment first and the
  declaration after it. A message's record alias carries its comment,
  `` `message notes.v1.Note` `` and an item per record field: the Elm
  name, the field's comment, then its `google.api.field_behavior` as
  words (`` `title`: The title, shown first. Required. ``; `Output
  only.`, `Input only.`, `Immutable.`, `Identifier.`, `Unordered.`;
  `OPTIONAL` and `NON_EMPTY_DEFAULT` are not written), a oneof's item
  its comment and its custom type's name. The field's full declaration
  is on its descriptor value, so the list stays readable. An enum's
  custom type carries its comment, `` `enum notes.v1.Visibility` `` and
  an item per constructor with its value's proto name and its aliases'
  (`` `VisibilityPublic` (`VISIBILITY_PUBLIC`, also `VISIBILITY_OPEN`) ``),
  the value's comment and `Deprecated.` if it is (values are not broken
  out of their enum's doc; the numbers are on the descriptor); a oneof's
  custom type its comment, `` `oneof kind` of `notes.v1.NoteEvent` ``
  and an item per constructor, shaped as a field's. A descriptor's doc
  is the comment and the declaration line, nothing more: the module
  name says whose it is. A field's descriptor value carries the field's
  comment and line, `, in oneof kind` for a member (so a field's comment
  is in both places), and an enum's descriptor every declared name with
  its line and comment; codecs, defaults and typed values get one
  sentence naming their type, and no proto text, and `registry` two
  saying what it holds and resolves. A deprecated element's
  doc starts with `Deprecated.`, a field's item with it. A comment of
  several paragraphs stays whole in its item, which makes the list
  loose (blank lines between items), as Markdown does.
  Modules carry docs too. A package's module has the package's
  comment: each file's leading comment on its `package` statement or,
  where that has none, on its `syntax` statement, where a file's
  overview often sits (a trailing comment on either line is left out),
  as paragraphs in file order, a comment that several files repeat
  written once; a package with none has no module doc. A service's
  module has the service's comment and its declaration (§4). A
  descriptor module has one line naming what it holds
  (`` The descriptor of `notes.v1.Note` and its fields. ``,
  `` The descriptor of `notes.v1.Visibility`. ``); the message's
  comment stays on its `descriptor`.
  The docs link to each other as the package site and elm-doc-preview
  resolve links, `#name` within a module and `Module-Name#name` (dots
  as dashes) to another: a type's declaration line to its descriptor
  module's `descriptor` (`` [`message notes.v1.Note`](Notes-V1-Note#descriptor) ``),
  each field item's name to its descriptor value, a oneof item to its
  custom type, a member's constructor to its value; a `descriptor`
  back to its type (`` Describes [`Notes.V1.Note`](Notes-V1#Note). ``);
  codecs, defaults, typed values and wrappers to the type they name; a
  call to its descriptor. A runtime
  type a doc names (`Proto.Any.Any`) links to the package site by
  absolute URL, which an editor's hover makes clickable, at `latest`,
  since the site has no per-major path and `elmConnectVersion_`
  already pins the minor version.
  The comment is the leading comment, then the trailing one as a
  paragraph of its own; detached comments are left out, as
  protoc-gen-go and Java leave them out. Each line loses the space
  after `//` and trailing whitespace, and blank lines stay as paragraph
  breaks. A declaration line is rebuilt from the descriptor in canonical
  spacing, never copied from the source and never a body: the type by
  keyword or full name, `map<K, V>`, `optional` only for a proto3
  optional field, and the options in brackets as a proto writes them,
  `json_name` (when set) first and custom options in parentheses
  (`[json_name = "heading", (google.api.field_behavior) = REQUIRED]`),
  each value in protobuf's text format on one line. Why the line: it
  says what the Elm type does not (the field number, the proto type
  behind an `Int` or a `String`, the options), in one line rather than
  the body Java and C++ print for a message. Elm comments nest, so
  `{-` and `-}` in a comment are written `{ -` and `- }`. elm-format
  re-renders a doc comment's Markdown, and generated code must be in
  its form (`elm-format --validate`, §7), so the printer puts every doc
  comment there: it ports the Markdown parser elm-format 0.8.8 vendors
  and its printer (`elm::markdown`), and repeats them until the text
  stops changing. Lists become `  - ` and `1.  `, emphasis `_` and
  `**`, setext headings `#`, a bare URL `<url>`; `\`, `` ` ``, `_` and
  `*` in text are escaped; tabs become spaces; lines are never
  reflowed. Where elm-format would lose text, the printer keeps it
  instead in a form elm-format leaves alone: code elm-format would
  format as Elm (indented, or fenced without a language or as `elm`) is
  fenced as `text`, since a proto comment's code is not Elm and
  formatting it as Elm rewrites it (`GET /v1/notes` becomes
  `GET / v1 / notes`); a line starting `@docs`, which elm-format would
  read as a list of names, sets `@docs` as code; a heading after the
  first block of a list item, which elm-format would move out of the
  list, becomes strong text; a link reference definition it cannot
  read back is kept as code; an empty code block, on which elm-format
  fails, is dropped. Each comment is settled on its own before it is
  placed among the declaration's items, so a fence it leaves open
  cannot take in what follows (`comments` and `comments_awkward`
  cases).

### 3.2 Messages

- A record type alias per message. Nested messages are flattened into
  the package module with the outer name as a prefix
  (`Outer.Inner` → `OuterInner`). *(Decided.)*
- The record's fields are in declaration order, the order the `.proto`
  file writes them in, not field-number order; a oneof's field sits
  where its first member is declared (§3.6). *(Decided.)* The
  record's constructor is positional, so this order is API, and the
  defaults, descriptors (§3.9), encoders and decoders follow it too.
  Field-number order was considered: the record would survive a
  cosmetic reordering of the file, and prost-reflect's `fields()` gives
  it by accident. Rejected, since the record should read beside the
  proto in its author's grouping, peer generators emit file order, and a
  new field changes the positional constructor under either order, so
  neither is stable under appends. The `field_order` conformance case
  pins it.
- Scalars use proto3 zero values directly, not `Maybe`. *(Decided.)* A
  missing JSON field decodes to the zero value, and `null` decodes to
  the zero value, matching proto3 JSON.
- Message-typed fields are `Maybe`. proto3 `optional` fields are
  `Maybe`. *(Decided.)*
- `repeated` → `List`. `map<K, V>` → `Dict K V` with `K` restricted to
  `String` and `Int` as proto allows. *(Decided.)*
  `string` and 64-bit integer keys give `Dict String V`, 32-bit
  integer keys `Dict Int V`. JSON object keys are strings, so integer
  keys are read from their decimal strings and written with
  `String.fromInt` (32-bit) or as held (64-bit). Every integer key is
  validated and canonicalised like a value of its kind, by a decoder
  per kind: `Proto.Json.int32Dict` (−2^31 to 2^31 − 1), `uint32Dict`
  (0 to 2^32 − 1), `int64Dict` (−2^63 to 2^63 − 1), and `uint64Dict`
  (0 to 2^64 − 1). Each reads
  a key as `Proto.Json.int64` reads a string, so `"07"`, `"-0"` and
  `"1e2"` are keys and `"+5"`, `"1.5"` and `"abc"` are not. A 64-bit key is held
  in the canonical decimal form `int64` gives (`"007"` is the key
  `"7"`). Two keys that canonicalise to one (`"7"` and `"07"`) fail the
  decode, naming both, rather than one silently replacing the other.
  protobuf's own parsers (protobuf-go's protojson) reject the same keys:
  out of range, not an integer, or a duplicate. *(Decided 2026-10-19;
  32-bit keys were checked only against the span of the signed and
  unsigned types together, and 64-bit keys not at all, before.)*
  An absent or `null` map decodes as `Dict.empty`.
- `map<bool, V>` → `List ( Bool, V )`. *(Decided.)* The Elm form is an
  association list because `Bool` is not `comparable`; a map has at
  most two entries. The encoder (`Proto.Json.boolMapField`, through
  `Proto.Json.encodeBoolMap`) writes a
  JSON object keyed `"true"` and `"false"`; the decoder
  (`Proto.Json.boolMap`) reads one, fails on any key but exactly
  `"true"` or `"false"`, and gives the pairs in the object's key order.
  An absent or `null` map decodes as `[]`. A `bool` key was first a
  diagnostic, and `Dict String V` keyed by `"true"`/`"false"` was
  considered; both hid the proto type.
- Empty messages (zero fields) become `type alias Foo = {}`. *(Decided.)*
  The decoder (`Proto.Json.emptyMessage`) accepts any JSON object,
  ignoring its keys, and fails on anything else, as every other message
  does. *(Decided 2026-10-19; it accepted any JSON before.)*
- Every message gets `defaultFoo`, so callers write
  `{ defaultFoo | title = "x" }` and
  `Maybe.withDefault defaultFoo.stars msg.stars` without knowing the
  proto default. *(Decided.)* `defaultFoo : Foo` holds every field at
  its proto3 default, the value it decodes to when absent: `0`, `0.0`,
  `False`, `""`, `"0"` for a 64-bit integer held as a `String` (`0` as
  an `Int`), an enum's zero constructor, `Nothing`, `[]`, `Dict.empty`,
  `()` for `Empty`, and each oneof's
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
  *(Decided.)* The shape:

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
- **A nested enum's prefix.** *(Decided, 2026-10-21.)* The conventional
  prefix is the enum's own name in `UPPER_SNAKE_CASE`, as the protobuf
  style guide, buf's `ENUM_VALUE_PREFIX` lint rule and AIP-126 write
  it, and for a nested enum its whole nesting path is accepted as well:
  the longer of the two the value starts with is stripped, so in
  `message Note { enum Kind { … } }` both `KIND_DRAFT` and
  `NOTE_KIND_DRAFT` → `NoteKindDraft` (`nesting` case). Before, only the
  own name was stripped, and `NOTE_KIND_DRAFT` became
  `NoteKindNoteKindDraft`. Two values that stripping makes one
  constructor (`KIND_DRAFT` beside `NOTE_KIND_DRAFT`) are
  `naming::constructor_collision`, with `rename` the escape.
- Encoding uses the proto name string. Decoding accepts the name and
  also the integer form, as the JSON spec allows. *(Decided.)*
- **Unknown values.** *(Decided.)* An unknown **number**
  decodes to the zero-value constructor: forward-tolerant, so a stale
  client survives a server that added a value, and lossy, since
  re-encoding sends the zero value's name back (§3.8). An unknown
  **name** fails the decode, as protobuf-go's protojson does:
  `Expecting a value of enum "Priority", but got "WHATEVER"`, the enum
  named as declared within its package (`Outer.Inner.Kind` when
  nested). A name is matched exactly.
- **`enum_unknown=fail|zero`.** *(Decided, 2026-10-14.)* The
  default, `fail`, is the behaviour above. `zero` reads an unknown
  **name** as the zero value too, so nothing a JSON string or integer
  holds fails an enum's decode (`Proto.Json.enumOrZero`, same arguments
  as `Proto.Json.enum`; `enums_unknown_zero` case). It is for an
  application whose clients outlive server deploys, where a value the
  server adds reaches an old client as a name and must not fail the
  whole message; proto3's convention that the zero value means
  "unspecified" is what makes reading it there sound. `fail` stays the
  default because strict is the default and escapes are options, and a
  silently zeroed value is a dropped distinction (§3.8).
  `Proto.Enum.fromName` and `fromNumber` are lookups, not decodes, and
  give `Nothing` for an undeclared name or number under either value.
  An `<Enum>Unrecognized Int` constructor, faithful and re-encoding
  what was received, will come as an option and never as the default:
  as the default, every `case` on an enum would gain a branch nobody
  wants to think about ([decisions.md](decisions.md), roadmap).
  `zero` was built first because it needs no change to the generated
  types.
- Generated shape *(Decided)*: the encoder is a `case` with one
  `Json.Encode.string "NAME"` branch per constructor, so the compiler
  checks it is total. The decoder is one call to the runtime's
  `Proto.Json.enum` (`Proto.Json.enumOrZero` under `enum_unknown=zero`),
  given the enum's proto name, the zero
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
| `bytes` | `String` (base64, as on the wire), or `Bytes` under `bytes=bytes` | *(Decided 2026-10-19; see below.)* |

Encoders leave out every field at its default. *(Decided.)*
A message's encoder is `Proto.Json.objectOfFields` over `( jsonName, Maybe
Json.Encode.Value )` pairs, one per field, `Nothing` leaving the field
out:

- A field without presence (a plain scalar or enum) is left out at its
  proto3 default (`Proto.Json.implicitField zero encoder value`: `0`, `"0"`,
  `""`, `False`, the zero enum value); a float only at `0`
  (`Proto.Json.implicitFloatField`), so `-0`, NaN and the infinities are
  written, `-0` as `0`: JavaScript's JSON writer has no negative zero,
  and a server reads `+0` either way.
- A field with presence (`Maybe`: `optional`, a message, a wrapper,
  `Timestamp`, `Duration`, `FieldMask`, `Struct`, `ListValue`, `Value`,
  `Any`) is left out when `Nothing` and written when `Just`, at its
  default too (`Just 0` writes `0`, `Just` an empty message writes `{}`,
  `Just Json.Encode.null` writes `null`): presence is what the `Maybe`
  says (`Maybe.map encoder value`, or the `Value` field's own `Maybe
  Json.Encode.Value`).
- A oneof's set member is always written, at its default too; an unset
  oneof writes nothing (§3.6).
- A repeated or map field is left out when empty (`Proto.Json.repeatedField`,
  `Proto.Json.dictField`, `Proto.Json.boolMapField`).
- An `Empty` field always writes `{}` (§3.5).

Why: request bodies shrink to what the message holds; protobuf-go's
`protojson`, and so connect-go, writes the same way unless
`EmitUnpopulated` is set; and every proto3 JSON parser, this runtime's
decoders included, reads a missing field as its default, so nothing is
lost. Encoders wrote every field, defaults included and `Nothing` as
`null`, until 2026-10-15; proto3 JSON allows both.

Decoders accept every form proto3 JSON requires a parser to accept, not
just the form encoders write. *(Decided.)*

- 32-bit integers as numbers or strings, in exponent notation too
  (`42`, `"42"`, `1e2`, `"1e2"`), through `Proto.Json.int32` (`int32`,
  `sint32`, `sfixed32`) and `Proto.Json.uint32` (`uint32`, `fixed32`).
  A fractional value fails, and so does one outside the proto type's
  range: −2^31 to 2^31 − 1 signed, 0 to 2^32 − 1 unsigned. *(Decided.)*
  A string is read as `Proto.Json.int64` reads one, then range-checked,
  so `"007"` is 7 and `"+5"`, `"1.e3"` and `"0x10"` fail, as they do
  for a 64-bit value and for every integer map key. *(Decided
  2026-10-19; a string went through `String.toFloat` before, which
  took `"+5"`, `"1.e3"` and `".5e1"`.)*
- Floats as numbers, numeric strings, and `"NaN"`, `"Infinity"`,
  `"-Infinity"`; 64-bit integers as strings or numbers, in exponent
  notation too (`"1e3"`, `"1.5e3"`, `1E2`, `"-2e0"`). *(Decided.)* The
  `String` form (`Proto.Json.int64`) is always the canonical decimal
  string (`"1000"`, `"1500"`, `"100"`, `"-2"`; `"007"` reads as `"7"`),
  found by moving the decimal point as text, never through a `Float`,
  so a string past 2^53 keeps every digit. A value that is not an
  integer (`"1.5e0"`) fails, and so does one outside its type's range:
  −2^63 to 2^63 − 1 for `Proto.Json.int64`, 0 to 2^64 − 1 for
  `Proto.Json.uint64`, checked by comparing the canonical digits with
  the bound's as text, by length and then digit by digit, so no `Int`
  arithmetic rounds them. *(Decided 2026-10-19; before, any value of up
  to 20 digits passed, `"99999999999999999999"` included.)* More than
  20 digits fails before the digits are written out, which bounds the
  text an exponent can ask for. A JSON number past 2^53 has been
  rounded by the JSON parser before the decoder sees it, and is checked
  as JavaScript writes it, so the bounds themselves fail as numbers
  (`9223372036854775807` reads as `9223372036854776000`); proto3 JSON
  writes 64-bit integers as strings, where every digit is kept.
  `Proto.Json.int64AsInt` reads the same forms within its range. A
  64-bit map key is validated, range-checked and canonicalised the same
  way (§3.2).
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
  helper (`memberEither`, `emptyMemberEither`, `valueMemberEither`,
  `valueFieldEither`). The
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
- A step finds its field with `Json.Decode.field` (JavaScript's `in`),
  in constant time, so a message decodes in time linear in its fields
  rather than reading the whole object once per field. `in` also finds
  inherited properties, so a field named after one of
  `Object.prototype`'s (`constructor`, `toString`, `__proto__`, …) is
  looked up among the object's own keys instead, in time linear in
  them. A message fails on any JSON that is not an object, arrays
  included, whether or not it has fields; when no field is present the
  check is constant-time too, and never lists the keys, and an empty
  message (`Proto.Json.emptyMessage`) makes the same check. The package requires elm/json 1.1.4,
  which lists an object's keys without calling the object's own
  `hasOwnProperty`, so a key of that name decodes wherever keys are
  listed: a prototype-named field, a map, a `Struct` or an `Any`.

**Bytes** *(Decided 2026-10-19.)* The rule:

- By default a `bytes` field is a `String` holding the base64 text
  exactly as received; nothing normalises it. `Proto.Json.bytes`
  validates it at decode time: the standard alphabet (`A`–`Z`, `a`–`z`,
  `0`–`9`, `+`, `/`) or the URL-safe one (`-`, `_`), not both in one
  string, with or without `=` padding. It fails on any other character,
  on a length no base64 has (after stripping the padding, length mod 4
  is 1), and on padding that does not complete the last group to four
  characters. The encoder writes the string unchecked. The zero value is
  `""`, the base64 of no bytes.
- The option `bytes=bytes` makes every `bytes` value elm/bytes'
  `Bytes`: singular `Bytes`, `optional` `Maybe Bytes`, repeated
  `List Bytes`, a map value `Dict K Bytes`, a oneof member `… Bytes`,
  and the `BytesValue` wrapper `Maybe Bytes` (bare `Bytes` repeated or
  as a map value, as for the other wrappers). The decoder
  (`Proto.Json.bytesAsBytes`) accepts what `Proto.Json.bytes` accepts;
  the encoder (`Proto.Json.encodeBytesAsBytes`) writes the standard
  alphabet with `=` padding, as proto3 JSON writers do, so a value does
  not re-encode as the text it arrived as. The zero value is
  `Proto.Bytes.empty`.
- `Proto.Bytes` converts either way (`fromBase64`, `toBase64`) for an
  application on the `String` default that wants the bytes at one
  place. It is always there, whatever the option.
- Elm's `==` does not look inside a `Bytes` value: any two compare
  equal, whatever they hold (elm/bytes 1.0.8: `encode (unsignedInt8 1)
  == encode (unsignedInt8 2)` is `True`), because the kernel compares a
  `DataView` by its enumerable keys, of which it has none. So a record
  holding a `Bytes` field equals one differing only there, `Expect.equal`
  passes when it should fail, and a model's change check misses the
  change. Generated code does not use `==` on such a field: a singular
  one is left out at its default by its width (`Proto.Json.implicitBytesField`)
  rather than through `Proto.Json.implicitField`, which would leave out every
  value. `docs/generator.md`'s option row and `Proto.Bytes`'s documentation say
  this where a user meets `Bytes`.
- Why `String` stays the default: the trap above. A record of `String`s
  compares, tests and diffs as its users expect; one holding `Bytes`
  silently does not, which is a bad thing to hand anyone who did not ask
  for it. `Bytes` by default was rejected for that reason.
- Why in the runtime: a separate `elm-connect-bytes` package, depending
  on elm/bytes so the runtime would not, was the earlier plan. It is not
  needed: elm/http, which the runtime requires, already depends on
  elm/bytes, so every application has it and the runtime's direct
  dependency adds nothing to install.
- A per-field override, as `jstype` is for 64-bit integers, is deferred.
  Protobuf's `jstype` is valid only on 64-bit integer fields (protoc
  rejects it elsewhere), so there is no standard field option to read;
  an override would be a generator option naming fields, additive later.
  No custom proto option is defined for it.

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
  `String` under either setting, since they are strings on the wire,
  but are validated and canonicalised as the `String` form's values are,
  and two keys that canonicalise to one fail (§3.2). *(Decided.)*
- The unsigned 64-bit kinds refuse a negative value when decoded
  (`Proto.Json.uint64`, `uint64AsInt`), as the 32-bit ones do; the
  encoders are the signed ones. *(Decided 2026-10-14; a negative
  `uint64` decoded before.)*
- Rejected: an opaque `Proto.Int64.Int64`, as protoc-gen-elm has.
  *(Decided.)* A 64-bit value a program mostly passes
  through or displays, such as an ID, a revision or a count, gains
  nothing from a wrapper it must unwrap to show or compare;
  `int64=int` and `jstype` exist for arithmetic within 2^53; and
  `Proto.Int64.toInt` and `fromInt` convert at the edge. The cost
  accepted is that an `int64` field and a `string` field have the same
  Elm type, so the compiler does not tell them apart. `bytes` is the
  same choice for the same reasons: a base64 `String` by default, with
  `bytes=bytes` as the typed escape and `Proto.Bytes` converting at the
  edge, rather than an opaque wrapper (see **Bytes** above).

### 3.5 Well-known types

The runtime provides the Elm types.

| proto | Elm | notes |
|---|---|---|
| `google.protobuf.Timestamp` | `Time.Posix` | RFC 3339 parse/print in the runtime; no third-party date package |
| `google.protobuf.Duration` | `Proto.Duration` (opaque; `toSeconds : Duration -> Float`) | Elm has no duration type; `"1.5s"` on the wire |
| `google.protobuf.FieldMask` | `List String` | comma-separated on the wire |
| `google.protobuf.Empty` | `()`, without presence | *(Decided; see below)* |
| `google.protobuf.Struct` | `Dict String Json.Encode.Value` | a JSON object; *(Decided; see below)* |
| `google.protobuf.ListValue` | `List Json.Encode.Value` | a JSON array; *(Decided; see below)* |
| `google.protobuf.Value` | `Json.Encode.Value`; a singular field `Maybe Json.Encode.Value` | it *is* JSON; *(Decided; see below)* |
| `google.protobuf.*Value` wrappers | `Maybe` of the scalar | null or the value on the wire |
| `google.protobuf.Any` | `Proto.Any.Any` (opaque: type URL and payload) | *(Decided)* the message's JSON plus `"@type"` on the wire |

The in-house generator mapped `Timestamp` to `String` to avoid a
dependency. With a runtime package required anyway (for the transports),
the parser lives there and `Time.Posix` is the right type.

In detail:

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
- A singular `Value` field, `optional` or not, is `Maybe
  Json.Encode.Value`. *(Decided, 2026-10-19.)* `Value` is a message, and
  `null` is one of its values: protojson reads `"payload": null` as set,
  holding `NullValue`, and only a missing key as unset. So a missing key
  is `Nothing`, and any JSON under the key is `Just` it, `null` included
  (`Just Json.Encode.null`); `Nothing` leaves the field out and `Just`
  writes its JSON, `null` too. The step is `Proto.Json.valueField`
  (`valueFieldEither` when the names differ), which reads `null` as set
  where `field` reads it as the default. This keeps a default message
  `{}` and matches `Struct` and `ListValue`. It replaces a bare
  `Json.Encode.Value` that read a missing key as `null` and always wrote
  the field, so a client that never touched it sent `null` and the
  server saw it set. Repeated, as a map value and as a oneof member it
  stays a bare `Json.Encode.Value`, passed through as received
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
  `Float` views (`fromSeconds`, `toSeconds`) are exact to the nanosecond
  only below 2^53 ns (about 104 days); `fromMilliseconds` and
  `toMilliseconds` are exact. Printed with 0, 3, 6 or 9 fractional
  digits, the fewest that keep every nanosecond, as protobuf does;
  `-0s` reads as zero and prints `0s`. The range is protobuf's,
  ±315,576,000,000 s. `fromString` refuses a duration past it;
  `fromSeconds` and `fromMilliseconds` give the limit for one past it
  (nanoseconds zero), and `fromSeconds` gives zero for NaN and the
  infinities, so every `Duration` prints as text `fromString` reads.
  *(Decided 2026-10-19; they built any span before, which `toString`
  wrote and `fromString` refused.)* The readers are `toSeconds` and
  `toMilliseconds`, as `Proto.Int64.toInt` and `Proto.Bytes.toBase64`
  are, and not the nouns `seconds` and `milliseconds`: elm-units names
  its constructor `Duration.seconds`, so the noun would read as the
  opposite conversion. *(Decided.)*
- `FieldMask`: the Elm list holds paths with proto field names
  (`"author.email_address"`); the wire form joins them with commas and
  writes each field name in lowerCamelCase, as proto3 JSON requires.
- `Any` is in the runtime as `Proto.Any` *(Decided)*: an opaque `Any`
  holding the type URL and the packed message, either as its JSON or, when only
  its protobuf binary arrived, as that binary (base64) alone. `pack`
  (prefix `type.googleapis.com/`) and `packWith` (another prefix) take
  the message's typed value (§3.9) and a value; `unpack` gives
  `Nothing` for another type (by full name, the type URL after its last
  `/`), else the decoded value or a `Problem`: `Json` for JSON that
  does not decode, `BinaryOnly` for a binary payload, which the
  runtime does not read. `is` tests the type, `typeUrl` and
  `typeName` read it, and `describe` looks its descriptor up in a
  `Proto.Registry`. `Proto.WellKnown.any : Message Any` is its typed value,
  and `Proto.Registry.wellKnown` holds its tree (`type_url`, `value`).
- `Any` on the wire is proto3 JSON's: the packed message's own object
  plus `"@type"`, or, for a well-known type with a JSON form of its own
  (`Timestamp`, `Duration`, `FieldMask`, `Empty`, `Struct`, `Value`,
  `ListValue`, the wrappers and `Any` itself), `{"@type": …, "value":
  <that form>}`. The codecs are `Proto.Json.any` and
  `Proto.Json.encodeAny`, beside every other well-known type's, and that
  list lives with them. `Proto.Json.any` fails
  on an object without `"@type"`, except `{}`, which is the empty `Any`
  (no type URL; the typed value's default), as protojson reads it. A
  binary-only `Any` has no proto3 JSON form; `encodeAny` writes it as
  a Connect error detail, `{"type": <name>, "value": <base64>}`, which
  `Proto.Json.any` does not read back. *(Moved from
  `Proto.Any.encodeJson` and `jsonDecoder` 2026-10-19, so that generated
  code reaches every well-known type's codecs through `Proto.Json`.)*
- A field of `Any` is a message field, so a singular one is a
  `Maybe Proto.Any.Any`; repeated it is `List Proto.Any.Any`, as a map
  value `Dict K Proto.Any.Any`, and a oneof member holds it bare. It is
  encoded and decoded with `Proto.Json.encodeAny` and `Proto.Json.any`,
  and its descriptor kind is `Message "google.protobuf.Any"`. A method
  taking or returning one uses those codecs too (`any_field` case). It was the `types::any` diagnostic until `Proto.Any` existed:
  decoding one needs the registry the descriptors give, and unpacking
  is left to the application, which knows the types it expects.
- An `Any` field has no query form: its JSON is the packed message's,
  whose fields the route cannot know (`route::query_field`, §5.3).

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

In detail:

- The record holds the oneof's field where its first member was
  declared, so the record constructor's argument order follows the
  proto.
- The oneof's encoder gives the set member as a one-element list of
  `( jsonName, Just value )`, or `[]` when unset, and the message's
  encoder appends it to its fields: `Proto.Json.objectOfFields ([ ... ] ++
  encodeNoteEventKind value.kind)`. The member is written at its
  default too: being set is what a oneof says (§3.4).
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
  underscore (`type` → `type_`). *(Decided.)* A name starting with
  capitals or underscores is converted too: after the underscores are
  dropped, the leading run of uppercase letters is lowercased, except
  that a run followed by a lowercase letter keeps its last letter, which
  starts the next word. `Label` → `label`, `ID` → `id`, `URLPath` →
  `urlPath`, `HTTPRequest` → `httpRequest`, `XCoord` → `xCoord`,
  `_internal` → `internal`, `__Label` → `label`. A run of two or more
  followed by a lone `s` (then the end, an uppercase letter, a digit or
  `_`) is a plural acronym, lowercased with its `s`: `IDs` → `ids`,
  `URLs` → `urls`, `APIs` → `apis`, `UUIDs` → `uuids`, `IDsSeen` →
  `idsSeen`. *(Decided, 2026-10-21.)* The rule cannot tell `ID` + `s`
  from `X` + `Is`, so `XIs` → `xis` too; that misreading is accepted,
  and a `rename` gives such a name another. Before, `IDs` became `iDs`
  (`URLs` `urLs`). Methods, oneofs
  and oneof members' descriptor values follow the same rule (`HTTPGet` →
  `httpGet`, `_Ping` → `ping`); types, enum constructors, modules and
  services do not (a message `URLPath` stays `URLPath`), and neither
  does a `rename`, which is taken as written. A name that is only
  underscores, or has a digit before its first letter (`_1x`), is still
  `naming::invalid_field` or `naming::invalid_method`: any Elm name for
  it would be invented. *(Decided, 2026-10-20; `naming_first_letter`
  case.)* Refusing a name that did not start with a lowercase letter was
  the first build.
- Collisions after casing (`foo_bar` and `fooBar` in one message, or
  a oneof `ID` beside a field `id`, which protoc accepts since it checks
  only fields' JSON names against each other) are
  `naming::field_collision`, not a silent rename. This is about
  collisions only: converting one name to its Elm form is not a rename.
  *(Decided.)*
- Nested messages and enums are flattened into their package's module,
  prefixed with the names of the messages enclosing them:
  `Outer.Inner` → `OuterInner`, `Outer.Inner.Kind` → `OuterInnerKind`.
  *(Decided.)* A submodule per message (`Pkg.Outer.Inner`)
  was considered and rejected: a parent referring to its own nested
  type would be an Elm module cycle. The descriptor modules (§3.1) are
  flat for the same reason, `Notes.V1.OuterInner` beside `Notes.V1.Outer`,
  and hold no types, so a message containing itself or its nested type
  needs no import between them (a field names a message by full name).
  *(Confirmed 2026-10-19: a descriptor module follows its type's Elm
  name, so one naming rule names both.)*
- Type names that collide after nested-message flattening are a
  diagnostic. *(Decided.)*
- **Windows device names.** *(Decided, 2026-10-21.)* A module path
  segment that is, ignoring case, `CON`, `PRN`, `AUX`, `NUL`, `COM1` to
  `COM9` or `LPT1` to `LPT9` is `naming::reserved_module` on every OS,
  as case-only module collisions are (§3.8): each segment is a
  directory or a file (`Notes.V1.Con` is `Notes/V1/Con.elm`), Windows
  reserves those names whatever the extension, so the file cannot be
  created there, and git refuses to check it out. A message `Con` and a
  package `devices.aux` are refused (`naming_reserved_module` case); a
  package's problem covers the modules inside it. Escape: `rename`. An
  option to accept them, for output that never reaches Windows, may
  come if asked; it is not built.
- **The refusals kept for 1.0.** *(Decided, 2026-10-21.)* Each of these
  stays a refusal, because any name the generator invented in its place
  would be unpredictable, or would depend on what else the protos
  declare, so that adding a message in a minor release of an API could
  silently rename an existing type. Each has an escape, and an escape
  added later is additive:
  - a name with no letter before its first digit, or only underscores
    (`_1x`, `_`): `naming::invalid_field`, `invalid_method`,
    `invalid_type`, `invalid_service`, or `invalid_module` for a package
    segment; escape `rename`, but for a oneof member's descriptor value,
    which follows the proto name: rename the member in the proto;
  - a file without a package: `naming::invalid_module`; escape: declare
    a package;
  - names that collide after casing (`display_name` beside `oneof
    displayName`, `Book` beside `book`, `GetNote` beside `get_note`, a
    service module beside a package's): the `naming::*_collision`
    codes; escape `rename` one of them;
  - a oneof beside a nested type of the same name (`oneof kind` and
    `message Kind`, both `XKind`): `naming::type_collision`; escape
    `rename` the oneof, which renames its type;
  - module names that differ only in case (`ShopItem`, `Shopitem`):
    `naming::module_collision` on every OS; escape `rename`;
  - reserved names: a type or constructor its module uses for a
    library's (`naming::reserved_name`), a module of the runtime or of
    its dependencies, or a Windows device name (`naming::reserved_module`);
    escape `rename`, and for a module `module_prefix`.

  Two module names compile and are warnings instead: one in the
  runtime's namespaces (`naming::runtime_namespace`) and one of an
  application's elm/* packages (`naming::shadowing_module`), both
  escaped by `module_prefix` or `rename` (§3.1).

- **Field names the front end refuses.** *(Decided, 2026-10-21.)* Two
  fields of one message whose names are the same once lowercased
  without underscores (`aB` and `ab`, `ID` and `id`, `ID` and `Id`)
  never reach the naming rules: prost-reflect, which both binaries build
  their descriptors with, refuses them in any file but a proto2 one,
  while protoc accepts them, since it compares only the fields' JSON
  names. The refusal comes before any option applies, so `rename`
  cannot help; the escape is renaming a field in the proto. It is
  `input::field_name_conflict`, in elm-connect's words, rather than the
  library's uncoded text, since codes freeze at 1.0 (§8.3). Accepting
  such fields as protoc does, once the library's rule matches protoc's,
  turns an error into output, a minor ([roadmap](roadmap.md)); those
  whose Elm names are the same (`ID` and `id`, both `id`) would then be
  `naming::field_collision`, as a field and a oneof are today.

As the `naming` and `naming_collision` cases show:

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
  `HttpMethodGet`), and a nested enum's prefix may be its own name or
  its whole path (`Outer.Inner.Kind`: `KIND_DRAFT` and
  `OUTER_INNER_KIND_PUBLISHED` → `OuterInnerKindDraft`,
  `OuterInnerKindPublished`; §3.3).
- An enum claims one constructor per number: an alias (§3.3) has no
  constructor, so its would-be name (`PRIORITY_LOW` beside `LOW`, both
  `PriorityLow`) is not a collision.
- A package module's top-level values are a prefix and a type name:
  `encodeFoo`, `decodeFoo`, `defaultFoo`, `messageFoo` and `enumFoo`
  (§3.9). Type
  names are unique in a module and start with an uppercase letter, and
  no prefix is another's, so these never collide. The one other,
  `registry`, is all lowercase, so it is none of them. A suffix scheme was
  rejected for the typed values: `encodeFooMessage` would be both the
  encoder of `FooMessage` and the typed value of `EncodeFoo`.
- A descriptor module's values are `descriptor` and one per field,
  named as its record field, but that a field or member named
  `descriptor` takes `descriptor_` (§3.1). A oneof member has no record
  field, so its value is the end of its constructor converted by the
  field rule: `NoteEventKindCreated` gives `created`, `URL` gives `url`,
  and `_legacy`,
  whose constructor is `EventKindLegacy`, gives `legacy`
  (`oneofs_member_underscore` case). It is the derived constructor's
  end, so a member's `rename`, which renames the constructor, leaves it
  alone; a member whose name has no letter after its leading
  underscores (`_1x`) has a constructor but no value, and is
  `naming::invalid_field` (`oneofs_member_invalid` case). A renamed
  field that meets another field's or a member's name is
  `naming::value_collision`, naming both (`descriptors_value_collision`
  case).
  A field named like a value Elm imports by default (`max`, `min`,
  `always`) needs nothing: a descriptor module's own top-level value
  shadows the default import (`descriptors_default_names` case). A
  renamed field or message is named by its new name wherever a route
  names it (`rename_routes` case).
- Two plain fields cannot collide in practice: protoc and protox reject
  a message whose fields' JSON names clash, and the Elm name is the
  default JSON name. The collision a user meets is a field and a oneof
  (`display_name` and `oneof displayName`), which
  `naming::field_collision` reports with both sites.

**Rename map** *(Decided, 2026-10-14)*. The naming rules are
fixed, so a proto name they turn into no Elm name, or into one that
collides, or simply into an unwanted one, needs a way past them that
leaves the protos alone: the option `rename=<proto full name>:<Elm
name>`, repeatable (`--elm-connect_opt=rename=notes.v1.Note:Memo,
rename=notes.v1.Note.title:heading`; CLI `--rename notes.v1.Note:Memo
--rename ...`). `:` separates the two because protoc splits its
parameter on commas and `=` is taken. The given name replaces the
converted one as it is, and what it names decides what it becomes, by
what the proto name resolves to among the generated packages:

- a package (`notes.v1`): its whole module name, dotted (`Notes.Api`);
  its service modules sit under it (`Notes.Api.NotesService`);
- a service (`notes.v1.NotesService`): its module's last segment;
- a method (`notes.v1.NotesService.GetNote`): its value;
- a message or enum, nested ones in proto's dotted form
  (`notes.v1.Note`, `notes.v1.Note.Revision`, `notes.v1.Visibility`):
  its type, flattened or not;
- a field (`notes.v1.Note.title`): its record field;
- a oneof (`notes.v1.Note.kind`): its record field, and its custom type,
  which is named from the oneof (`kind` gives `NoteKind`) and so from
  the new name (`body` gives `NoteBody`, and `NoteBodyUnset`,
  `NoteBodyText`);
- a field of a oneof (`notes.v1.Note.link`): its constructor;
- an enum value, under its enum (`notes.v1.Visibility.VISIBILITY_PUBLIC`,
  though protobuf scopes it beside the enum): its constructor.

Names derived from a renamed one follow it through the rules above: a
type's codecs, default, typed value and descriptor module (`Memo`
gives `encodeMemo`, `defaultMemo`, `messageMemo`, `Notes.Api.Memo`), a
recursive message's wrapper (`Memo_`),
an enum's other constructors (`Audience` gives `AudienceUnspecified`),
a oneof's type and constructors, and a nested type's name (renaming
`Note` to `Memo` makes `Note.Revision` `MemoRevision`, unless it is
renamed too). Wire names, the descriptors and the JSON never change.

The given name must suit its role, or it is `options::invalid_rename`,
naming the role and the rule: a module name's segments (and a service's
one segment) an ASCII uppercase letter followed by letters, digits or
underscores; a type or constructor an ASCII uppercase letter followed
by letters and digits, with no underscore, so it cannot meet a
recursive wrapper's (`Node_`); a value or record field an ASCII
lowercase letter followed by letters, digits or underscores, not ending
in an underscore, and not a reserved word. *(No trailing underscore:
decided 2026-10-21.)* A derived value ends in `_` only as the
reserved-word escape (`type_`) or `descriptor_`, and the generator's
own values end in one (`elmConnectVersion_`), so the promise of §3.1
that a value it adds later cannot collide holds for renamed names too
(`rename_invalid` case). Before, `foo_` and `get_` were accepted, and a
rename to `elmConnectVersion_` was `naming::value_collision`. An enum
value alias has no constructor of its own to
rename, which is `options::invalid_rename` too. A proto name that
resolves to nothing in the generated packages is
`options::unknown_rename`. It names the longest prefix of the name that
resolves, what kind of element that is, and the member it lacks, sited
on that element's declaration, with a suggestion among that element's
members only; or that the element's package is not generated, and how
to generate it; or, when nothing resolves, the generated packages, with
a suggestion among them (`suggestions` and `rename_unknown` cases). Names that collide after renaming are the
`naming::*_collision` diagnostics, as before, and each `naming::*` help
text names the escape, the `rename` of the element at fault by its proto
full name (of a collision's second claimant, when renaming it would part
them), with a placeholder for the Elm name (`rename` and
`rename_invalid` cases). When a rename gave one of them the name, its
site says so ("renamed to `title` by `rename`") and the help points at
that rename instead (`rename_collision` case).

### 3.8 Dead ends

Valid proto constructs whose Elm form drops a distinction the proto
makes, or that the generator refuses with a diagnostic.

The policy *(Decided)*: diagnostics stay the default, and
each diagnostic names its escape, a generator option (§6) that gets the
user past it, in its help text. An escape either generates the
construct some other way or leaves it out; what it leaves out it
reports as a warning (`services::streaming` under `streaming=skip`),
which never fails the run: the CLI prints warnings to stderr, the
protoc plugin likewise (protoc has no other channel for them), and the
library returns them beside the files. Custom proto options spelling
the same escapes in the protos are on the roadmap. The entries
below each say their escape, or "no escape yet".

Dropped distinctions:

- **Sub-millisecond timestamp precision.** A `Timestamp` is
  `Time.Posix`, which counts milliseconds (§3.5): a fraction of up to
  nine digits is read and truncated, and the finer digits are not
  re-emitted. An option mapping `Timestamp` to an exact seconds and
  nanoseconds type, as `Duration` is held, could cover the rare case it
  matters; there is none.
- **Unknown enum numbers** read as the zero value (§3.3), so a value
  the client does not know is indistinguishable from the zero value,
  and re-encoding sends the zero value's name. `enum_unknown=zero`
  widens the drop to unknown names, which the default, `fail`, refuses
  instead: an option that loses more, chosen for clients that must
  survive values added after them, not an escape.
- **Presence of an `Empty` field.** A singular `google.protobuf.Empty`
  field is `()` (§3.5), so a message that sent `{}` and one that left
  the field out decode alike, and the encoder always sends `{}`.

None of these is a diagnostic, and none has an escape yet: each would be
an option choosing an Elm form that keeps the distinction.

Refused (each a diagnostic, pinned in the conformance corpus where a
case names it):

- **Names that collide in Elm**: two types after nested-message
  flattening (`naming::type_collision`, one problem for two messages,
  whose record constructors collide with their types), two constructors
  in one module, such as enum values or oneof members
  (`naming::constructor_collision`),
  and a field and a oneof of one message (`naming::field_collision`,
  `naming_collision` and `naming_type_collision` cases). Escape: rename one of them with `rename=`
  (§3.7).
- **Names with no Elm form**: a package segment, type, field or method
  whose converted name is not a valid Elm identifier
  (`naming::invalid_module`, `naming::invalid_type`,
  `naming::invalid_field`, `naming::invalid_method`, `naming_invalid`
  and `services_invalid` cases). Escape: give it a name with `rename=` (§3.7). A file without a
  package declaration (`naming::invalid_module` too) has no escape yet:
  a rename names its element by proto full name, and the file's
  package has none; its help text says to add a package.
- **A `google.protobuf` type without a mapping**
  (`types::unsupported_well_known`, `types_unsupported` case), such as
  `Api` or `Type`. `Any`
  was refused here (`types::any`) until it was built (§3.5). No escape
  yet.
- **Package import cycles** (`generate::import_cycle`, `packages_cycle`
  case): Elm forbids import cycles. No escape yet; a module map,
  sending the packages of a cycle to one Elm module, would be one.
- **A generate set not closed under package references**
  (`generate::not_generated`, `packages_not_generated` case), the
  request and response types of methods included (`services_invalid`
  case). Escapes: request the imported files too, with `buf generate
  --include-imports`, by naming them on protoc's command line, or with
  the CLI's `--include-imports` (§3.1, §6). The plugin cannot add them
  itself: it generates only what it is asked to.
- **Streaming methods** (`services::streaming`, `services_streaming`
  case): client, server and bidirectional (§1.3). Escape:
  `streaming=skip` leaves each one out of its service's module, a
  `services::streaming` warning, and generates the rest
  (`services_streaming_skip` case). A service left with no methods gets
  no module, as one declared without methods does: Elm rejects a module
  that declares nothing.
- **HTTP rules a client cannot follow** (`route::*`, `routes_invalid`
  case): a template that does not parse or has a bare wildcard, a path
  variable, `body` or `response_body` naming no suitable field, a
  request field with no query form, a rule without a path, nested
  additional bindings (§4, §5.3; with `services_invalid`). No escape
  yet; a `route` skip, leaving such a method out as `streaming=skip`
  does, would be one. Two bindings of the generated methods with one
  HTTP method and one path shape (each variable written as what it
  matches, so `/v1/{name=messages/*}` and `/v1/messages/{id}` are both
  `/v1/messages/*`; implicit routes included) match the same requests,
  which no router serves both of, and generate with a
  `route::ambiguous_binding` warning (`routes_ambiguous_binding` case).
- **Method values that collide**: two methods of one service whose
  values have one name (`GetSettings` and `Get_Settings`), or a method
  named for another's descriptor (`DescriptorDefaultSettings` beside
  `DefaultSettings`; `naming::value_collision`,
  `services_value_collision` case). Escape: rename one with `rename=`
  (§3.7).
- **Modules that collide**: two services of one package whose module
  names coincide (`Archive` and `archive`), a service module that is
  also a package's (`NotesService` in `notes.v1` beside the package
  `notes.v1.notes_service`), and two packages with one module name
  (`naming::module_collision`, `services_module_collision` case); and a
  service whose name has no module form (`naming::invalid_service`,
  `services_invalid` case). Escape: rename the service or package with
  `rename=` (§3.7). Two module names that differ only in case (`Shop.Api`
  and `Shop.API`) collide too, since their files are one file on the
  case-insensitive file systems macOS and Windows default to
  (`naming::module_collision`, `naming_module_case` case).
- **Names an application already has**: a generated
  module named like a module of the runtime (`Rpc`, `Proto.Json`; the
  `exposed-modules` of `elm.json`) or of a package it depends on (elm/core's
  `Dict`, `Time`, `Json.Decode`, `Http`; `naming::reserved_module`,
  `naming_reserved_module` case), since every import of it would be
  ambiguous; and a type or constructor named like one its module's code
  uses unqualified (`naming::reserved_name`, `naming_reserved` case). The
  latter are the default imports of elm/core the emitter writes bare
  (`Int`, `Float`, `Bool`, `String`, `List`, `Maybe`, `Just`, `Nothing`,
  `False`) and the types it imports exposed (`Dict`, `Proto.Duration`'s
  `Duration`), and the check is of what the module uses: a message
  `Dict` in a package without a map field compiles and is left alone
  (`naming_reserved_unused` case), and gains the diagnostic with its
  first map field. Both are errors, not warnings, as the output would
  not compile. A module that compiles but is a risk to the application,
  one inside the runtime's namespaces or one an elm/* package an
  application uses has, is a warning instead (`naming::runtime_namespace`,
  `naming::shadowing_module`, §3.1). A `rename` to such a name is the same problem. Escape:
  `rename=`, and for a module `module_prefix=` (§3.7, §3.1); the help
  writes them as the front end in use takes them (`--rename` and
  `--module-prefix` from the CLI). Qualifying the library names in an
  affected module would generate working code instead; it is left open,
  since it makes a module's text depend on what its package declares,
  and a `rename` already gets past the clash.
- **Methods without an HTTP rule, when asked**: under
  `unbound_methods=error`, each one is `services::unbound_method`
  (`services_unbound_error` case; §4). The option is the user's own
  choice, and its escape is the default, `unbound_methods=implicit`,
  which the help names.

### 3.9 Descriptors  *(Decided, 2026-10-13; reshaped 2026-10-16)*

Every message and enum gets a descriptor, in a module of its own
beside the package's (§3.1), and a typed value, in the package's
module, which holds its codecs and default with the descriptor:

```elm
-- Notes/V1/Visibility.elm
descriptor : Proto.Enum.Descriptor
descriptor =
    Proto.Enum.descriptor "notes.v1.Visibility"
        [ Proto.EnumValue.descriptor "VISIBILITY_UNSPECIFIED" 0
        , …
        ]


-- Notes/V1/Note.elm
descriptor : Proto.Message.Descriptor
descriptor =
    Proto.Message.descriptor "notes.v1.Note"
        [ name
        , visibility
        , text
        , …
        ]


name : Proto.Field.Descriptor
name =
    Proto.Field.descriptor "name" "name" 1 Proto.Field.CardinalitySingular (Proto.Field.KindScalar Proto.Field.ScalarString)


visibility : Proto.Field.Descriptor
visibility =
    Proto.Field.descriptor "visibility" "visibility" 3 Proto.Field.CardinalitySingular (Proto.Field.KindEnum Notes.V1.Visibility.descriptor)


text : Proto.Field.Descriptor
text =
    Proto.Field.descriptor "text" "text" 11 Proto.Field.CardinalitySingular (Proto.Field.KindScalar Proto.Field.ScalarString)
        |> Proto.Field.inOneof "kind"


-- Notes/V1.elm, in its TYPED VALUES and REGISTRY sections
enumVisibility : Proto.Enum.Enum Visibility
enumVisibility =
    Proto.Enum.enum encodeVisibility decodeVisibility VisibilityUnspecified Notes.V1.Visibility.descriptor


messageNote : Proto.Message.Message Note
messageNote =
    Proto.Message.message encodeNote decodeNote defaultNote Notes.V1.Note.descriptor


registry : Proto.Registry.Registry
registry =
    Proto.Registry.union
        (Proto.Registry.fromDescriptors
            [ Notes.V1.Note.descriptor
            , …
            ]
            [ Notes.V1.Visibility.descriptor
            ]
        )
        (Proto.Registry.union Users.V1.registry Proto.Registry.wellKnown)
```

- **The layout** *(Decided)*. A descriptor module holds
  its `elmConnectVersion_`, then `descriptor`, then a message's fields
  in declaration order, each oneof's members where the oneof is, each
  value documented (what the field is, and its oneof). The package
  module's sections are types, defaults, typed values (each enum's,
  then each message's), the registry, encoders and decoders; a package
  without types has the registry alone. Until 2026-10-19 each
  descriptor was a value of the package module, `descriptorNote`, its
  fields written inline, in a descriptors section beside the typed
  values.

- The naming: `Proto.Thing.Descriptor` is the data-only tree,
  `Proto.Thing.Thing a` the typed value carrying it beside the type's
  codecs and default, in one module (§3.1): `Proto.Message.Descriptor`
  and `Proto.Message.Message a`, `Proto.Enum.Descriptor` and
  `Proto.Enum.Enum a`, `Proto.Method.Descriptor` and
  `Proto.Method.Method req res` (§4, which holds the codecs of its types
  but not their typed values). *(Decided.)* Nothing about a type is
  written twice: an enum's names and numbers are its descriptor's, and
  `Proto.Enum` reads them through the codecs (below).
- **The typed values are opaque**, built by positional functions and
  read by functions of the same module: `Proto.Message.message encode
  decoder default descriptor` (read by `encode`, `decoder`, `default`,
  `toDescriptor`), `Proto.Enum.enum encode decoder zero descriptor`
  (likewise, with `toName`, `fromName`, `toNumber`, `fromNumber`) and
  `Proto.Method.method encodeRequest responseDecoder descriptor` (§4). Why: an Elm record alias that generated code writes
  as a literal can never gain a field. The field is a major by Elm's
  package rules, and every module generated before it stops compiling
  on the literal rather than on the sentinel (§8.2). Built by a
  function, a type grows by a new modifier and a new reader, a minor,
  and code generated before compiles against the newer runtime. A
  builder takes its arguments positionally, never as one record
  argument, which would freeze the shape the same way. The first shape
  was record aliases written as literals. *(Decided, 2026-10-16.)*
- **The trees are opaque too**, for the same reason, each built by a
  `descriptor` function and read in the module of its concept (§3.1):
  `Proto.Message` (`descriptor typeName fields`; `typeName`, `typeUrl`,
  `fields`, `oneofs`), `Proto.Field` (`descriptor name jsonName number
  cardinality kind`, `inOneof`, `withBehavior`, `withDeprecated`;
  `name`, `jsonName`, `number`, `cardinality`, `kind`, `oneof`,
  `behavior`, `deprecated`), `Proto.Enum` (`descriptor typeName
  values`; `typeName`, `values`), `Proto.EnumValue` (`descriptor name
  number`, `withDeprecated`; `name`, `number`, `deprecated`) and
  `Proto.Method` (`descriptor service name idempotency input output
  bindings`; the same six). The unions a descriptor holds are public, to
  match on, in the module beside it: `Cardinality`, `Kind`, `Scalar` and
  `Behavior` in `Proto.Field`, `Idempotency` in `Proto.Method`. A
  property a field has beyond the five every field has is a modifier
  written only when set: `|> Proto.Field.inOneof "kind"` for a oneof
  member, `|> Proto.Field.withBehavior [ … ]` for its
  `google.api.field_behavior` values, `|> Proto.Field.withDeprecated`
  for `[deprecated = true]`; an enum value likewise takes
  `|> Proto.EnumValue.withDeprecated`. A message's oneofs are the ones
  its fields name, in order of first appearance, derived by
  the builder rather than written a second time. *(Decided, 2026-10-16.)*
  The record form wrote every property of every field, its labels
  included. *(Measured 2026-10-16.)* Against the record form, the
  builders make the Connect conformance suite's generated Elm 5.9 %
  smaller (126,211 to 118,711 bytes) and the notes example's 6.6 %
  (98,345 to 91,863), though generated code refers to every module
  qualified in full (`Proto.Field.CardinalitySingular`). An import
  alias would save more; that is a separate question.
- The trees are faithful to the proto, not to the
  Elm mapping: a message's full name, its fields in declaration order
  (name, JSON name, number, cardinality, kind, oneof, behavior,
  deprecation) and its oneofs' names; an enum's full name and its value
  names in declaration order, an alias an entry of its own, each with
  its deprecation. A singular message field is
  `CardinalitySingular` of `KindMessage "…"` though Elm holds it as a
  `Maybe`; a proto3 `optional` field is `CardinalityOptional`, its
  synthetic oneof not listed. `Cardinality` has `CardinalityRequired`
  for proto2's `required`, which the generator, reading proto3 alone,
  never gives. A field of a message type refers to it by full name,
  never by value, since a message can contain itself and Elm forbids
  cyclic values; a `Proto.Registry` resolves the names. A field of an
  enum type holds the enum's descriptor, `KindEnum
  Notes.V1.Visibility.descriptor`: an enum contains nothing, so it
  cannot lead back to the field, and its zero value's name is wanted
  wherever the field is read alone, by a route's default path or query
  text (§5.3) and by UI code that renders the field. `Proto.Field`
  imports `Proto.Enum`, which imports only `Proto.EnumValue`, so no
  import cycle forms either. *(Decided, 2026-10-19; `KindEnum` held the
  full name before.)*
- **The omission rule reads the cardinality.** *(Decided.)*
  Whether a path variable or query parameter is sent at its field's
  default lives in the runtime (`Proto.Http.variable` and `param`,
  §5.3), which reads presence from the last field's descriptor: a
  `CardinalitySingular` field outside any oneof and not of a message
  type has none, and is left out at its default; any other is left out
  only when unset or empty. That is exactly proto3's presence, and it
  is sound because the generator accepts proto3 alone. A later syntax
  (proto2, editions) must map explicit presence to
  `CardinalityOptional` (or `CardinalityRequired`), never to
  `CardinalitySingular`, or the runtime would drop a field set to its
  default; a generated module carries no rule of its own to fix.
- `Proto.Field.Behavior` mirrors `google.api.FieldBehavior` but its
  unspecified zero: `BehaviorOptional`, `BehaviorRequired`,
  `BehaviorOutputOnly`, `BehaviorInputOnly`, `BehaviorImmutable`,
  `BehaviorUnorderedList`, `BehaviorNonEmptyDefault`,
  `BehaviorIdentifier`, and `BehaviorUnknown Int` for a number this
  release does not name, since `google.api.FieldBehavior` keeps growing
  (2020, 2021, 2023) and the union is frozen (§8.3). The prefix keeps them apart from
  `CardinalityOptional` and `CardinalityRequired`, which mean something
  else (§3.1). The CLI embeds `google/api/field_behavior.proto` (§4,
  with the `google.api.http` files), so a proto importing it compiles
  without a googleapis checkout; both binaries read the extension when
  the descriptor pool has it, which it does exactly when a proto
  imports it; a number this release does not name is kept as
  `BehaviorUnknown` and the unspecified zero is dropped.
  *(Decided, 2026-10-16; `BehaviorUnknown` 2026-10-21.)*
- **Descriptor data is added sparingly.** A program that uses the
  registry keeps every tree in it, and every program pays for the
  trees' source size, so a property joins the trees only when a use
  needs it: behavior for update masks and forms, deprecation for
  tooling. Comments (which are in the documentation, §3.1), proto2
  default values, extensions in general and a method's streaming kind
  are not in them.
- `Proto.Enum` derives names and numbers (`toName`, `fromName`,
  `toNumber`, `fromNumber`) from the descriptor and the codecs: the
  encoder writes a value's name, the decoder reads every declared name
  and number, aliases included, and the descriptor says which names
  and numbers are declared, so an undeclared one is `Nothing` rather
  than the zero value the decoder would give. A value the encoder does
  not write as a string has no name: `toName` gives `""` and `toNumber`
  `0`. No generated value is one today, since every constructor is a
  declared value. The typed value holds no list of Elm values of its
  own: that would be the descriptor again, and it is sound only while
  the descriptor is always written (§3.9 has no option to leave it
  out).
- The well-known types' typed values are the runtime's, in
  `Proto.WellKnown` (`empty`, `timestamp`, `duration`, `fieldMask`,
  `any`, `struct`, `value`, `listValue` and the wrappers, the 64-bit
  ones in both `int64` forms), built with `Proto.Message.message`, and
  `Proto.Registry.wellKnown` holds their trees. They live apart from
  `Proto.Message` so that the value for `google.protobuf.Any`
  (`Proto.Any`, §3.5), whose module needs `Proto.Message` and
  `Proto.Registry`, can join them without an import cycle.
- The typed values serve `Any` (§3.5), error details (§5.4) and
  reflection; calls carry codecs only (§4), because Elm's dead-code
  elimination keeps a top-level value whole: a method holding a typed
  value would bring the type's default and descriptor tree into every
  program that calls it. *(Decided.)* For the same reason
  each descriptor is a top-level value of its own (in its descriptor
  module) and the registry is built from those, never from the typed
  values: a registry of
  `messageFoo.descriptor` kept every type's codecs and default in any
  program that used it, which on a large API was most of the program.
  *(Decided, 2026-10-16.)*
- Each method's descriptor is a value of its own in its service's
  module, `descriptorGetNote`, which its call refers to (§4). Its name
  is derived from the method's, so it can collide only with a method
  named for it (`DescriptorGetNote` beside `GetNote`), which is
  diagnosed. There is no service, file or package descriptor: nothing
  consumes one, and a service module's namespace is its methods' calls
  and descriptors, so any fixed value name could collide with a method.
- **The registry.** Each package module has a registry section,
  `registry : Proto.Registry.Registry`, transitive: the package's
  own descriptors, then the registries of the generated packages its
  module imports (each holding its own imports'), then
  `Proto.Registry.wellKnown`, joined with `Proto.Registry.union`, which
  keeps the left one of two with one name (diamonds hold each type
  once). Packages a service refers to but the package's types do not are
  not in it: importing them could make a cycle Elm rejects. It is a
  top-level constant, built once at start-up and dropped by dead-code
  elimination when nothing uses it. A package without types has a
  module holding its registry alone. It names each descriptor module's
  `descriptor`, so the package module imports every one of them.
- **No option to leave the trees out.** A `descriptors=off` setting
  that wrote the message trees empty and no registry was built,
  measured (below) and dropped *(2026-10-14)*. It saved generated
  bytes only, and it made a tree with no fields mean either a message
  with none or descriptors switched off, a doubt every reader of the
  trees (`Proto.Any.describe`, a registry lookup, `Proto.Enum`'s names
  and numbers) would have carried. One knob fewer while the shape
  settles; it can return, additively, if smaller modules turn out to
  matter.
- **Cost** *(measured 2026-10-14, Elm 0.19.2, Apple M4)*: a synthetic
  package of 300 messages of eight fields and ten enums gives a package
  module of 25,434 lines (1.13 MB) with descriptors and 22,277 lines
  (0.66 MB) without. A cold `elm make` of a program using every decoder
  takes the same time either way (5.2–6.6 s over three runs each, the
  spread larger than the difference). The optimized program is 677 KB
  (46 KB gzipped) without descriptors, the same with them when the
  registry is unused, since dead-code elimination drops the trees, and
  1,655 KB (73 KB gzipped) when it uses the registry. So the trees are
  always written: the cost falls on applications that use them. (That
  measurement predates the descriptors' split from the typed values:
  the registry then kept every type's codecs too.)
- **Cost of the descriptor modules** *(measured 2026-10-19, Elm
  0.19.2)*: the notes example's generated Elm goes from 5 modules of
  2,652 lines (92,896 bytes) to 39 modules of 4,099 lines (128,572
  bytes), and the Connect conformance suite's from 119,376 to 184,997
  bytes. Most of the growth is per module (its header, imports and
  `elmConnectVersion_`, about fifteen lines) and per value (a two-line
  doc comment, and a field's own annotation and name). On a
  synthetic package of 100 to 500 messages of eight fields, a cold
  `elm make --optimize` takes the same time within run-to-run noise
  (the superlinear growth is in the package module's types and codecs,
  which do not move), peak memory is 1–12 % higher, and the optimized
  program, with everything reachable through the registry, is 21–29 %
  larger unminified, each field descriptor being a top-level value of
  its own. Dead-code elimination works per top-level value, so a real
  program pays for what it reaches: the notes example's optimized
  bundle goes from 268 to 274 KB; a program reaching every call and the
  registry, minified and gzipped, from 22.2 to 22.5 KB; a program that
  only encodes and decodes is byte-identical; `elmConnectVersion_` is
  dropped from every bundle.

## 4. Calls  *(Decided, 2026-10-13)*

Each service is an Elm module of its own, `Notes.V1.NotesService`
beside the package's `Notes.V1`, holding a calls section with one
function per method from its request to an `Rpc.Call` (§5.2) and then
a descriptors section with each method's `Proto.Method.Descriptor`:
what a program uses comes first and its description after, as a
message's descriptor sits in a module apart from its type (§3.1). The
`services` conformance case pins the output:

```elm
-- CALLS


{-| `rpc GetNote(GetNoteRequest) returns (Note)`.
Connect: `POST /notes.v1.NotesService/GetNote`.
Transcode:

  - binding 0: `GET /v1/{name=notes/*}`;
  - binding 1: `GET /v1/{name=users/*/notes/*}`.

Described by [`descriptorGetNote`](#descriptorGetNote).
-}
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Rpc.call
        (Proto.Method.method Notes.V1.encodeGetNoteRequest
            Notes.V1.decodeNote
            descriptorGetNote
        )



-- DESCRIPTORS


{-| `rpc GetNote(GetNoteRequest) returns (Note)`
-}
descriptorGetNote : Proto.Method.Descriptor
descriptorGetNote =
    Proto.Method.descriptor "notes.v1.NotesService"
        "GetNote"
        Proto.Method.IdempotencyNoSideEffects
        "notes.v1.GetNoteRequest"
        "notes.v1.Note"
        [ Proto.Http.binding
            { method = "GET"
            , path =
                [ Proto.Http.literal "v1"
                , Proto.Http.variable
                    { fieldPath = [ Notes.V1.GetNoteRequest.name ]
                    , template = [ Proto.Http.literal "notes", Proto.Http.wildcard ]
                    }
                ]
            , customVerb = Nothing
            , body = Proto.Http.noBody
            , responseBody = Nothing
            , query = []
            }
        , Proto.Http.binding { … }   -- the additional binding
        ]
```

Both applications put one argument per line however short their
arguments, so a method without bindings (`[]`) reads like one with
them; the emitter asks the printer for that layout, which elm-format
keeps.
*(Decided, 2026-10-16.)*

- **A method's documentation shows its routes.** *(Decided,
  2026-10-20.)* A call's doc comment gives the method's comment
  (§3.1), then its declaration line, its Connect path on a line of its
  own and its HTTP bindings as its `google.api.http` rule writes them,
  each with its `body` and `response_body` where set: one binding on
  the Transcode line, several as a list numbered as
  `Rpc.Call.viaBinding` counts them, binding 0 the rule's own; then, as
  a paragraph of its own, a line linking its descriptor;
  `Transcode: no HTTP rule, follows the Connect path.` for a method
  without a rule, and `Deprecated.` first for a deprecated method. The
  request and response types in the declaration line are named as the
  service's package would write them, relative to it inside it and by
  full name outside (`returns (google.protobuf.Empty)`); the call's
  annotation already names their Elm types. Why: the call is the
  value a program uses, and the routes it may take were visible only as
  `Proto.Http` data in its descriptor. The descriptor carries the
  comment and the declaration line.
  A service has no declaration of its own, so its module's
  documentation carries its comment and `` `service
  notes.v1.NotesService` ``.
- The service module imports `Rpc`, `Proto.Method` (for the method
  and its descriptor), `Proto.Http` (for the bindings), the descriptor
  modules of the messages its bindings' fields belong to
  (`Notes.V1.GetNoteRequest`, §3.1), the package module and the modules of any other package
  its request and response types come from (`Proto.Json`, `Proto.Any`,
  `Json.Encode` or `Json.Decode` for a well-known type's codecs), and
  refers to every one of them qualified. Each method is written
  point-free, `getNote = Rpc.call (…)`, binding no local name. So a
  method's name can clash with nothing but another method's call or
  descriptor in its service, whatever it is: `value`, `identity` or
  `encodeNote` are all fine method names (the namespace rule is in the
  IR bullets below).
- `Rpc.call` takes the method's `Proto.Method.Method req res` (§3.9),
  built by `Proto.Method.method` from its request type's encoder and its
  response type's decoder (`Notes.V1.encodeGetNoteRequest`,
  `Notes.V1.decodeNote`; for a well-known type the runtime's codecs a
  field of that type uses, `Proto.Json.encodeEmpty` and
  `Proto.Json.empty` for `Empty`, `Proto.Json.encodeInt64AsInt` for
  `Int64Value` under `int64=int`, `Basics.identity` qualified for
  `Value` so that a method called `identity` cannot capture it), and
  its descriptor value, `descriptorGetNote : Proto.Method.Descriptor`,
  built by `Proto.Method.descriptor` from the fully-qualified service
  name and the method's name as declared, together its Connect path,
  its idempotency, the full names of its types and its bindings.
  The descriptor's name is `descriptor` followed by the method's Elm
  name with its first letter uppercased, so a `rename` renames both. No
  `Proto.Method.Method` value is generated; `Rpc.Call.method` and
  `Rpc.Call.descriptor` read the method and its descriptor back from any
  call of it. Elm keeps a top-level value whole, and the call refers to
  the descriptor value, so a program that calls the method keeps what
  it kept when the descriptor was written inline, and one that does
  not keeps neither. *(Decided, 2026-10-13; the descriptor became a
  value of its own 2026-10-16.)* The first shape put the codecs
  themselves in a descriptor record of `Rpc`'s; the second gave the
  method its types' typed records (§3.9). A method now carries only
  what the wire needs: the records hold each type's default and
  descriptor tree, and Elm keeps a top-level value whole, so a call
  through records cost about 16 KB gzipped over a client referencing
  only the codecs in an application's bundle. *(Decided, 2026-10-15.)*
- `idempotency` is the proto's `idempotency_level`, whole:
  `Proto.Method.IdempotencyUnknown` when unset,
  `IdempotencyNoSideEffects` or `IdempotencyIdempotent`. Connect sends
  only an `IdempotencyNoSideEffects` method as a GET; a retry policy
  (idempotent-only by default) retries either level, since an
  `IDEMPOTENT` method (a typical `Delete` or `Put`) is safe to repeat
  but not to cache. Transcoding takes its verb from the rule.
  *(Decided, 2026-10-16.)* It was `idempotent : Bool`, true for
  `NO_SIDE_EFFECTS` alone, so an `IDEMPOTENT` method was never retried
  under `idempotentOnly`. `Rpc.Call.idempotency` reads it from a call;
  it was `Rpc.idempotent : Call -> Bool` until the descriptor's three
  levels made that a misnomer.
- **Bindings are data.** `bindings` is the method's `google.api.http`
  rule as the generator parsed it (§4 routes, below): the rule's own
  binding first, then its `additional_bindings` in order, each a
  `Proto.Http.binding` of the verb, the path as literals and variables, the
  custom verb, the body, the response body and the query parameters.
  The runtime walks them and never parses a template. A call picks an
  additional binding with `Rpc.Call.viaBinding n`, `Nothing` for a number
  the method has no binding of, so additional bindings need no names of
  their own.
- **The implicit route.** A method without a rule has `bindings = []`,
  and nothing else is generated for it: under the Transcode transport
  the runtime sends it as `POST /<package>.<Service>/<Method>` with the
  request as its JSON body (§5.3), which grpc-gateway
  (`generate_unbound_methods`), Envoy's transcoder (`auto_mapping`) and
  Vanguard (always; from v0.5 through the Connect handler mounted
  beside it, §7) serve. That request is exactly the one Connect
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
  (`Rpc.Call.toJson`), read back (`Rpc.Call.requestMessage`) and send
  again, so a retry or token-refresh wrapper closes over it, and a
  queue can store it; `req` keeps those uses typed.

The first shape built was different: one module per package holding,
after the codecs, a `Connect.Method` per method (`getNote`) and a
`Transcode.Call` per binding (`getNoteHttp`, `getNoteHttp2`, …), a
`transports=` option choosing which. It put route presence in the type
(§2), named additional bindings by number, and put method values in one
namespace with the codecs; the module per service, calls as data and
`viaBinding` replace all three.

In the IR (`ir::Service`, `ir::Method`):

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
- A method's value is its name converted as a field's is (`GetNote` →
  `getNote`, `HTTPGet` → `httpGet`), a reserved word escaped (`Type` →
  `type_`), and its descriptor's is
  `descriptor` followed by that with its first letter uppercased
  (`descriptorGetNote`). They share a namespace only with the other
  methods' values in its service: two methods that coincide (`GetNote`
  and `Get_Note`), or a method named for another's descriptor
  (`DescriptorGetNote` beside `GetNote`), are `naming::value_collision`,
  never a rename. A method `DefaultSettings` beside a message
  `Settings`, or a `Get` in two services, is fine.
- Module names are unique across the build: a service module that is
  also a package's module (`NotesService` in `notes.v1` beside the
  package `notes.v1.notes_service`), two services whose module names
  coincide (`Archive` and `archive`), or two packages whose do
  (`notes.v1` and `notes.V1`) are `naming::module_collision`, each
  site labelled. So is a service named like a type of its package,
  whose descriptor module has the service module's name (§3.1): proto
  forbids the same name, but not two that convert to one
  (`notes_service` and `NotesService`).
- A method of `google.protobuf.Empty` or another supported well-known
  type takes or gives that type's Elm form (`()` for `Empty`), through
  the runtime's codecs for it (`services_types` case). Any other
  type outside the generate set is `generate::not_generated`, worded for
  the method ("The request of `notes.v1.Notes.Get` refers to ...").
- A streaming method is `services::streaming`, pointing at its
  `stream` keyword, rather than being skipped; `streaming=skip` skips it
  instead, with the same code as a warning (§3.8).
- `google/api/http.proto`, `google/api/annotations.proto` and
  `google/api/field_behavior.proto` (§3.9) are embedded in
  `elm-connect-gen` (`googleapis` module; Apache-2.0,
  `THIRD_PARTY.md`). The CLI resolves imports from its include paths
  first, then protox's `google/protobuf` files, then these, so a proto
  importing `google/api/annotations.proto` compiles without a googleapis
  checkout. The protoc plugin needs no copy: protoc sends every import.
  It builds its descriptor pool from the request's encoded files rather
  than from `prost_types`, which drops extension options such as
  `google.api.http`.

Routes (`elm-connect-gen::route`): each binding of
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
- The runtime writes literals and the custom verb into the URL as they
  are, so each must be URL path text that stays where it is
  (`route::template` otherwise, `routes_unsafe` case): RFC 3986 `pchar`s
  alone (letters, digits, `-._~!$&'()+,;@`, and `%` only as an escape of
  two hex digits), so no `?`, `#`, space, control or non-ASCII
  character; and a literal is not a dot segment (`.`, `..`, or either
  with `%2e` for a dot), which a URL resolves against the segment before
  it and so could leave the base URL's path.
- A `custom` rule's kind is the request's method: an RFC 9110 token, and
  not `CONNECT`, `TRACE` or `TRACK`, which browsers refuse to send
  (`route::rule` otherwise).
- A bare `*` or `**` outside a variable is refused (`route::template`):
  a server can match it, but a client has no field to fill it from.
- A path variable names a non-repeated scalar or enum field, possibly
  through singular fields of generated messages (`{sub.subfield}`); not
  through a well-known type, whose fields have no JSON form of their own.
  A field bound twice is refused. Each violation is `route::path_field`.
- The variable's field may also be a well-known type whose JSON is one
  string or scalar: `Timestamp`, `Duration`, `FieldMask` and the nine
  wrappers, the set a query parameter holds, from one predicate in
  `route.rs` so the two cannot drift. Its text is that JSON value
  (`/v1/at/2026-10-20T12%3A34%3A56Z`), as grpc-gateway reads it. `Empty`,
  `Any`, `Struct`, `Value` and `ListValue` stay refused, as does a
  repeated one. *(Decided, 2026-10-20; `routes_well_known_path` case.)*
  Refusing every message here was the first build, although
  `route::query_field` already accepted these.
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

**The package is kept.** *(Decided.)* The type layer was
built against a runtime package from day one, because the JSON pipeline
helpers and the well-known-type codecs would otherwise be inlined into
every generated module, with the question of keeping it left open until
its contents existed. They settle it: a shared type (`Duration`)
must be one type across every generated module and the application,
which inlining cannot give; the codecs for timestamps as `Time.Posix`
and the `Int64` helpers are one copy rather than one per module; and
the coming transports belong in it too.

### 5.1 Config  *(Decided, 2026-10-13; frozen 2026-10-16)*

```elm
type alias Config =                       -- frozen (§8.3)
    { transport : Rpc.Transport.Transport
    , baseUrl : String                    -- a trailing "/" is dropped; no "?" or "#"
    , headers : List ( String, String )   -- e.g. ( "Authorization", "Bearer …" )
    , timeout : Maybe Float               -- ms, > 0; Connect also sends Connect-Timeout-Ms
    , withCredentials : Bool              -- Http.riskyRequest when True
    , retry : Maybe Rpc.Retry.Retry
    }

config : String -> Config                 -- Connect, POST only, nothing else set
checkConfig : Config -> List String       -- the config's problems, [] when none

-- Rpc.Transport: opaque
connect, connectGet, transcode : Transport
withMaxGetUrl : Int -> Transport -> Transport
withReadMaxBytes, withWriteMaxBytes : Int -> Transport -> Transport
name : Transport -> String                -- "connect" | "transcode"

-- Rpc.Retry: opaque
on : List Rpc.Code.Code -> Retry          -- 3 attempts, 200 ms doubling, 30 s cap, jitter, idempotent only
withAttempts : Int -> Retry -> Retry
withBackoff, withMaxBackoff : Float -> Retry -> Retry
withoutJitter, allowNonIdempotent : Retry -> Retry
```

The config is data: a record with no function in it, transport options
inside the opaque `Transport` and retry options inside the opaque
`Retry`, both data too, so `==` still holds. That is the point of it. Elm 0.19
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

[calling.md](calling.md) shows the wrapper pattern this asks of an
application: one function, `rpc shared call = Rpc.task (config shared)
call`, through which every call goes, and a generic retry or refresh
wrapper that closes over the call value, which is data and can be sent
again. If a need for hooks appears, an opaque `Rpc.Client` built from a
`Config` plus hooks can be added beside `task : Config -> …` without
breaking it (roadmap).

- `Config` stays a record, so it is built per call with record syntax,
  and is frozen: a new knob never becomes a field of it. Each has a
  home that can grow within a major: a protocol-level knob (a binary
  format, compression, gRPC-web, `Grpc-Timeout` for transcoding, a
  proxy's quirks, stream framing) on `Transport`; a retry knob on
  `Retry`; a per-call one on `Call`; hooks on a future opaque
  `Rpc.Client` (an addition, so a minor); and JSON codec options are
  the generator's, decided when code is generated. *(Decided,
  2026-10-16.)* `Transport` was the exposed union `Connect { useGet,
  maxGetUrl } | Transcode` and `Retry` a record until then; nearly every
  protocol on the roadmap would have changed the union, and a cap or
  jitter would have added a field to the record, each a major.
- Headers are name–value pairs rather than `Http.Header`, which is
  opaque, so a built request can be inspected and compared.
- GET is off by default (`connect`), as in connect-es: a GET is only
  worth it where a cache sits in front of the server, and the
  application knows that, not the generator. *(Decided.)*
  `connectGet` sends an `IdempotencyNoSideEffects` method's call as a
  GET, which
  puts the request in URLs, and so in history and logs;
  `withMaxGetUrl n` POSTs a call whose GET URL would be longer than `n`
  characters, for servers and proxies that cap URL length. `name` gives
  the protocol for traces and logs.
- `withReadMaxBytes n` refuses a successful answer whose body is longer
  than `n` bytes of UTF-8, before decoding it, on either transport:
  connect-go's `WithReadMaxBytes` (4 MiB by default, 0 for none) and
  connect-node's `readMaxBytes` (none by default); connect-web, the
  browser transport, has no such knob. No limit by default here, as in
  connect-node: the browser has downloaded the body before the limit
  applies, so a default would surprise without saving bandwidth. It is
  a protocol-level knob, so it is on `Transport`, not in `Config`. The call fails with
  `NoAnswer (ResponseTooLarge { limit, size })` (§5.4). The size is the body as
  the browser decoded it, counted back into UTF-8 by a kernel loop
  (`String.foldl`) rather than a recursion, so a long body cannot
  exhaust the stack; `String.length` would count UTF-16 units. The
  browser has received the body by then, so the limit bounds what is
  decoded and held, not what is downloaded. An error answer is read
  whatever its size, for its status. A limit below 1 refuses every body
  with anything in it, and `checkConfig` reports it. *(Decided,
  2026-10-20.)*
- `withWriteMaxBytes n` is its twin for the request: connect-go's
  `WithSendMaxBytes` and connect-node's `writeMaxBytes`, no limit by
  default. A call whose request message, as the JSON a POST sends (for
  a GET, the same JSON before it is percent-encoded into the query; over
  transcoding, the whole message whichever fields the binding puts in
  the path, query or body), is longer than `n` bytes of UTF-8 is not
  sent: every way of sending fails it with
  `NoAnswer (RequestTooLarge { limit, size })`, checked beside the bad
  URL and the invalid header, and never retried, since nothing was sent
  and nothing would change. The size is the call's message, not a
  request rewritten for `taskFromRequest`. A limit below 1 refuses
  every call, and `checkConfig` reports it. *(Decided, 2026-10-20.)*
- A timeout is also the elm/http timeout, so the client gives up at the
  same moment it asked the server to. A timeout that is not a positive
  number (`0`, negative, NaN, infinite) is no timeout, as `Nothing` is,
  and a call's such timeout leaves the config's in force: elm/http
  hands the value to XHR, whose unsigned conversion makes a negative
  one weeks long and `0` or NaN none, while the header would claim
  1 ms or the maximum.
- A call's path is appended to `baseUrl`, so a `baseUrl` holding `?`
  or `#` would put it in the query or fragment. Such a call is not
  sent: every way of sending fails it with `NoAnswer (BadUrl url)`,
  the URL it would have used, and it is never retried. The pure `Rpc.request` still
  builds that URL, since it has no error to give. `Rpc.checkConfig`
  reports it where the application builds its config, at start-up or
  when its settings change, rather than at the first call: a pure
  `Config -> List String`, empty when nothing is wrong, read as a list
  so later releases can report more. It reports invalid config headers
  too (below), each by name, its value left out since it may be a
  credential. *(Decided.)*
- A header a browser refuses is never handed to elm/http: a name that is
  not an RFC 9110 token, or a value that, once the spaces and tabs at
  either end are trimmed, holds NUL, CR or LF or a character above
  U+00FF (XHR's values are byte strings). XHR's `setRequestHeader`
  throws on such a header, and elm/http calls it outside any handler,
  inside the scheduler's step, so one bad value (a token with a
  newline, a display name in CJK) stopped every Elm process for good:
  no HTTP, no ports, no timers. Every way of sending (`send`,
  `sendTraced`, `task`, `taskTraced`, `taskFromRequest`) checks the
  config's and the call's headers first, and a call with one fails
  with `NoAnswer (InvalidHeader name)`, nothing sent and never retried
  (the trace's `attempts` is `0`, as for a bad `baseUrl`). A header is
  never altered to fit: a changed credential would fail later and less
  clearly. The pure `Rpc.request` still builds the request, which has
  no error to give. *(Decided.)*
- A retry policy is `Rpc.Retry.on codes`: the codes are always the
  caller's, and the rest has defaults. It applies to any error whose
  code (§5.4) is one of `codes`, up to 3 attempts in all, and only to
  calls of an `IdempotencyNoSideEffects` or `IdempotencyIdempotent`
  method (§4) unless
  `allowNonIdempotent`, so a network failure retries when `Unavailable`
  is listed and a timeout when `DeadlineExceeded` is. Clients in the
  wild treat a network failure as the same event as a 503 and gate
  safety on idempotency; a timeout is the ambiguous case, since the
  request may have reached the server, and `DeadlineExceeded` belongs
  in `codes` only for calls safe to replay, which the idempotent-only
  default keeps to. *(Decided.)*
- The wait before the second attempt is bounded by the backoff, 200 ms
  by default, doubling before each one after, never above the cap, 30 s
  by default (`withMaxBackoff`), nor above 2^31 − 1 ms, past which
  `setTimeout` (under `Process.sleep`) runs at once. Each wait is
  drawn uniformly from zero to its bound, full jitter, so clients that
  failed together do not retry together. The draw needs no `Random`
  command: the loop reads `Time.now` when an attempt fails and hashes
  its milliseconds with the attempt number (a 32-bit integer hash), so
  clients a millisecond apart draw unrelated waits. `withoutJitter`
  waits each bound in full. *(Decided, 2026-10-16.)* The policy was
  `{ attempts, backoff, codes, idempotentOnly }` without cap or jitter
  until then: a long policy overflowed `setTimeout` into a tight loop,
  and clients retried a recovering server in lockstep.

### 5.2 Rpc  *(Decided, 2026-10-13)*

The runtime has two roots: `Proto.*` is the data, `Rpc.*` the calling.
`Rpc` is the one module that sends, beside a
module per type it takes or gives: `Rpc.Call` (below),
`Rpc.Transport` and `Rpc.Retry` (§5.1), `Rpc.Trace`, `Rpc.Body`,
`Rpc.Request`, `Rpc.Response`, `Rpc.Error` and `Rpc.Code` (§5.4). The
first five are opaque. `Call`, `Transport`, `Retry` and `Trace` have
their constructors in `Rpc.Internal.*` (where the rest of the internals
live) so that `Rpc` can build or read them and users cannot, and each
public module names its type by an alias; `Body`, which no other module
builds or matches, is defined in `Rpc.Body` (§3.1, rule 4). `Request` and
`Response` are frozen records, each declared once in its module so
that `Rpc`, `Rpc.Trace` and the internals share it without an import
cycle (§3.1, rule 5); `Rpc` aliases both, so `Rpc.Request` and
`Rpc.Response` name them in annotations as before. `Rpc` itself holds
the public API and the running of a call (sending, retrying, timing a
trace); the work it runs is internal, a module per responsibility:
`Rpc.Internal.Route` maps a call onto a binding's URL and body,
`Rpc.Internal.Wire` builds the request each transport sends,
`Rpc.Internal.Answer` reads an answer into a result or an `Error`,
`Rpc.Internal.Retry` holds the policy math and the attempt loop, and
`Rpc.Internal.Http` is the elm/http adapter, with the checks that decide
whether a request can be sent. The data modules, which generated code
calls whatever the transport, are the codecs (`Proto.Json`,
`Proto.Timestamp`, `Proto.Duration`, `Proto.Int64`, `Proto.Bytes`), the typed values
and descriptor trees (`Proto.Message`, `Proto.Enum`, `Proto.Method`, and
`Proto.Field` and `Proto.EnumValue` for the descriptors' parts), the
HTTP bindings (`Proto.Http`), the well-known types' values
(`Proto.WellKnown`), `Proto.Registry` (§3.9) and `Proto.Any` (§3.5).
The names stay `Rpc` and `Proto.*`. *(Decided 2026-10-19.)* They say
what the modules are: proto data, and RPC calls over either transport.
They were `Connect.*` at first, a product prefix that tied proto3 JSON
to one of the two transports; no public `Connect` module remains. The
cost of short names is collision: an application with a module of its
own named `Rpc` (or `Proto.Json`) cannot import either, since Elm 0.19
refuses a module name defined twice: `AMBIGUOUS IMPORT`, "I found
multiple modules with that name. One in the … package, and another
defined locally", or with the runtime vendored as a source directory,
"I found multiple files in your `source-directories` with that name".
The application renames its own module; generated modules go under
`module_prefix` (§3.1, `docs/generator.md`'s option table); a package whose
module would be one of the runtime's is refused
(`naming::reserved_module`, §3.8). An option to
move the runtime's own modules under a prefix was considered and
deferred: it can only work where the runtime is vendored or bundled
rather than installed as a package, and it is a complex option to carry
before anyone asks for it.

```elm
-- Rpc.Request, Rpc.Response: frozen (§8.3)
type alias Request =
    { method : String, url : String, headers : List ( String, String )
    , body : Rpc.Body.Body, timeout : Maybe Float, withCredentials : Bool }
type alias Response =
    { url : String, statusCode : Int, statusText : String
    , headers : Dict String String, body : Rpc.Body.Body }

-- Rpc.Call
type Call req res      -- opaque: method, request, binding, per-call adjustments

-- per call
withHeaders : List ( String, String ) -> Call req res -> Call req res   -- after the config's
withTimeout : Float -> Call req res -> Call req res                     -- replaces the config's
withTracker : String -> Call req res -> Call req res                    -- send without retry only
viaBinding : Int -> Call req res -> Maybe (Call req res)                -- transcoding only

-- reading
method : Call req res -> Proto.Method.Method req res
descriptor : Call req res -> Proto.Method.Descriptor
serviceName, methodName, requestMessage, requestJson
idempotency : Call req res -> Proto.Method.Idempotency
toJson : Call req res -> Json.Encode.Value   -- {"service","method","request"}

-- Rpc
type alias Call req res = Rpc.Call.Call req res
call : Proto.Method.Method req res -> req -> Call req res

-- sending
task : Config -> Call req res -> Task Error res
send : Config -> (Result Error res -> msg) -> Call req res -> Cmd msg
taskTraced : Config -> Call req res -> Task Never ( Rpc.Trace.Trace, Result Error res )
sendTraced : Config -> (Rpc.Trace.Trace -> Result Error res -> msg) -> Call req res -> Cmd msg
cancel : String -> Cmd msg                                              -- Http.cancel by tracker; reports nothing

-- pure halves
type alias Request = Rpc.Request.Request
type alias Response = Rpc.Response.Response
request : Config -> Call req res -> Request
response : Config -> Call req res -> Http.Response String -> Result Error res
taskFromRequest : Config -> Call req res -> Request -> Task Error res
splitTrailers : Dict String String -> { headers : Dict String String, trailers : Dict String String }
```

- A call is data: a generated function per method applied to the
  request (§4). Per-call adjustments ride on it; `toJson` gives it a
  stable JSON form for logs, deduplication keys and queues.
- The codecs are the method's, read by `Proto.Method.encodeRequest`
  and `responseDecoder` (the typed values' `Proto.Message.encode` and
  `decoder` for `Any` and error details). Another encoding's codecs
  would arrive as a modifier of the opaque `Method` and `Message`
  (§3.9), not as a field beside these. *(Decided, 2026-10-13; method
  fields 2026-10-15; opaque 2026-10-16.)* The record form claimed its
  codec names left room for binary codecs beside them, which Elm's
  rules for records never allowed.
- A call's modifiers and readers live in `Rpc.Call`, the module its
  type is named in, as each opaque type has its own; `Rpc.call`, the
  constructor generated code applies, stays in `Rpc` beside an alias
  `Rpc.Call` of the type, so generated code imports `Rpc` alone and
  its `Rpc.Call req res` annotations name the alias. *(Decided,
  2026-10-16.)* They were in `Rpc`, where `Rpc.descriptor` read as too
  generic beside the config, errors and requests the module also
  handles.
- The readers are `method` (the `Method`), `descriptor` (its
  descriptor), `serviceName`, `methodName` and `idempotency` (the
  descriptor's, §4); the string accessors were `service` and `method`
  until `method` named the record. *(Decided, 2026-10-13;
  `idempotency` 2026-10-16.)*
- `viaBinding n` is `Just` the call over binding `n` when the
  descriptor has one (`0` the rule's own, `1` and up its additional
  bindings), `Nothing` otherwise; a method without a rule gives
  `Nothing` for every number, and its unadjusted call takes the
  implicit route (§5.3). A call therefore always has a route, and
  sending never fails for want of a binding. *(Decided.)*
- `Request` is the data form of the record `Http.request` takes,
  without `expect` and `tracker`: elm/http has no request value of its
  own, and its headers and body are opaque. Headers are pairs, the body
  an opaque `Rpc.Body` (`none`, `text`, read by `toText`), and
  `withCredentials` picks `Http.request` or `Http.riskyRequest`. It
  stays a record, so a rewriter changes it with record syntax, and is
  frozen. The body was `Maybe String` until 2026-10-16: the bytes that
  streaming envelopes, gRPC-web, binary protobuf and compression need
  will arrive as another kind of `Body` (`bytes`), a minor, rather than
  as a field.
- `task` is `taskFromRequest` of `request`; the retry loop lives in
  `taskFromRequest`, between attempts `Process.sleep`, so a rewritten
  request is retried too.
- `send` and `sendTraced` take the message before the call, as
  `Task.attempt` and `Http.expectJson` take theirs before the data, so
  a call pipes into them as into `task`: `Notes.getNote req |> Rpc.send
  config GotNote`. *(Decided, 2026-10-16.)* They took the call first
  until then, which needed parentheses around every call.
- `send` without a retry policy is one `Http.request`, carrying the
  call's tracker; with one, it is `Task.attempt` over `task`, and the
  tracker does not apply, since elm/http tracks commands only and
  retrying needs a task. The traced forms are tasks too.
- `cancel tracker` is `Http.cancel tracker`, and a cancelled call
  reports nothing, as elm/http's requests do: elm/http cancels by
  killing the process that runs the request, which aborts it and
  delivers no message. An application that cancels knows it did, and
  records it where it cancels, in its model or with a message it
  batches itself (`Cmd.batch [ Rpc.cancel "note-42", Task.perform
  identity (Task.succeed (Withdrew "note-42")) ]`). One race remains:
  an answer whose message was queued before the cancel ran is still
  delivered, so the application ignores, by its tracker or a request id
  of its own, a result for a call it withdrew. It is for `send`
  without a retry policy, and for a request the application sends
  itself from `request` with the tracker on its `Http.request`: a call
  sent with a retry policy has no tracker and cannot be cancelled, and
  the tasks (`task`, and `taskTraced` under `sendTraced`) ignore the
  tracker; one killed with `Process.kill` reports nothing and has no
  trace, its attempts and duration ending with the process.
  *(Decided, 2026-10-16.)* It was plain `Http.cancel` when decided on
  2026-10-13; on 2026-10-15 it took the call's `toMsg` and reported a
  synthetic `Canceled` error, so the application would see every call
  end exactly once. Review found that outcome wrong both ways: it was
  reported when nothing was in flight (a cancel after the answer, or
  of a tracker never used), and beside a retry policy, which drops the
  tracker, the call reported `Canceled` and then its real result.
  Unary cancellation is rare, and an application that cancels holds
  the locus of control to say so itself, so the runtime no longer
  guesses. The exactly-once form is a later, additive design: a
  model-held state machine (`Rpc.Pending` stepped by an `update`) that
  owns the retry loop, so a retried call is cancellable and every call
  reports one outcome; a streaming transport would need the same
  machine, and would share it.
- `Rpc.Trace` is opaque, made only by the runtime and read by
  accessors: `serviceName` and `methodName` (as a call's are named),
  `transport` (`Rpc.Transport.name` of the config's), `binding`
  (`Nothing` when none was used: Connect, the implicit route),
  `request`, `httpStatus` (the last answer's, `Nothing` when none
  came), `headers` and `trailers` (its response metadata as
  `splitTrailers` divides it, both empty when there was no answer),
  `code` (`Rpc.Error.code` of the error the call ended with, `Nothing` on
  success, so a timeout is `Just DeadlineExceeded`), `duration`
  (milliseconds by `Time.now` before the first attempt and after the
  last) and `attempts`. `toJson` gives every field under stable keys
  (`service`, `method`, `transport`, `binding`, `request` with
  `method`, `url`, `headers` as pairs, `body`, `timeout` and
  `withCredentials`, `httpStatus`, `headers` and `trailers` as objects,
  `code` as Connect spells it or `"ok"`, `duration`, `attempts`); `service`
  and `method` are `Rpc.Call.toJson`'s keys for a call. `toString` is one
  log line without the request, whose URL and body hold the message
  and whose headers may hold credentials. *(Opaque, `code : Maybe Code` and
  `transport` decided 2026-10-16; `httpStatus` and `code` 2026-10-13,
  `headers` and `trailers` 2026-10-15.)* It was a record, so a new
  field (per-attempt statuses, sizes once compression exists) would
  have been a major; its `code : Rpc.Code` repeated the result beside
  it.
- `splitTrailers` is the Connect unary rule for an answer's metadata:
  a header named `trailer-<name>`, in any case, is the trailer
  `<name>`, and the rest are headers; every name is lowercased. A
  header named `trailer-` alone names no trailer and stays a header.
  The trace applies it whatever the transport; the halves' caller
  applies it to `Http.Metadata` itself. A header sent more than once
  arrives as one value: the browser's `getAllResponseHeaders` and
  elm/http's `_Http_parseHeaders` join repeated names' values with
  `", "` in the order they came, and names differing only in case are
  joined the same way when lowercased. The conformance suite's
  duplicate-metadata tests accept the joined value. *(Decided.)*
- Only the pure halves are unit-tested; elm-test cannot run a `Task`,
  so `task`, `send`, the traced forms and the retry loop are checked by
  the compiler and by the retry policy's own tests, and run against a
  server by the live suite (§7, live verification): `sendTraced`,
  `send` with and without a retry policy, `task`, the retry loop over
  `UNAVAILABLE` and its idempotent-only gate, timeouts,
  `withCredentials` reaching the request, a tracker's progress, and
  each field of the `Trace`. The Connect conformance suite (§7) runs
  `Rpc.request` and `Rpc.response` with elm/http between them, and
  `sendTraced`. The live suite also runs `taskFromRequest` with a
  request rewritten after `Rpc.request`, the rewritten header seen on
  the wire, on a retry too. `cancel` is run by both: the suite's
  cancellation test cancels calls sent through the halves (the tracker on `Http.request`), and a
  smoke case one sent with `send`; each is aborted, and the runner
  reports the cancellation it recorded itself, as an application
  does (2026-10-16).
- The pure halves and the traced forms give the application an
  answer's headers and trailers; `task` and `send` give the response or
  the error and nothing more. The conformance suite's tests of response
  headers and trailers pass both through the halves and through
  `sendTraced` (2026-10-15).

### 5.3 Transports

#### Connect  *(Decided)*

Run against connect-go by the live suite (§7): POST and GET, the
timeout header, every method of the example API; and by the Connect
conformance suite's unary JSON test cases over HTTP/1.1 (v1.0.6, §7),
all 40 passing.

- Unary only. POST to `baseUrl/<service>/<Method>` with the request's
  JSON as an `application/json` body and `Connect-Protocol-Version: 1`.
  With `connectGet`, a call of an `IdempotencyNoSideEffects` method is a GET of the same URL with
  `?connect=v1&encoding=json&message=<JSON>`, the JSON percent-encoded
  (every byte but RFC 3986's unreserved characters), in the order the
  protocol recommends; no protocol-version header, which GET carries in
  the query.
- `Connect-Timeout-Ms` is the timeout rounded up to a whole
  millisecond, between 1 and 9,999,999,999 (ten digits); a timeout that
  is not a positive number sends none (§5.1).
- Success is status 200 with a body the response decoder accepts; a 200
  whose body it rejects is `BadResponse problem answer`. Any other
  answer is read as an error (§5.4).
- Bindings are carried on the call and ignored, `viaBinding` too:
  Connect has one route per method.
- The runtime's dependencies beyond core, json and time: elm/http
  (which brings elm/bytes and elm/file). Percent-encoding is written out
  in the runtime rather than taken from elm/url, whose `percentEncode`
  keeps `!*'()`, which the transcoding rules require escaped.

#### Transcode  *(Decided, 2026-10-13)*

Run against Vanguard by the live suite (§7): GET with query
parameters, POST with a body field, PATCH with an update mask in the
query, DELETE, a custom verb, percent-encoded path values and the
implicit route; and every route fixture (`conformance/routes/`), each
request checked against the fixture and Vanguard's reading of it
against the fixture's request, with three divergences recorded (§7).
Not verified live: `response_body` (no rule of either API has one),
and the fields refused a query form, which never reach a server.

The bindings a generated call carries (`Proto.Http.binding`, with
`literal`, `variable`, `wildcard`, `doubleWildcard`, `noBody`,
`wholeBody`, `bodyField` and `param`) are the parsed `google.api.http`
rule, the rule's own binding first and its
`additional_bindings` after; `Rpc.Call.viaBinding n` picks one, `0` by
default, and is `Nothing` for a number the method has no binding of
(§5.2).

- **Variables and parameters are paths of field descriptors.**
  *(Decided, 2026-10-19.)* A variable is `Proto.Http.variable { fieldPath,
  template }` and a parameter `Proto.Http.param fieldPath`, where `fieldPath`
  is the path of `Proto.Field.Descriptor`s from the request message
  down to the field, each from its message's descriptor module (§3.1):
  `[ Notes.V1.UpdateNoteRequest.note, Notes.V1.Note.name ]` for
  `{note.name}`. The runtime derives
  the rest once, when the binding is built: the JSON path from each
  field's `jsonName`, a parameter's name from the proto names joined
  with dots, the text of the default from the last field's kind (`""`
  for a string or bytes, `false`, `0` for any number, an enum's zero
  value's name, which is why `KindEnum` holds the enum's descriptor,
  §3.9), and whether a parameter is left out at that text from the
  last field: one without presence (`CardinalitySingular`, outside any
  oneof, not a message) is, any other only when unset or empty. The
  generator keeps what may be a variable or a parameter (below) and
  writes the descriptors; the derivation exists once, in the runtime.
  Before, the generator computed the names, JSON paths, default text
  and omission and wrote them as positional strings
  (`Proto.Http.variable [ "name" ] [ … ] ""`, `Proto.Http.param
  "page_size" [ "pageSize" ] (Just "0")`). A variable of a
  well-known request (`{seconds}` of a `Timestamp`) is refused
  (`route::path_field`): its JSON is not an object of its fields.

- **A body field and a response body are field descriptors.**
  *(Decided, 2026-10-19.)* `Proto.Http.bodyField
  Notes.V1.CreateNoteRequest.note` and `responseBody = Just
  Notes.V1.ListNotesResponse.notes`, so that every field a binding
  names is named one way. Each is one descriptor, not a path: the
  generator accepts as `body` only a singular message field at the top
  of the request, and as `response_body` only a field at the top of the
  response. The runtime reads the field's `jsonName`, the key it read
  before, so `Proto.Internal.Binding` is unchanged. A service module
  imports the response's descriptor module when a binding names a
  response body; descriptor modules import no service module, so no
  cycle forms. A body field of a well-known request (`body:
  "struct_value"` of a `google.protobuf.Value`) or a response body of
  a well-known response is refused (`route::body_field`,
  `route::response_body`): its fields have no descriptor module, and
  its JSON is not an object of its fields. grpc-gateway, Vanguard and
  Envoy accept the shape, since each reads the field from the message
  by reflection rather than from its JSON; the runtime here reads the
  encoded JSON by key, so the shape is refused until someone needs it.
  Before, both took the field's JSON name as a string.

- **The implicit route.** A method without a rule has no bindings, and
  is called as `POST /<package>.<Service>/<Method>` with the request as
  its JSON body, which grpc-gateway (`generate_unbound_methods`), Envoy
  (`auto_mapping`) and Vanguard all serve. That is exactly the request
  Connect POSTs, `Connect-Protocol-Version: 1` and `Connect-Timeout-Ms`
  included, so the runtime builds it from the descriptor and the
  generated code carries nothing for it; whether a method has a rule is
  not in the type. Its answer is read as a transcoder's (any 2xx).
  The live suite runs it against connect-go with Vanguard (§7).
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
- A binding's literal segments and custom verb are written as RFC 3986
  `pchar`: unreserved characters, sub-delimiters, `:` and `@` as they
  are, a `%` followed by two hex digits kept as an escape (never
  encoded twice), and every other byte percent-encoded. The generator
  already refuses a literal or verb outside that set, so generated
  bindings are written unchanged; this is a second line of defence for
  a binding built by hand with `Proto.Http.literal`, which could
  otherwise end the path with `#` or start a query with `?`.
  *(Decided.)*
- A path variable the request's JSON has no value for (a message on
  the way unset, or the field absent or `null`) is the text of the
  field's proto3 default, which the runtime reads from the variable's
  last field descriptor (`0`, `""`, `false`, an enum's zero name). An
  unset well-known field (a timestamp, a wrapper) is `""`, as an unset
  string is, so the server sees an empty segment there too; a
  well-known type has no zero text of its own to send. *(Decided,
  2026-10-20.)* proto3 reads the field as its default there, and a
  server parses the segment as the field's type: Vanguard rejected the
  empty segment the runtime sent before
  (`/v1/typed/0/false/KIND_UNSPECIFIED/0/`, `invalid parameter
  "inner.deep.b": unexpected end of JSON input`) and accepts `0`. A
  server reads every message on the way as set, which the wire cannot
  avoid (§7). *(Decided, 2026-10-15.)*
- Path from the template and the request; body from the `body` field
  (`*`, a named field, or none); remaining request fields as query
  parameters on GET and DELETE, omitting zero values. *(Decided for
  omission: the in-house generator sent them, which was harmless but
  noisy.)*
- Query parameters: unless `body` is `*`, every
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
  Generated encoders already leave such fields out (§3.4); the runtime
  still compares a value with its parameter's default text, so JSON
  from another encoder (`Rpc.taskFromRequest`, the pure halves) gives
  the same query. Likewise a path variable missing from the JSON is
  its default's text, which is now how every path field at its default
  is written.
  Values are written as proto3 JSON writes them, unquoted: enums by
  name, 64-bit integers in decimal, timestamps in RFC 3339, field masks
  comma-joined.
- Fields with no query form are refused rather than dropped
  (`route::query_field`): maps, repeated messages, `Struct`, `Value`,
  `ListValue` and `Any`, and a message that contains itself, directly or
  through other messages. That message is refused at the field holding it
  and not expanded, so a cycle of any length is one problem. A message
  held deeper than 100 messages below the request, protobuf's nesting
  limit for parsing ([proto limits]), is refused at the field holding it
  too, for the query and for a path variable: no server reads it, and
  the limit bounds the walk of a deep chain. `Empty` carries nothing and
  has no parameter.

[proto limits]: https://protobuf.dev/programming-guides/proto-limits/

### 5.4 Errors  *(Decided, 2026-10-13; reshaped 2026-10-16)*

Every source is read from a live answer by the live suite (§7): a
Connect body and a `google.rpc.Status` body, each with details read
as JSON (`debug` in the Connect body), `grpc-status` headers and a bare
HTTP status. The Connect conformance suite (§7) checks every code from a
Connect body, with its message (Unicode included) and details, and
`fromHttpStatus` on answers with no error body. A detail without `debug`
is not met: connect-go, the suite's reference server, always sends it.

```elm
-- Rpc.Error; Rpc aliases the type (type alias Error = Rpc.Error.Error)
type Error
    = RpcStatus StatusError Response    -- the server stated an RPC status
    | HttpStatus Response               -- it answered with a failure and stated none
    | BadResponse String Response       -- it answered 2xx and the body did not decode (the problem)
    | NoAnswer Reason                   -- nothing came back, nothing was sent, or the answer was refused unread

type Reason                             -- frozen (§8.3)
    = Timeout | NetworkError | BadUrl String | InvalidHeader String
    | RequestTooLarge { limit : Int, size : Int }
    | ResponseTooLarge { limit : Int, size : Int }

type alias StatusError =                -- frozen (§8.3)
    { code : Rpc.Code.Code
    , message : String
    , details : List Proto.Any.Any
    , source : Source
    }

type Source
    = ConnectBody                       -- {"code": "not_found", …}
    | StatusBody                        -- google.rpc.Status, {"code": 5, …}
    | GrpcHeaders                       -- grpc-status / grpc-message headers
    | GrpcTrailers                      -- reserved: gRPC / gRPC-Web trailers
    | ConnectEndStream                  -- reserved: Connect end-of-stream message

code : Error -> Rpc.Code.Code           -- see below
message : Error -> String
details : Proto.Message.Message a -> Error -> List a
toString : Error -> String              -- "<code>: <message>", or "<code>" when the message is empty

-- Rpc.Response.Response, which Rpc aliases
type alias Response =                   -- elm/http's Http.Metadata, and the body; frozen (§8.3)
    { url : String, statusCode : Int, statusText : String
    , headers : Dict String String, body : Body }
```

```elm
-- Rpc.Code
type Code = Canceled | Unknown | … | Unauthenticated   -- gRPC's 1 to 16
```

`Rpc.Code` has `toString` / `fromString` (Connect's names), `toInt` /
`fromInt` (gRPC's numbers), `toHttpStatus` and `fromHttpStatus`.
Success has no code: the `Result` a call ends with says whether it
succeeded, as in connect-go, connect-es and connect-kotlin, whose
`Code` is the sixteen error codes alone. A failed answer whose body
says `ok` or `0` reads as `Unknown`. *(Decided, 2026-10-16.)* On
2026-10-13 two modules were decided instead: `Rpc.ErrorCode` for these
sixteen and `Rpc.Code`, `Ok | Failed ErrorCode`, so that a `Trace`
could report a status whole. That decision is reversed: `Code` existed
only for the trace, whose result already said whether the call
succeeded, it copied every helper to add one case, and its `Ok` clashed
with `Result.Ok` in every module. The trace's `error : Maybe Code`
says the same, and the sixteen codes took the name `Code`. (Before that the
two types shared one module, the helpers for `Code` prefixed.)

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
  order, and is an `RpcStatus` error when one of three readers finds a
  status: a Connect error body (`code` a string the protocol names; an
  unknown name reads as `Unknown`; `message` `""` and `details` `[]`
  when absent); a `google.rpc.Status` body as grpc-gateway and Envoy
  send it (`code` an integer; one outside 1 to 16, `0` included, is
  `Unknown`, the number as sent left in the body); the `grpc-status`
  and `grpc-message` headers, when the browser exposes them (the
  message percent-decoded, the status text when absent). The shape of
  `code` tells the two bodies apart, so a server behind either
  transport may answer in either form. An answer none of them reads is
  an `HttpStatus` error: `code` infers its code from the HTTP status by the
  protocol's table, `message` is the status text (`HTTP <status>` when
  empty), and it has no details.
- Every error that had an answer keeps it, a
  `Response`: the URL it came from (after any redirect), the status and
  status text and the headers as elm/http's `Http.Metadata` gives
  them, and the body, whichever reader
  recognised it, so an application can parse what the readers do not
  (`HttpStatus response -> Rpc.Body.toText response.body`). Some servers cannot be
  changed to answer in a standard shape, and when the readers fall
  through to the status table the body that said more was otherwise
  lost. Reading the answer with the pure halves (§5.2) would work too,
  but gives up the retry loop. A custom reader passed to the config as
  a function is the possible next step, deferred until a second
  application asks for it. *(Decided, 2026-10-15; `BadResponse`
  2026-10-16.)*
- A constructor per kind of error, and `code` and `message` for the
  common path (`case Rpc.Error.code error of Unauthenticated -> …`).
  *(Decided, 2026-10-15.)* The answer was first kept on one flat
  `Rpc` record beside `source`, whose `HttpStatus Int` marked an
  inferred code, until review found it bought nothing: Elm's record
  patterns bind field names and never match field values, so the
  documented `Rpc { source = HttpStatus 404, response }` did not
  parse, and helpers serve as well. A code the server stated and one inferred
  from the HTTP status are different kinds of error, which a
  constructor says honestly while `code` still gives one code for
  both. `Source`'s `Int`s went too: `StatusBody`'s duplicated the raw
  body and `HttpStatus`'s `statusCode`. A `Status = { code, message,
  details }` alias wrapped in the constructor was rejected, since
  `google.rpc.Status` generated from googleapis is already a
  `Google.Rpc.Status` record with `code : Int`, and two `Status`
  records with different code types would confuse; the record is
  `StatusError` now, its constructor `RpcStatus`, which says the same
  thing without the clash.
- The errors and their readers are a module of their own, `Rpc.Error`,
  as each type has its module (§5.2); `Rpc` keeps the alias `Error`
  so annotations naming `Rpc.Error` compile, and the readers are
  `Rpc.Error.code`, `message`, `details` and `toString` (which was
  `Rpc.errorToString`). *(Decided, 2026-10-16.)*
- Every error has a code, the one the Connect clients give it when the
  server stated none: an `HttpStatus` error's by the status table, a
  `BadResponse` `Internal`, and a `NoAnswer` by its reason: `Timeout`
  `DeadlineExceeded`, `NetworkError` `Unavailable`, `BadUrl` and
  `InvalidHeader` `Internal`, `RequestTooLarge` and `ResponseTooLarge`
  `ResourceExhausted`. This settles whether a client timeout reads as
  `DeadlineExceeded`: through `code` it does, while the constructor
  still says no answer came. `message` gives a description for those
  (`timeout`, `network error`, `bad URL: <url>`, `invalid header
  "<name>"`, connect-es's `message size <size> is larger than
  configured writeMaxBytes <limit>` and `… readMaxBytes <limit>`,
  `bad response body: <problem>`), and `toString` is the code and the message for all of
  them. elm/json's problem quotes the JSON it rejected, which can be
  the whole response, so the message keeps the first 300 characters of
  it and `…`; the whole problem stays in the error. A bad URL is
  printed without the `user:password@` a URL can carry and without its
  query and fragment, which over Connect's GET hold the request
  (`bad URL: https://api.example.com/base (query omitted)`); the whole
  URL stays in the error. *(Decided, 2026-10-15; the URL's printing
  2026-10-16.)*
- `Reason` and `StatusError` are frozen (§8.3): every failure a browser
  request can have before an answer is read is one of the reasons, and
  a later kind of failure found in an answer that was read (a malformed
  stream envelope, a failed decompression) is a `BadResponse`, whose
  problem says what. A bad URL, an invalid header and a request over
  the write limit are never retried,
  whatever the policy's codes: nothing was sent, and nothing would
  change. `InvalidHeader` has its home here rather than in a
  constructor of its own beside `NoAnswer`, since it is one more reason
  nothing was sent (§5.1). *(Decided, 2026-10-16.)*
- `ResponseTooLarge { limit, size }` is the answer over the receive limit
  (§5.1): it arrived, but was dropped before it was decoded, so it is a
  reason no answer was read and carries no `Response`; keeping one would
  keep the body the limit is there to drop. It was added before 1.0
  because `Reason` freezes then. connect-go and connect-node have the
  knob and connect-web does not, and the conformance suite tests it
  only for servers (§7); it is kept because an Elm program is not only
  a browser one (§1), and because server streaming will check each
  message of a stream against the same limit, as connect-go's does.
  Its code is `ResourceExhausted` and its message connect-es's.
  It is retried only when a policy lists `ResourceExhausted`.
  `RequestTooLarge { limit, size }` is the request over the send limit,
  never sent. The two are distinct constructors, as connect-es's
  messages are distinct, so a caller can tell a request it must shrink
  from an answer it asked not to read. *(Decided, 2026-10-20.)*
- The shape until 2026-10-16 was `Status { code, message, details,
  source } Response | Http Response | Transport Http.Error | Canceled`
  (2026-10-15). Review found three of the four names clashing:
  `Transport` with the `Rpc.Transport` type and module (`Rpc.Transport
  _ ->` beside `transport = Rpc.Transport.transcode`), `Canceled` with
  `Rpc.Code.Canceled` in every module exposing both, `Http` with the
  `Http` module. `Transport Http.Error` put elm/http's type in the API,
  so an elm/http major would have forced one here, and it let user code
  match `Http.BadStatus`, which the runtime never produced. And a 2xx
  whose body did not decode was `Transport (Http.BadBody _)`, which
  dropped the answer, the status and body a developer most needs when a
  schema drifts. So the constructors say what came back (`RpcStatus`,
  `HttpStatus`, `BadResponse`, `NoAnswer`), the runtime maps elm/http's
  errors to its own `Reason`, and `BadResponse` keeps the answer.
  `Canceled` went with the synthetic cancel outcome (§5.2).
- Error details are `Proto.Any.Any` values (§3.5). *(Decided,
  2026-10-13.)* A `google.rpc.Status` body holds them as proto3 JSON
  `Any` objects; a Connect body as `{"type": <name>, "value": <base64
  binary>, "debug": <JSON, optional>}`, read as an `Any` of that type
  (`type.googleapis.com/` prefixed unless the name holds a `/`) whose
  payload is `debug` when present and the binary alone otherwise. Each
  detail is read in either form whichever body it came in, the proto3
  form first; one in neither form is left out rather than losing the
  error's code and message with it. They were raw JSON values first,
  until `Any` was designed.
- `Rpc.Error.details : Proto.Message.Message a -> Error -> List a` gives
  the details that are of that type and decode, in order; only an
  `RpcStatus` error has any. A binary-only detail never decodes: details meant for
  this client need their JSON on the wire, as `debug` in a Connect body
  or, as always, in a `google.rpc.Status` body.

## 6. Generator  *(Decided unless marked)*

- Rust. One workspace: `elm-connect-gen` (library), `protoc-gen-elm-connect`
  (protoc plugin, reads `CodeGeneratorRequest` on stdin; it answers
  `--version` and `--help` without reading it, and run from a terminal
  with no arguments prints its usage), `elm-connect`
  (standalone CLI on `protox`, compiles `.proto` directly; no protoc).
- Output is produced from a typed Elm AST and a printer tuned to match
  `elm-format` (`elm-connect-gen::elm`). The conformance suite runs
  `elm-format --validate` on every golden file to keep that true.
  *(Decided.)* No Wadler-style printer was needed: fixed rules choose
  one line or several per construct, laid out on a port of elm-format's
  own block model (text, tab stops, prefix, indent), and a corpus test
  holds the output to `elm-format --validate` and `elm make`.
- Options (`--elm-connect_opt=` or CLI flags): `int64=string|int`,
  `bytes=string|bytes`, `unbound_methods=implicit|error`, `streaming=error|skip`,
  `enum_unknown=fail|zero`,
  `rename=<proto full name>:<Elm name>` (repeatable) and
  `module_prefix=`; an option for unrecognised enum values (§3.3) is on
  the roadmap. A
  `transports=` option, choosing which transports' values were
  generated, went with the shape it chose between (§4). *(Decided,
  2026-10-13.)*
  As the plugin and the CLI take them: `int64` (§3.4; `--elm-connect_opt=int64=int`, or
  `elm-connect gen --int64 int`), `bytes` (§3.4;
  `--elm-connect_opt=bytes=bytes`, or `elm-connect gen --bytes bytes`),
  `unbound_methods` (§4;
  `--elm-connect_opt=unbound_methods=error`, or `elm-connect gen
  --unbound-methods error`), `streaming` (§3.8;
  `--elm-connect_opt=streaming=skip`, or `elm-connect gen --streaming
  skip`), `enum_unknown` (§3.3; `--elm-connect_opt=enum_unknown=zero`,
  or `elm-connect gen --enum-unknown zero`), `rename` (§3.7; `--elm-connect_opt=rename=notes.v1.Note:Memo`,
  repeated, or `elm-connect gen --rename notes.v1.Note:Memo`, repeated),
  `module_prefix` (§3.1; `--elm-connect_opt=module_prefix=Api.Notes`, or
  `elm-connect gen --module-prefix Api.Notes`).
  The plugin parameter is comma-separated `key=value` pairs; an unknown
  key or value, or a key other than `rename` given twice, is an error,
  as is a `rename` without its `:` or one renaming a proto name twice,
  or a `module_prefix` that is not dot-separated Elm module segments,
  each an `options::*` diagnostic, all of a parameter's reported
  together. A conformance case sets options with an
  `options.txt` holding that parameter, and a case whose parameter has
  problems expects them as its `diagnostics.txt`.
- The CLI's `--include-imports` flag *(Decided, 2026-10-15;
  narrowed 2026-10-16)*, named after buf's: the CLI also generates every
  imported file that declares a message or enum the requested packages
  refer to, through fields and method types, transitively (a file
  generated is generated whole, so its own references count too), bar
  `google/protobuf/*` (the runtime's). A package such a file declares is
  generated from those files alone, not whole as a requested package is
  (§3.1): an import used only for its options, such as
  `google/api/client.proto`, `field_behavior.proto` or the googleapis
  files the CLI embeds for `google.api.http`, contributes nothing, and
  before this rule it brought a `Google.Api` module of some thirty
  unused types, `HttpRule` among them, into every API that imported
  one. A service is never referred to, so an imported file of services
  alone is not generated either (`crates/elm-connect/tests/generate.rs`).
  The plugin cannot do the same under `buf generate --include-imports`,
  which sends every import as a file to generate: there it skips only
  the embedded googleapis files. Off by default, so the CLI generates
  what protoc and buf generate from the same files (§3.1). It is the
  CLI's driver choosing the generate set, not a generator option:
  protoc and buf choose it themselves, and the plugin cannot widen it.
  The corpus cannot set it (`options.txt` is the plugin parameter), so
  `crates/elm-connect/tests/generate.rs` covers it.
- Diagnostics carry spans from `SourceCodeInfo` and render in the style
  of Elm's compiler, each under a code. The codes, what each reports and
  its escape are listed in [`diagnostics.md`](diagnostics.md), which a
  test (`crates/elm-connect-gen/tests/catalogue.rs`) holds to the
  generator's own list.
  A help that names an option writes it as the reader gave it: a flag
  under the CLI (`--streaming skip`), a parameter under the plugin
  (`streaming=skip`), from `Options::spelling`, which each binary sets.
  The plugin has no proto sources, so no snippet: it names each site
  as `path/to/file.proto:3:9` from the request's `SourceCodeInfo` before
  the message, and lists the sites with their labels when there are
  several; the CLI renders snippets.
  The CLI's compile errors are protox's, rendered as protox renders them
  and not in the catalogue; a file or import found on no include path
  adds a help naming the include paths searched.
  The `naming::reserved_*` checks (§3.8) are errors: what they report
  would not compile, and an error at generation names the proto element
  and the escape where the Elm compiler's error would name neither.
  A diagnostic is an error, failing the run, or a warning, reporting
  what an escape left out (§3.8) beside a successful run: rendered the
  same way with miette's warning styling (`⚠`), printed to stderr by
  both binaries (the plugin leaves the response's `error` unset), and
  returned by the library as `Generated::warnings` beside
  `Generated::files`.

## 7. Conformance  *(Decided)*

The harness is `conformance/cases/` and the
`conformance` test of `elm-connect-gen`, described in
`conformance/README.md`. A case that generates pins its warnings, if
any, in `expected/warnings.txt`, rendered as `diagnostics.txt` is.

- `conformance/cases/<case>/input/*.proto` and `expected/*.elm`. A test
  regenerates and diffs, the patch of the version on each module's
  header line read as a placeholder, `0.1.X` (§8.4); a second test runs
  `elm make` over all expected output against the runtime at the repo's
  version; a third runs `elm-format --validate`.
- The plugin replays the corpus as protoc runs it
  (`crates/protoc-gen-elm-connect/tests/plugin.rs`): the built binary is
  sent each case's `CodeGeneratorRequest` on stdin, and its response must
  carry the expected modules, or the problems in `error`, with warnings
  on stderr. protoc sends no sources, so its rendering names the proto
  elements; it is compared with the generator's own without sources and,
  by problem code, with `diagnostics.txt` and `warnings.txt`.
- Route fixtures: a JSON file of `(template, request) → (path, query,
  body)` expectations, checked against the generator's parser. The same
  file is intended to be consumable by a server-side implementation so
  the two ends can prove agreement without sharing code.
  They are `conformance/routes/` (layout in
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
  `Rpc.Call.viaBinding` (a fixture naming a binding the method lacks fails
  rather than falling back to the implicit route). Bodies compare with
  `null`s and defaults dropped.
- Property tests, in two layers. Elm fuzz tests
  (`tests/Proto/JsonFuzzTest.elm`, `tests/RpcFuzzTest.elm`, fuzzers in
  `tests/Fuzzers.elm`) check laws of the runtime alone: each proto3
  JSON codec round-trips across its type's whole range (32- and 64-bit
  integers past 2^53, floats with their special values, bytes in both
  base64 alphabets, timestamps of years 1 to 9999, durations to
  ±315,576,000,000 s, field masks, enums, maps, repeated fields,
  `Struct`, `ListValue`, `Value`), decoders accept the other forms
  proto3 JSON allows, the generated codecs of `routes.proto` leave out
  defaults (a default message is `{}`, which holds for every message
  but one with an `Empty` field, always written as `{}` (§3.5); `{}`
  decodes to it, and
  `encode (decode (encode x)) == encode x`), and `Rpc.request` over
  Transcode keeps structural laws (a path segment percent-decodes to its
  field's value, a field bound in the path is in neither the query nor
  a `*` body, a body field is not in the query, the URL holds only
  unreserved characters, escapes and its delimiters). The second layer
  is the route fixtures' machinery run on requests the Rust test samples
  for every binding of `routes.proto` from a fixed seed (strings needing
  escapes, integer bounds, floats' special values, unset and empty
  messages, repeated and map fields, wrappers at their defaults,
  well-known types): the reference gives each one's HTTP request, pinned
  as `tests/RouteProperties.elm` and replayed through `Rpc.request` as
  the fixtures are, which also runs the generated decoders and encoders
  on prost-reflect's proto3 JSON (written with and without defaults,
  under JSON and proto names). Neither layer proves a server agrees: the
  samples are not sent live, the second layer is only as right as the
  reference's reading of http.proto and proto3 JSON, and a float's text
  in a path or query is held to one form (ECMAScript's, which proto3
  JSON does not require). Timestamps are sampled to the millisecond,
  which is all `Time.Posix` holds (§3.5). A sample that fails is a
  finding, not a case to exclude; `-0` is the one value the codec laws
  hold apart, since it is written as `0` (§3.4).
- Codec round trips: the corpus's expected modules
  are compiled and diffed, never run, so a construct wired wrong (a
  wrong key, combinator, default or omission) passes once blessed.
  `conformance/codec/codec.proto` (with `other.proto`, a second package)
  holds every construct the codecs handle, one per message, and a
  message nesting them all: every scalar kind, `optional`, repeated
  fields, a map of every key kind, a oneof of scalar, `int64`, enum,
  message, `Empty`, `Value`, `Timestamp` and wrapper members, `json_name`
  overrides, a nested message and enum, a message recursive directly and
  through a list, a map and a oneof, `Any`, `Struct`, `ListValue`,
  `Value`, the other well-known types and every wrapper, and references
  across packages. The Rust test (`crates/elm-connect-gen/tests/codec.rs`)
  samples each message with the route properties' sampler from a fixed
  seed, plus each oneof member and the scalars' bounds and special
  values by construction, and prost-reflect writes each sample in three
  forms: canonical (defaults left out), with defaults written, and under
  proto names with an unknown field in every message object. The
  samples become Elm data with what the encoders must write back,
  prost-reflect's canonical form but for two differences the design
  allows: a float without presence received as `-0` is written as `0`
  (§3.4), and a singular `Empty` field is always written as `{}` (§3.5);
  an `Any`'s packed message comes back as it arrived. The test writes
  them, with the modules generated from the protos under the default
  options, `int64=int`, `enum_unknown=zero` and `bytes=bytes`, into
  `tests/Generated/` on every run (`just codec-gen`); none of it is
  committed, since the corpus already shows a change to the generator's
  output in review and the fixed seed makes the samples the same each
  run. `tests/Codec/RoundTripTest.elm` decodes every form with each set's
  generated decoder, re-encodes it and compares the JSON structurally,
  numbers by value, then checks what each option changes. Its known
  gap: the sampler is the generator's own reading of the descriptors
  and the oracle is prost-reflect's, so a misreading both share passes,
  and a value prost-reflect cannot write is not sampled (a `DoubleValue`
  or `FloatValue` holding NaN or an infinity, which it writes as
  `null`; an `Any` without a type URL).

### Live verification *(Decided 2026-10-15)*

The corpus and the route fixtures prove what is generated and what
request a call becomes; nothing above proves that a server accepts
that request or that the runtime reads its answer. The HTTP path
(`Rpc.task`, `send`, `sendTraced`, retries, timeouts,
`withCredentials`, trackers, the error reader and the transcoding
request builder) was compile-checked and unit-tested only. Five
workstreams, in order, closed that; all five are built (2026-10-15):

1. **Runner**: one example API, one server answering it over
   Connect and transcoding from one process, and a headless runner
   that drives the compiled runtime from Node over ports.
2. **Connect conformance suite** (`connectrpc/conformance`): a Node
   wrapper makes the runner a client under test, with
   a config declaring what is supported (unary, the JSON codec,
   HTTP/1.1, no compression, GET for idempotent methods). Streaming, the
   binary codec and gRPC-Web are declared unsupported rather than
   known-failing.
3. **Transcoding live tests**: a table of calls against the server
   asserting path, query, body, response and the `google.rpc.Status`
   error body, reusing the route fixtures' expectations where they
   overlap.
4. **Examples**: `examples/notes/` gains a browser application over
   either transport and a walkthrough; the README's snippets move into
   it so CI compiles them.
5. **CI**: a `live` job on Ubuntu, built with the
   runner and given its caches with the examples.

Decisions:

- The server is Go: connect-go and Vanguard, the canonical Connect
  stack, whose transcoder is the likeliest one in front of a Connect
  service. connect-go v2 and Vanguard v0.5 mount side by side
  (`connecthttp.Mount`, `vanguard.Mount`); Vanguard serves the rules
  alone, and a method without one is reached on its Connect route,
  which is the implicit route (§5.3).
- buf generates the example, so the plugin runs under buf for real:
  googleapis is a module of the example's workspace, its files reach the
  plugin as imports only, and nothing is generated for them. `just
  live-gen` also generates the Elm under `buf generate
  --include-imports` (`buf.gen.include-imports.yaml`) and checks it
  gives the committed files, so the googleapis files that only carry
  `google.api.http` are not generated when asked for either (§3.1).
- *(Decided 2026-10-15.)* The protos generation reads are vendored, not
  fetched: googleapis' few files the example imports
  (`examples/notes/third_party/googleapis/`) and the conformance suite's
  (`conformance/live/suite/proto/`), each exported once with `buf export`
  at the commit the Buf Schema Registry pinned and refreshed by `just
  protos-refresh`. Fetching them was a dependency on the registry being
  up whenever buf's cache was cold, a developer's first run or CI's
  after a pin changed, and the registry was unavailable five times in one
  day of runs; vendored, `buf generate` needs no network.
- HTTP/1.1 only, without TLS: elm/http cannot choose a protocol, and a
  browser handles the rest.
- The runner sends through its own `XMLHttpRequest` over `node:http`
  (`conformance/live/xhr.mjs`), the subset elm/http uses, with a
  browser's whole-exchange timeout; it hides no response header and
  reports each exchange, so a case can assert what went over the wire.
  xhr2 was the candidate and was not taken: unmaintained since 2022,
  its timeout is socket idleness and its status text is invented.
- `just live` is not part of `just check`, which needs neither Go nor
  the network; CI runs it as its own job.

The live suite (`conformance/live/`, layout in `conformance/README.md`): the
example API and server under `examples/notes/`, the runner (`Live.elm`,
a dispatch table per service, `run.mjs`) and the smoke suite
`cases/notes.json`, which runs every method over both transports, the
error reader's four sources (a Connect body, a `google.rpc.Status`
body, `grpc-status` headers, a bare status) with `ErrorInfo` and
`BadRequest` details decoded from each body, timeouts (a
`NoAnswer Timeout`, the server never answering first), retries,
Connect GET (with the config's and the call's headers) and `maxGetUrl`,
percent-encoded path values, `viaBinding`
in and out of range, and `sendTraced`, `send`, `task` and
`taskFromRequest` (a header rewritten between `Rpc.request` and it,
seen on the wire on every retry).

The Connect conformance suite: `connectconformance`
v1.0.6, fetched from its GitHub release with its SHA-256 pinned per
platform (a Go `tool` dependency would have put the suite's modules in
the example server's `go.mod`), runs its reference server and
`conformance/live/conformance.mjs`, which reads the suite's
`ClientCompatRequest`s with the JavaScript protoc-gen-es generates, makes
each call through the runner with the Elm protoc-gen-elm-connect
generates from the same protos (`streaming=skip`; the three streaming
methods are its only warnings; the protos are v1.0.6's, vendored in
`conformance/live/suite/proto/`), and reports what the runtime gave. The
config (`conformance.yaml`) selects 40 test cases: basic success,
`Unimplemented`, every error code, Connect's mapping of a bare HTTP
status, error metadata, duplicate metadata, Unicode messages, deadline
propagation, a timeout, Connect GET and cancellation. The proto-codec
suites (unexpected and empty answers, error end-streams) do not apply.

- Calls go through the pure halves (`Rpc.request`, elm/http,
  `Rpc.response`), which give an application the answer's headers, and
  are run again through `Rpc.sendTraced`, whose `Trace` gives them
  split into headers and trailers. 40 of 40 pass through the halves, 39
  through `sendTraced`; `known-failing.txt`, for what fails whichever
  way, lists none.
- Cancellation is live: `Client Cancellation/unary/cancel-after-close-send`
  becomes an envelope with `cancelAfterMs`, the runner sends the call
  under a tracker and issues `Rpc.cancel` that long after, records the
  cancellation itself as an application does, and reports whichever
  outcome comes first, so the race of §5.2 is reported once.
  The smoke case `connect cancel` does the same through `send`, and
  asserts the exchange was aborted.
- Known failing through `sendTraced` only (`known-failing-send.txt`):
  `cancel-after-close-send`: `sendTraced` and `task` ignore the tracker,
  so the runner refuses to cancel a call sent so rather than report it
  cancelled while it runs on. `Basic/unary/success`, `Connect with
  GET/success`, `Duplicate Metadata/unary/success` and `unary/error`, and
  `Errors/unary/error-with-metadata` assert the answer's headers and
  trailers; they failed through `sendTraced` until the `Trace` carried
  them (2026-10-15), and would through `send` and `task`, which do not
  give them (§5.2).
- A transport failure is reported to the suite as an error, `Timeout`
  as `deadline_exceeded`: the wrapper's reading of the runtime's
  `NoAnswer Timeout`, as a Connect client gives its own deadline.
- The receive limit is declared (`supportsMessageReceiveLimit: true`,
  2026-10-20): the wrapper applies a request's `message_receive_limit`
  with `withReadMaxBytes` (0 is no limit) and reports `ResponseTooLarge` as
  `resource_exhausted`. v1.0.6 has no client-mode case that relies on
  it (its one such suite, Server Message Size, tests servers over the
  proto codec), so the count stays 40; the live suite's `readMaxBytes`
  cases in `cases/notes.json` run the knob against the example server
  over Connect and transcoding. The suite has no client feature for the
  send limit; the `writeMaxBytes` cases there show a refused
  call sends nothing, and a GET's limit counts the JSON before
  it is percent-encoded.
Workstream 3: the example server also serves the
route fixtures' `routes.v1.Routes` under Vanguard, each method echoing
the request Vanguard decoded, and `conformance/live/routes.mjs` sends
every fixture through the runtime with its binding. It checks (a) the
request against the fixture (verb, path, query pairs as sent, body
compared as the fixtures' own checks compare it, a fixture's headers),
(b) HTTP 200 and the echo equal to the fixture's request, both read as
proto3 JSON (a field without presence at its default left out, one
with presence kept when set, 64-bit integers as strings, enums by name,
bytes, durations and timestamps in one form), and (c) the runtime's
`ok` equal to the echo. `cases/transcode.json` adds the error bodies as
they go over the wire. Found, and recorded in
`conformance/live/known-divergent-vanguard.json`, where the run asserts
Vanguard's answer so that a change either way is noticed:

- `routes.proto` cannot be served whole: `GetMessage`'s first and third
  bindings are both `GET /v1/messages/*`, and `UpdateMessage` and
  `UpdateMessageWhole` share `PATCH /v1/messages/{message_id}`. Vanguard
  refuses the second route; the server serves each refused binding on a
  second transcoder under `/layer/1`, and its fixture runs there. The
  fixtures join http.proto's separate examples into one rule; a client
  can follow it, no router can serve it.
- A `google.protobuf.StringValue` set to `""` is sent as `label=`, which
  Vanguard rejects (it quotes a wrapper's value for protojson only when
  non-empty). Vanguard's bug; it accepts `maybe_name=` for a plain
  string.
- A path variable under an unset message was sent as an empty segment
  (`/v1/typed/0/false/KIND_UNSPECIFIED/0/`), which Vanguard rejected as
  no int32. The runtime now writes the field's default (§5.3), and
  Vanguard accepts `/v1/typed/0/false/KIND_UNSPECIFIED/0/0`; it reads
  `inner` and `inner.deep` as set and empty where the request left
  them unset. Neither end is wrong: a path segment sets its field and
  every message on the way, and no path leaves them unset.
- An unset body field sent as `{}` reaches the server as a set, empty
  message. Neither end is wrong: the wire has no other form for it.

Also seen, not a divergence: with `body: "*"` the runtime sends
`"sub": {}` for a message whose only field the path holds, which the
fixtures' comparison drops. It also wrote fields at their defaults
until encoders left them out (§3.4).

Workstream 4: `examples/notes/elm/` is a browser
application (`Main.elm`) that lists, creates, edits with an update
mask, archives and deletes notes, and shows each error's code, message,
source and details (`google.rpc.BadRequest` and `ErrorInfo` by type,
from `Google.Rpc`, which buf generates from googleapis'
`error_details.proto` with `buf.gen.google-rpc.yaml`), with a toggle
between the two transports. Every call goes through one function,
`Api.rpc`, the wrapper §5.1 describes. It reuses the generated
tree the runner compiles, `examples/notes/elm/generated`, whose drift
`just live-gen` checks. The server's `-static` flag serves the page and
the API from one origin; `just example-notes` builds and runs both. The
walkthrough (`examples/notes/README.md`), the root README and the `docs/`
guides quote it:
each Elm, proto, JSON or YAML block names the file it is from in its
fence (a `region` comment pair, consecutive lines, or `excerpt` for lines
in order from a generated file), `examples/check-snippets.sh` checks
every one in `just check`, and `just live` compiles the application and
`src/Snippets/`, the README's and the guides' examples the application does not
contain. A snippet that computes something, the update mask's, has
tests in the example's `tests/`, which `just check` runs against the
generated notes modules. The service-module snippets of §2.1 and §4 stay illustrations:
they elide (`…`) what the generated module spells out, and §4's is
pinned by the `services` case's expected output. Not verified: the
application is driven by hand in a browser, not by the live suite; the
calls it makes are the suite's.

Workstream 5: the `live` job caches Go's modules and
build cache, npm's downloads, Elm's packages and the `connectconformance`
binary, each keyed on the files that pin it (`go.sum`;
`package-lock.json`; the `elm.json`s; `fetch-conformance.sh`), and
Envoy's release, keyed on `conformance/live/envoy/envoy-version`, and
runs `just live`, which builds the example.

grpc-gateway: the example server mounts grpc-gateway
v2.32.0 under `/gateway` beside Vanguard, in front of the same service,
and `just live` runs the transcode cases of `cases/notes.json` (`run.mjs
--transport transcode`; they make the notes they delete, so they run
alone), `cases/transcode.json` and the route fixtures against it
(`--prefix /gateway`), each fixture's divergence recorded
in `conformance/live/known-divergent-gateway.json` as Vanguard's are in
`known-divergent-vanguard.json`, with a reading and the answer the run
asserts.

- The gateway proxies over gRPC, as one deployed in front of a gRPC
  service does: generated with `protoc-gen-go-grpc` and
  `protoc-gen-grpc-gateway` (`generate_unbound_methods=true`, so a
  method without a rule is served at its implicit route), registered
  over a `grpc.NewClient` connection to the server's own address, where
  connect-go serves gRPC; the server accepts HTTP/2 without TLS for it.
  connect-go's gRPC handler sends a service error with its details, and
  the gateway writes it as a `google.rpc.Status` body: the error cases
  pass unchanged. Calling the service in process
  (`Register…HandlerServer`) would skip the hop but needs the errors
  translated by hand, which is not what a deployment does.
- The gateway runs with its defaults (`runtime.NewServeMux()`), as a
  deployed one most likely does; where an option changes an answer, the
  reading says so.
- protoc-gen-grpc-gateway refuses two bindings with one verb and path
  template in a service ("duplicate annotation"), so `routes.proto`
  cannot be generated whole: `UpdateMessageWhole` is left out of
  `buf.gen.gateway.yaml` (buf's `exclude_types`) and generated alone,
  standalone, by `buf.gen.gateway-apart.yaml`, onto a second gateway mux
  under `/gateway/layer/1`. Templates that differ but match the same
  paths, `GetMessage`'s `GET /v1/{name=messages/*}` and `GET
  /v1/messages/{message_id}`, are both generated, and the mux tries the
  binding registered last first, so the fixture for the first is
  answered by the second. Neither end is wrong: no router can serve that
  rule whole.
- grpc-gateway keeps a `google.protobuf.FieldMask` query value's paths
  as written, so the JSON form the runtime sends (`mask=displayName`)
  reaches the service as a path no field has; the gateway is wrong by
  proto3 JSON. Two fixtures fail with it, with `UNKNOWN`: the
  well-known types in the query, and `UpdateResource`'s `update_mask`.
- A single-segment variable holding `/` (`%2F`) is not found: the
  gateway's default unescaping mode splits the decoded path. The gateway
  is wrong by http.proto; `UnescapingModeAllExceptReserved`, which it
  documents as the next default, serves the fixture.
- As under Vanguard, a path value under an unset message and an unset
  body field sent as `{}` reach the service as set, empty messages.
- Where the gateway agrees with the fixtures and Vanguard does not: a
  `StringValue` set to `""` and sent as `label=` is accepted.
- Where the two transcoders differ beyond the fixtures, each known file
  holds the same probes, requests the runtime does not make, with that
  transcoder's answer: an unknown query parameter (Vanguard 400,
  grpc-gateway drops it), a verb a path has no route for (405 against
  501, both `UNIMPLEMENTED` in a `google.rpc.Status` body), and `PATCH`
  without an update mask, which grpc-gateway fills from the body's
  fields (its `allow_patch_feature`, AIP-134's implied mask, applied for
  the service). Neither is wrong in any of them.
- Also seen, not a divergence: the gateway writes every field, an unset
  message as `null` (in an error's details too), which the runtime reads
  as unset, and passes the gRPC response headers on as
  `Grpc-Metadata-*`.

Envoy: `just live-envoy` (part of `just live`, and of CI's `live` job)
runs Envoy 1.40.0's gRPC-JSON transcoder through func-e, which mise
pins, in front of the example server, calling it over gRPC
(`conformance/live/envoy/envoy.yaml`; the walkthrough is
`docs/envoy.md`). Two listeners differ only in `convert_grpc_status`:
the transcode cases of `cases/notes.json`, `cases/transcode.json` and
the route fixtures run against the one that writes a
`google.rpc.Status` body, and `cases/envoy.json` against Envoy's default,
the error in `grpc-status` and `grpc-message` headers with no body,
which the runtime reads as `GrpcHeaders`, without details.

- Envoy reads the rules from a descriptor set buf builds from the
  example's protos, so no binding is served apart:
  `known-divergent-envoy.json` has `servedApart: null`, and `routes.mjs`
  runs every fixture at the root without reading the server's layers.
- Envoy passes a request no method matches, or one with a query
  parameter naming no field, to the server untranscoded, where the
  server's own transcoder would answer; the config sets
  `reject_unknown_method` and `reject_unknown_query_parameters`, so
  Envoy answers them (404 and 400, plain text). The canned answers of
  the cases are reached past Envoy, at the server (`run.mjs --origin`).
- Envoy's default `url_unescape_spec`, `ALL_CHARACTERS_EXCEPT_RESERVED`,
  leaves `%2B` and `%3A` encoded in a multi-segment variable, against
  http.proto; the config sets `ALL_CHARACTERS_EXCEPT_SLASH`, which
  agrees.
- A verb and path registered twice (the two pairs above) are marked
  ambiguous by Envoy's path matcher and served by neither binding, with
  no warning: five fixtures get 404. Envoy is wrong to stay silent; no
  router can serve that rule whole.
- Envoy answers the `HEAD` binding with its JSON body after the
  headers, which Node's HTTP parser refuses, so the runtime reports
  `NetworkError`. Envoy's bug by RFC 9110.
- As under the others, a path value under an unset message reaches the
  service as a set, empty message.
- Where Envoy agrees and another does not: an empty `StringValue` as
  `label=`, and a `FieldMask` in the query in its JSON form.
- Also seen: Envoy writes its own HTTP/1.1 reason phrase, `Unknown` for
  a status it has no name for, which becomes an `HttpStatus` error's
  message; and the header-only form carries no details.

What is now verified live, against connect-go, Vanguard, grpc-gateway
and Envoy: every method of the example API over both transports, from
Node in CI (transcoding under all three transcoders) and by hand from
the example in a browser (under Vanguard); `task`, `send`, `sendTraced`,
retries, timeouts, `withCredentials`, trackers and Connect GET; an
answer's headers and trailers reaching the application through the
halves and the `Trace`; the error reader's four sources with details;
the transcoding request builder on every route fixture, under all three
transcoders; the error reader's header-only form against Envoy; the Connect conformance suite's unary JSON cases;
`taskFromRequest` with a rewritten request; and cancellation, through
the halves and through `send` (§5.2). Not live: `response_body`
(§5.3).

Recorded for later: a pass of small, well-documented examples for learning from (medium priority, 2026-10-15): the notes
example was meant to double as the implementation to consult, and
serves verification well, but carrying both transports, the error
panel and the live suite's needs makes it too much to learn from
first; teaching wants a few short examples that each show one thing,
kept compiling the same way.

## 8. Compatibility and versioning  *(Decided)*

### 8.1 One version

- The Elm package (`elm.json`) and the three crates (the Cargo
  workspace's version) carry one version number and are released
  together, under one git tag: the bare version, `1.2.3`, without a
  `v`, because the Elm package index requires a release's tag to equal
  its version.
- A release's magnitude is the largest any surface needs (§8.3). Elm
  computes the runtime's magnitude from its API diff and enforces it at
  publish, so the runtime can be no lower than that; when the generator
  alone needs a minor or a major, the runtime's number is pushed up on
  purpose through `Proto.Version` (§8.2), whose new value is an
  addition Elm counts as a minor, and whose removed values are a major.
- Why lockstep: generated code and the runtime are halves of one
  program that reach an application by two channels, and the only
  pairing worth supporting is one the gate has compiled together. One
  number makes that pairing obvious to a user (make them match) and to
  the compiler (§8.2); independent numbers would need a compatibility
  table, and a CI matrix to keep it true.
- Before 1.0.0, both carry the same `0.x` number (`0.1.0` now). Elm
  checks the number only at publish, which requires `1.0.0` for a
  package's first release, so the package and the crates move to
  `1.0.0` together at its first publish. Until then an application
  takes the runtime from this repository at the matching tag.
- The agreement is tested (`crates/elm-connect-gen/tests/lockstep.rs`):
  the workspace's version is `elm.json`'s, and the corpus's header
  placeholder (§8.4) is that release's.

### 8.2 The compatibility sentinel

- The runtime's `Proto.Version` exposes an opaque type, `Generated`,
  and one value of it per released minor: `v0_1` now. Every generated
  module imports it and defines, after its imports,

  ```elm
  {-| The elm-connect release this module was generated for: a compile error here means the runtime package is from another release.
  -}
  elmConnectVersion_ : Proto.Version.Generated
  elmConnectVersion_ =
      Proto.Version.v0_1
  ```

  naming the value of the release that generated it,
  `v{major}_{minor}` of the generator's version
  (`elm_connect_gen::SENTINEL`, derived from `CARGO_PKG_VERSION` at
  build time). This is protobuf-go's `protoimpl.EnforceVersion` and
  swift-protobuf's `ProtobufAPIVersion_N` in Elm: a mismatch is a
  compile error at a line that names the problem, before any codec
  disagrees at run time.
- The trailing underscore marks the name as the generator's own, as it
  does a recursive message's wrapper (`Node_`, §3.2): a derived value
  name drops underscores when casing, and only the reserved-word escape
  adds one, so no proto name derives to `elmConnectVersion_`, and a
  `rename` to a value cannot end in `_` (`options::invalid_rename`,
  §3.7).
- A value is added at every minor release, and every value of a major
  is kept until the next major removes them all. So a runtime newer
  than the generated code, within its major, compiles it; an older
  runtime fails with Elm's own error, "The `Proto.Version` module does
  not expose a `v0_2` variable", and the module's documentation says
  what that means: regenerate with the generator matching the package,
  or install the package version the generated code names. Before 1.0,
  the `v0_N` values accumulate through `0.x`, and 1.0.0 removes them
  all and exposes `v1_0` alone.
- The sentinel is strict: generated code names the release that
  generated it, not the oldest runtime it could run against, so the
  ordinary gate, the corpus compiled against the runtime of the same
  commit (§7), proves exactly the pair that ships. A looser variant is
  recorded for later: as protobuf-go's generated code names a minimum
  runtime vintage, the generator could name the oldest release whose
  runtime has everything the generated code uses. That changes only
  the generator (which value it names) and adds a CI job compiling the
  corpus against that older runtime.
- `crates/elm-connect-gen/tests/lockstep.rs` tests that `Proto.Version`
  exposes the value `SENTINEL` names and every earlier value of its
  major, and that every expected module of the corpus names it.

### 8.3 The surfaces and their promises

Within a major version:

- **Generated code to runtime.** Enforced by the sentinel (§8.2): a
  pairing it admits compiles.
- **Generated code to user code.** Regenerating the same protos with
  the same options gives code the same application compiles against:
  the same modules, types, constructors, record fields and values, at
  the same types, plus possibly new definitions.
- **Wire behaviour.** What a call sends and how its answer is read is
  pinned by the route fixtures, the conformance corpus and the live
  suite, the Connect conformance suite among it (§7). A fix that makes
  a wrong encoding right is a patch, though it changes what is sent.
- **The runtime's namespaces are the runtime's.** Any release, a minor
  or a patch one included, may add modules named `Rpc.*` or `Proto.*`.
  A generated module there (`naming::runtime_namespace`, §3.1) is the
  user's risk: a later release's module of the same name makes every
  import of it ambiguous, and that is not a break of this contract.
- **The CLI's and the plugin's options, and diagnostic codes.**
  Additive: options, values and codes are added, and none is removed or
  changes meaning. A diagnostic's text, help and rendering are not a
  contract.
- **The runtime's types: opaque or frozen.** Every type generated code
  builds is opaque, built by functions and read by accessors, so it can
  grow within a major by new modifiers and accessors, and code
  generated by an earlier minor keeps compiling: `Proto.Message.Message`,
  `Proto.Enum.Enum`, `Proto.Method.Method`, and the descriptor trees,
  the `Descriptor` of `Proto.Message`, `Proto.Field`, `Proto.Enum`,
  `Proto.EnumValue` and `Proto.Method` (§3.9), with `Rpc.Call`, `Proto.Any.Any` and
  `Proto.Registry.Registry`; so are the types a config holds or the
  runtime gives, `Rpc.Transport.Transport`, `Rpc.Retry.Retry`,
  `Rpc.Trace.Trace` and `Rpc.Body.Body`. The records an application
  builds or reads with record syntax are frozen within a major:
  `Rpc.Config`, `Rpc.Request.Request`, `Rpc.Response.Response`
  (which `Rpc` also names `Rpc.Request` and `Rpc.Response`) and
  `Rpc.Error.StatusError`. A new
  config knob goes where §5.1 routes it (a protocol's on `Transport`, a retry's on
  `Retry`, a call's on `Call`, hooks on a future `Rpc.Client`), never
  into `Config`. The public unions are
  frozen within a major, since users match on them exhaustively:
  `Proto.Field.Cardinality` (with `CardinalityRequired` reserved for
  proto2), `Kind` (whose `KindEnum` holds the enum's descriptor and
  `KindMessage` the message's full name, §3.9), `Scalar`, `Behavior` (with
  `BehaviorUnknown Int` holding a number this release does not name, so
  that naming it later is a minor), `Proto.Method.Idempotency`,
  `Rpc.Code`, and `Rpc.Error`'s `Error`, `Reason` (`Timeout`,
  `NetworkError`, `BadUrl`, `InvalidHeader`, `RequestTooLarge`,
  `ResponseTooLarge`) and `Source` (with `GrpcTrailers` and
  `ConnectEndStream` reserved for server streaming, which reads a
  status from those two places, so that it can ship as a minor; a
  failure before an answer is read is one of the reasons, and a new kind
  found in an answer that was read is a `BadResponse`, §5.4).
- **The `elm-connect-gen` crate.** Published so that `cargo install`
  builds the binaries; its API is not covered by this contract and may
  change in any release, as its crate documentation says.

### 8.4 Provenance

- The first line of a generated module names the exact version that
  wrote it: `-- Generated by elm-connect 0.1.0 from notes.proto. Do not
  edit; regenerate instead.` It is provenance for bug reports, as every
  peer generator writes, and nothing checks it; `elmConnectVersion_` is
  what the compiler checks. A file whose name holds a control character,
  which would end the comment early, is `input::file_name`.
- The conformance corpus's expected modules and the route replay's
  modules in `tests/Routes` carry a placeholder on that line, the major
  and minor version with `X` for the patch: `-- Generated by
  elm-connect 0.1.X from ...` (`elm_connect_gen::HEADER_VERSION_PLACEHOLDER`,
  derived beside the sentinel's name). Their tests put it in place of
  the version before comparing, and `just bless` writes it, so a patch
  release leaves them alone. A minor or major release still re-blesses
  each, for the header's minor and the `elmConnectVersion_` line, which
  is real code the harness compiles. The other committed generated
  trees keep the real version: the notes example's, which is what a
  user sees and whose drift `just live` fails on, and the conformance
  suite's, which the plugin writes through buf; every release
  regenerates them.

### 8.5 The drift check

- `elm-connect check` takes exactly `gen`'s arguments and
  options, generates in memory, and compares with the tree under
  `--out`: a module whose file is missing, a file whose content differs
  (printed as a unified diff, its sides labelled with the real path, `(on
  disk)` and `(generated)`), and a stale file, an `.elm` file under
  `--out` whose first line is the generated-file notice above naming a
  proto file the run generated from, but which generating no longer
  gives. Files without the notice are left alone, since an application
  may keep its own modules in the same directory. *(Decided.)*
  A generated file whose notice names none of the run's protos is left
  alone too: two `gen` runs may share an `--out` (two APIs, or one
  package under other options), and each run's check would otherwise
  call the other's modules stale. Matching the notice's `from` list is
  smaller than a `--stale=report|ignore` flag and needs no choice from
  the user; its cost is that a module whose protos were all removed
  from the command line is no longer reported, which a regenerate into
  an emptied directory catches. The notice names each proto by its path
  under the include directory, so `check` must be given `gen`'s `-I`
  too, or every module differs on its first line. `gen` deletes nothing;
  after writing it warns on stderr about each stale file by the same
  rule, and says how many modules it wrote.
  When every difference is in the header line or the `elmConnectVersion_`
  line, it prints one message naming the version that generated the
  tree and its own, and says to regenerate. It exits 0 when the tree is
  current, 1 on drift, and 2 when it cannot tell: bad arguments, an
  error generating, an unreadable directory (`gen` exits 1 on an error).
- The plugin cannot check, since protoc writes its files. With protoc
  or buf, run `elm-connect check` on the same protos and options, or
  regenerate and `git diff --exit-code` the output.

### 8.6 Elm compilers

- Elm 0.19.2 is the development target; 0.19.0 and 0.19.1 are checked
  in CI. *(Decided.)* A CI job per earlier release installs the
  official Linux binary (checksum pinned) and runs
  `conformance/compile-with.sh`, which compiles the runtime package (with
  `--docs`) and every case's expected output against a copy of the
  harness set to that release. Nothing the 0.19.2 output needs is refused
  by 0.19.0 or 0.19.1 so far. Decoders for messages with more than eight
  fields use the runtime's pipeline helpers rather than `map8` chunking.
- The same job runs the runtime's and the notes example's Elm tests,
  fuzz tests included, with elm-test-rs under that release
  (`conformance/test-with.sh`, `just test-with`), the example from a
  copy of its `elm.json` set to the release. Under 0.19.1 only:
  elm-test-rs's runner package (`mpizenberg/elm-test-runner` 6) requires
  Elm 0.19.1, so 0.19.0 cannot run the tests, and is held to the compile.
- What CI checks, all told: `just check` on Linux and macOS (formatting,
  clippy, the Rust tests with the corpus, the plugin's replay and the
  lockstep test, the runtime's build and Elm tests, the README's
  and the guides' excerpts, zizmor, gitleaks, `cargo deny` and `cargo package`), with
  the toolchain mise pins, which is the crates' `rust-version`; `just
  live` on Linux (§7); and the job above per earlier Elm release.

### 8.7 Releasing

A release is a commit on `main` tagged with its bare version (§8.1),
and what `.github/workflows/release.yml` builds and publishes from that
tag. The maintainer makes the commit and pushes the tag; the workflow
does the rest, and refuses a tag whose commit skipped a step it can
check.

By hand, before the tag:

1. Set the version in the Cargo workspace and in `elm.json`, and, for a
   minor or major, add its `Proto.Version` value (§8.2).
   `tests/lockstep.rs` fails until they agree, in the gate and again in
   the workflow.
2. Run `just bless`, then `just live`, and commit the regenerated
   trees (§8.4).
3. In `CHANGELOG.md`, turn `## Unreleased` into `## <version>` followed
   by the release date, and start a new, empty `## Unreleased` above
   it. The first release does this once over everything listed so far;
   after that, Unreleased holds only what is new since the last
   release. The section is the release's notes: the workflow publishes
   it as the GitHub Release's text, and refuses a tag without it.
4. From 1.1 on: check out the last release's tag beside this commit,
   compile its corpus's expected output against this commit's `src/`
   (`conformance/compile-with.sh` with the harness's source directories
   pointed there), and run `elm diff <last tag>`, whose magnitude must
   not exceed the release's (§8.1). Code generated by the last minor
   must compile against this runtime (§8.3). This step stays manual; a
   CI job for it is on the [roadmap](roadmap.md).
5. Tag the commit on `main` with the bare version, `git tag 1.2.0`, and
   push the tag.

What the tag runs (`.github/workflows/release.yml`), in order:

6. `verify`: the tag equals the workspace's and `elm.json`'s version,
   the tagged commit is on `main`, `CHANGELOG.md` has the tag's
   section, the lockstep test passes, and `cargo package --workspace
   --locked` packages the crates from the tagged tree. `build`, beside
   it, builds both binaries for six targets, each on a runner of its
   own platform, `x86_64-unknown-linux-musl`,
   `aarch64-unknown-linux-musl`, `x86_64-apple-darwin`,
   `aarch64-apple-darwin`, `x86_64-pc-windows-msvc` and
   `aarch64-pc-windows-msvc` (musl so the Linux binaries run on any
   distribution), runs each binary once (its `--version`, then `gen`
   and `check` on a small proto), and packs one archive per target,
   `elm-connect-<version>-<target>.tar.gz` (`.zip` on Windows), holding
   the two binaries, `LICENSE-MIT`, `LICENSE-APACHE` and
   `THIRD_PARTY.md`.
7. Once both are green, the maintainer approves `publish` under the
   `release` environment. It writes `SHA256SUMS` over the archives,
   attests the archives and `SHA256SUMS`
   (`actions/attest-build-provenance`, verified with `gh attestation
   verify`), and creates the GitHub Release with them and the CHANGELOG
   section as its notes; a `0.x.y` tag makes a pre-release, and
   produces nothing else. From `1.0.0` on, two more jobs wait behind a
   second approval once the Release exists: `crates` publishes
   `elm-connect-gen`, then `protoc-gen-elm-connect` and `elm-connect`,
   to crates.io, and `elm` runs `elm publish`, which checks that the tag
   on GitHub names the commit being published and that the tree
   matches it, then builds the package's documentation again and
   compares it with the copy the package index serves, failing on any
   difference. The comparison confirms the index stored what the job
   built; it is `elm publish`'s own checks that tie the package to the
   tag. Two approvals rather
   than one, so the Release can be looked at before the registries,
   which have no undo, receive anything.

A `workflow_dispatch` run on any branch rehearses the workflow:
`verify` and `build` run, the archives are kept as the run's artifacts,
and nothing is created. With `rehearse_gate` set, on `main`, one empty
job runs under the `release` environment, so the approval prompt can be
seen working.

What protects a release:

- A tag ruleset covers tags matching `[0-9]*.[0-9]*.[0-9]*`: once
  pushed, such a tag cannot be moved, force-pushed or deleted, and the
  ruleset has no bypass, so it holds for the maintainer too. Creating
  one is not restricted by the ruleset; only the maintainer has push
  access.
- The `release` environment requires the maintainer's review before any
  job under it runs, and accepts only tags matching the same pattern
  and the `main` branch. `main` stays listed after the first
  rehearsal: every change to the workflow is rehearsed from `main`
  before a tag depends on it, and the jobs that publish anything run
  only on a tag push, so a run from `main` can build, keep artifacts
  and ask for approval, and nothing more.
- Every job that reads the source checks out the tag afresh, without
  persisted credentials, and the workflow uses no caches, so nothing an
  earlier run left behind reaches a release. Each job holds only the permissions it
  needs, and only the jobs under the environment can write.
- The binaries are built with exactly the workspace's `rust-version`,
  which the workflow reads from `Cargo.toml`, and with `--locked`, so
  with the dependency versions `Cargo.lock` pins and CI tests.

Releases come from `main`: the work is iterated there until it is
ready, the CHANGELOG is folded, and the tag is pushed. There are no
release branches and no release-candidate tags, and the workflow holds
to that: `verify` refuses a tag whose commit is not on `main`, and the
tag pattern takes no suffix. An Elm package version is a bare
`MAJOR.MINOR.PATCH`, so a `1.0.0-rc.1` could carry binaries and crates
but never the package; the `0.x` line is the candidate line instead,
each `0.x.y` tag a pre-release on the same path `1.0.0` takes. A
candidate build with no version spent is a `workflow_dispatch` run on
`main`: its archives are the run's artifacts. A release branch would
become necessary only if a `1.x` ever needed patches beside a `2.x`
([roadmap](roadmap.md#release-branches)).

When a release fails: a tag is never moved, so a fix goes forward,
under the next patch version, with its own commit and tag. Rerunning
the workflow on the same tag recreates nothing that exists: a GitHub
Release is made once, and `publish` fails rather than replace one.

crates.io: the three crates' first versions, `0.1.0`, are published by
hand once, from the checkout of the `0.1.0` tag, with a short-lived
token scoped to publishing. Trusted Publishing is then configured on
crates.io for each crate, naming this repository, `release.yml` and the
`release` environment, and from `1.0.0` on the `crates` job publishes
with a short-lived token crates.io issues to that workflow run. crates.io has no
unpublish, only yank: a published version stays.

## 9. Open questions, collected

The questions this section collected are settled, and recorded with
their reasons in [decisions.md](decisions.md).

## 10. Out of scope but recorded

What 1.0 leaves out, and what may come after it, is in
[roadmap.md](roadmap.md), each item with whether it would be a minor or
a major release.
