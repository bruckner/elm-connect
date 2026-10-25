# The generator

The generator turns `.proto` files into Elm modules. It comes as two
binaries with the same options and the same output: `elm-connect`, a CLI
that compiles the protos itself, and `protoc-gen-elm-connect`, a plugin
for protoc and buf. [install.md](install.md) installs them.
`elm-connect --help` says where to start, and `elm-connect guide` prints
the [guide](guide.md), for a reader with only the binary.
The protobuf language and the JSON mapping the generator follows are
listed, with links, in [specs.md](specs.md).

## What a proto becomes

Each package becomes a module of its types and their JSON codecs
(`notes.v1` → `Notes.V1`), each service a module of one function per
method (`Notes.V1.NotesService`), and each message and enum a module of
its descriptor (`Notes.V1.Note`, [descriptors.md](descriptors.md)). The
forms below are those of the default options unless a row says
otherwise.

| Proto | Elm |
|---|---|
| `message Note` | `type alias Note = { … }`, a record with a field per proto field in declaration order, named in lowerCamelCase (`create_time` → `createTime`); with it `defaultNote`, `encodeNote`, `decodeNote` and `messageNote : Proto.Message.Message Note`, its typed value. Build a message from its default by record update, `{ defaultNote | title = "x" }`, rather than as a record literal: the update keeps compiling when the message gains a field. Elm's record update takes an unqualified name, so `{ Notes.V1.defaultNote | … }` does not compile; bind the default first, `let note = Notes.V1.defaultNote in { note | title = "x" }` ([quick start](quickstart.md#4-send-a-call)) |
| `string`, `bool` | `String`, `Bool` |
| `int32`, `uint32`, `sint32`, `fixed32`, `sfixed32` | `Int` |
| `double`, `float` | `Float` |
| `int64`, `uint64`, `sint64`, `fixed64`, `sfixed64` | `String`, the exact decimal value (default `"0"`); under `int64=int`, `Int`. A field's `jstype` option overrides either: `JS_STRING` gives `String`, `JS_NUMBER` `Int` |
| `bytes` | `String`, the base64 text as received; under `bytes=bytes`, `Bytes.Bytes` from elm/bytes |
| a field without presence (`string title = 2;`) | the value itself, its default when absent (`""`, `0`, `False`, the enum's zero value) |
| `optional string subtitle = 1;` | `Maybe String` |
| a singular message field, `optional` or not | `Maybe Author` |
| `repeated string tags = 4;` | `List String` |
| `map<string, V>` | `Dict String V` |
| `map<K, V>` with a 32-bit integer key | `Dict Int V` |
| `map<K, V>` with a 64-bit integer key | `Dict String V`, under `int64=int` too |
| `map<bool, V>` | `List ( Bool, V )`, since `Bool` is not `comparable` |
| `enum Visibility` | `type Visibility = VisibilityUnspecified \| VisibilityPrivate \| …`: one constructor per value, the type's name in front of the value's with the enum's own prefix dropped (`VISIBILITY_PRIVATE` → `VisibilityPrivate`), an alias folded into its first value; with it `encodeVisibility`, `decodeVisibility` and `enumVisibility : Proto.Enum.Enum Visibility`. An unknown number decodes as the zero value; an unknown name fails, or under `enum_unknown=zero` is the zero value too |
| `oneof kind { string text = 11; string link = 12; }` | a field `kind : NoteKind`, with `type NoteKind = NoteKindUnset \| NoteKindText String \| NoteKindLink String`; a `google.protobuf.Empty` member has no argument |
| `google.protobuf.Timestamp` | `Maybe Time.Posix` (`Time.Posix` in a list, map or oneof). Code that held instants as RFC 3339 strings, from another generator or by hand, and keyed a `Dict` or a DOM id with them or sorted them, needs another key, since a `Time.Posix` is not `comparable`: `Time.posixToMillis` gives an `Int` to key with (through `String.fromInt` for an id) and to `compare`, which orders by the instant, where the strings ordered by their text |
| `google.protobuf.Duration` | `Maybe Proto.Duration.Duration` |
| `google.protobuf.FieldMask` | `Maybe (List String)`, the paths by proto name: `Just [ "create_time" ]`. A path is not checked: a camelCase one (`"createTime"`) passes through unchanged, and goes out as the same JSON, but a mask the client decodes holds proto names, so the two do not compare equal |
| `google.protobuf.Empty` | `()`, as a field and as a request or response |
| `google.protobuf.Struct` | `Maybe (Dict String Json.Encode.Value)` |
| `google.protobuf.Value` | `Maybe Json.Encode.Value`; `Just` the JSON `null` is a `Value` set to null |
| `google.protobuf.ListValue` | `Maybe (List Json.Encode.Value)` |
| the wrappers (`StringValue`, `Int32Value`, …) | `Maybe` of the wrapped type's form: `Maybe String`, `Maybe Int`; `Int64Value` and `UInt64Value` follow `int64`, `BytesValue` follows `bytes` |
| `google.protobuf.Any` | `Maybe Proto.Any.Any` ([descriptors.md](descriptors.md#any)) |
| a recursive message (`repeated Node children`) | the field that closes the cycle holds a wrapper, `List Node_`, with `type Node_ = Node_ Node`; fields that close no cycle hold the record itself |
| a nested message or enum (`Outer.Inner`) | a type named by its path, `OuterInner`, in the package's module |
| a type of another generated package | the type from that package's module, `Users.V1.User` |
| `service NotesService` | a module `Notes.V1.NotesService`: per unary method a call, `getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note`, and its method descriptor, `descriptorGetNote` |
| a streaming method | a diagnostic; under `streaming=skip`, left out with a warning |
| comments and `deprecated` | each type, call and descriptor is documented with the proto's comment for it, its one-line declaration, and `Deprecated.` where the proto says so; a call also names its Connect path and its HTTP bindings, and a package's module carries the comment on its `package` statement |
| `google.protobuf` itself | nothing: the well-known types map to the runtime |

Every generated module starts with a line naming the elm-connect
version and the protos that produced it, and defines
`elmConnectVersion_`, which [install.md](install.md#versions) explains.
A package is generated whole, from every given file declaring it.

## Names

The Elm names follow from the proto's, by a fixed rule:

- Fields, oneofs and methods become lowerCamelCase from their proto
  names (`create_time` → `createTime`, `GetNote` → `getNote`), not from
  `json_name`, which only changes the wire.
- A leading run of capitals is lowercased as one word: `ID` → `id`,
  `URLPath` → `urlPath`, `HTTPGet` → `httpGet`, and a plural acronym
  with its `s`, `IDs` → `ids`. Leading underscores are dropped
  (`_internal` → `internal`).
- An Elm reserved word gets a trailing underscore: a field `type` is
  `type_`, still `"type"` on the wire.
- Messages, enums and services keep their proto spelling (`URLPath`
  stays `URLPath`); a nested message or enum is prefixed with the names
  of the messages enclosing it (`Outer.Inner` → `OuterInner`). A
  package's segments are capitalized (`notes.v1` → `Notes.V1`).
- An enum value drops the enum's own prefix, or for a nested enum the
  whole nesting path, whichever it starts with, and takes the type's
  name in front: in `message Note { enum Kind { … } }`, both
  `KIND_DRAFT` and `NOTE_KIND_DRAFT` become `NoteKindDraft`.

Two names that meet after these rules are a diagnostic, never a silent
rename ([diagnostics.md](diagnostics.md)), and `rename` (below) gives
any element another name. The design's
[§3.7](design.md#37-naming) has the full rule and its edge cases.

## Options

Both binaries take the same options: the protoc plugin as
`--elm-connect_opt=key=value,key=value`, the CLI as flags.

| Option | CLI flag | Values | Effect |
|---|---|---|---|
| `int64` | `--int64` | `string` (default), `int` | How 64-bit integers are held. `string` is exact; `int` gives Elm `Int`s, and a value outside ±(2^53 − 1) fails to decode. A field's `jstype` option (`JS_NUMBER`, `JS_STRING`) overrides it. |
| `bytes` | `--bytes` | `string` (default), `bytes` | How `bytes` fields are held. `string` is the base64 text as received; `bytes` gives elm/bytes' `Bytes` (add elm/bytes to your `elm.json`), the `BytesValue` wrapper too. `Proto.Bytes` converts either way under both. Beware: Elm's `==` does not look inside a `Bytes`, so any two compare equal: a record differing only in a `Bytes` field equals the other, `Expect.equal` passes when the bytes differ, and a check for whether your model changed misses a change to them. |
| `unbound_methods` | `--unbound-methods` | `implicit` (default), `error` | What a method without a `google.api.http` rule gets. `implicit`: a call like any other, sent over transcoding on the implicit route ([transcoding.md](transcoding.md#methods-without-an-http-rule)). `error`: a `services::unbound_method` diagnostic, for servers that serve rules alone. |
| `streaming` | `--streaming` | `error` (default), `skip` | What a client, server or bidirectional streaming method gets. `error`: a `services::streaming` diagnostic. `skip`: left out of its service's module, with a warning on stderr, and the rest generated. |
| `enum_unknown` | `--enum-unknown` | `fail` (default), `zero` | What an enum value name the client does not know reads as; an unknown number reads as the zero value either way. `fail`: the decode fails, as protobuf's own parsers do. `zero`: the zero value, so a value the server adds after the client was generated does not fail the message it is in, at the cost of telling it apart from the zero value. It applies to every enum of the invocation. Packages can take different values only from separate invocations, each into its own out directory and checked the same way, and only when no message of one refers to a type of another, since a reference to a package the invocation does not generate is `generate::not_generated`. |
| `rename` | `--rename` | `<proto full name>:<Elm name>`, repeatable | An Elm name in place of the one the naming rules derive, for a package (its module), service, method, message, enum, field, oneof or enum value. The escape for names that collide or have no Elm form. |
| `module_prefix` | `--module-prefix` | dot-separated Elm module segments, such as `Api.Notes` | A module every generated module goes inside: with `Api`, `notes.v1` becomes `Api.Notes.V1`, written to `Api/Notes/V1.elm`, and its services' modules follow. A renamed package's module is prefixed too. The runtime's modules are never prefixed. |

For example, to give `notes.v1.Note` the Elm type `Memo` and its field
`title` the record field `heading`:

```sh
protoc -I proto -I googleapis --elm-connect_out=generated \
  --elm-connect_opt=rename=notes.v1.Note:Memo,rename=notes.v1.Note.title:heading \
  notes/v1/notes.proto
elm-connect gen -I proto notes/v1/notes.proto --out generated \
  --rename notes.v1.Note:Memo --rename notes.v1.Note.title:heading
```

To generate every module inside `Api`, so `notes.v1` becomes `Api.Notes.V1`
in `generated/Api/Notes/V1.elm`:

```sh
protoc -I proto -I googleapis --elm-connect_out=generated --elm-connect_opt=module_prefix=Api notes/v1/notes.proto
elm-connect gen -I proto notes/v1/notes.proto --out generated --module-prefix Api
```

These examples use the layout of the [quick start](quickstart.md):
the protos under `proto/`, and for protoc the googleapis files under
`googleapis/` ([install.md](install.md#with-protoc)). protoc writes only
into an out directory that exists (`mkdir -p generated`); the CLI
creates it. The CLI needs no googleapis for `google/api/annotations.proto`,
`google/api/http.proto` and `google/api/field_behavior.proto`, the three
googleapis files it carries ([install.md](install.md#googleapis)).

`rename` takes the proto's names as declared (`notes.v1.Note.page_count`,
not `pageCount`).

## Imported packages

Each package of the given files is generated whole, from every file
declaring it. A package they only import is not generated, as with any
protoc plugin, and a reference to one of its types is the diagnostic
`generate::not_generated`, naming the ways to add it: `buf generate
--include-imports`, the file on protoc's command line, or the CLI's
`--include-imports`. `google.protobuf` maps to the runtime instead.

Packages that refer to each other in a cycle cannot be generated at all, together or
apart (`generate::import_cycle`), since Elm modules cannot import each
other in a cycle. An application replacing another generator's output
replaces all of a related set together: the modules are named after
their packages (`Users.V1`), so the old module and the new cannot both
be on the source directories: Elm refuses an import two files answer.
`module_prefix` (above) names the new modules apart, for an application
that moves over one related set at a time.

The CLI alone also takes `--include-imports`, named after buf's: it
also generates every imported file that declares a message or enum the
given files' packages refer to, transitively, each imported package
from those files alone (bar `google/protobuf`, which maps to the
runtime). A file imported only for its options, such as
`google/api/annotations.proto` or `google/api/client.proto`, is not
generated. Off by default, so the CLI generates what protoc and buf do
from the same files.

The plugin never generates `google/api/http.proto`,
`google/api/annotations.proto` and `google/api/field_behavior.proto`,
which only carry the options the generator reads (`google.api.http` and
`google.api.field_behavior`), so `buf generate --include-imports` gives
no `Google.Api` module of their types; other files imported for their
options alone, such as `google/api/client.proto`, it generates when buf
asks for them. The CLI's `--include-imports` generates no file nothing
refers to, so none of these. Other `google/api` files, such as
`httpbody.proto`, generate when asked for or referred to.

## Checking generated code: `elm-connect check`

`elm-connect check` takes exactly `gen`'s arguments and options, `-I`
included, since a module's first line names its protos by their paths
under the include directory; and writes nothing: it generates in memory
and compares with the modules under `--out`, for CI to catch generated
code that has drifted from its protos or from the generator. It exits:

- 0 when they are current;
- 1 when a module is missing, differs (shown as a unified diff) or is
  stale;
- 2 when it cannot tell (bad arguments, a proto that does not compile,
  an unreadable directory).

A stale module is an `.elm` file under `--out` whose first line is
elm-connect's `-- Generated by elm-connect` notice naming one of the
same protos, but which generating no longer gives. Files without that
notice are left alone, so handwritten modules can share the directory,
and so are modules another `gen` writes there from other protos. `gen`
deletes nothing; it warns about the stale modules it leaves. When the
modules differ only in the version they name, `check` says which version
generated them instead of printing diffs.

```sh
elm-connect check -I proto notes/v1/notes.proto --out generated --module-prefix Api
```

The protoc plugin cannot check, since protoc writes its files; with
protoc or buf, run `elm-connect check` on the same protos and options,
or regenerate and `git diff --exit-code` the output.

## Running the plugin

protoc finds the plugin on `PATH` by its name, from the
`--elm-connect_out` flag. With the protos under `proto/` and the
googleapis files under `googleapis/`, and the out directory created
first, since protoc does not create it:

```sh
mkdir -p generated
protoc -I proto -I googleapis --elm-connect_out=generated --elm-connect_opt=int64=int notes/v1/notes.proto
```

buf runs it from a `buf.gen.yaml`, with the options under `opt`, one
`key=value` per item:

```yaml
version: v2
plugins:
  - local: protoc-gen-elm-connect
    out: generated
    opt:
      - int64=int
```

[install.md](install.md#googleapis) has the googleapis files either needs
for `google.api.http`, and a complete `buf.yaml` and `buf.gen.yaml`. The
plugin also answers `--version` and `--help` without protoc.

## Diagnostics

A problem in the protos or the options is reported as a diagnostic with
a code, such as `services::unbound_method`, and fails the run. Both
binaries print the code above the message and say where in the proto
the problem is: the CLI quotes the lines with the problem marked, the
plugin gives each place as `file:line:column`. [diagnostics.md](diagnostics.md) lists every code with the
option or edit that gets past it.

The design ([§3](design.md#3-generated-types) for the generated types,
[§4](design.md#4-calls) for calls, [§6](design.md#6-generator) for the
generator) has the reasons behind each form.
