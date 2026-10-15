# elm-connect

Elm clients for protobuf APIs, generated from `.proto` files.

One generator, one runtime, two transports:

- **Connect** — the [Connect protocol](https://connectrpc.com/docs/protocol/)
  over JSON, for servers built with connect-go, connect-es, connect-python,
  or Envoy's Connect filter.
- **Transcode** — REST over JSON driven by `google.api.http` annotations,
  for servers behind grpc-gateway or Envoy's gRPC-JSON transcoder.

Generated code is transport-neutral: types, JSON codecs, and one function
per method that turns a request into a call. A call is data, and so is the
config that says which transport to send it over.

## Status

Design. Nothing to install yet. The design is being worked out in the open
in [`docs/design.md`](docs/design.md); iteration happens in pull requests
against that document before any generator code lands.

The generator grew out of an in-house Elixir protoc plugin that has been
serving a production Elm client since early 2026. This repository is the
portable, public rewrite: the generator in Rust, the runtime as an Elm
package.

## Layout

```
Cargo.toml          Rust workspace
crates/
  elm-connect-gen/        the shared library: IR, emitter, Elm printer
  protoc-gen-elm-connect/ the protoc plugin
  elm-connect/            standalone CLI (no protoc needed)
elm.json, src/, tests/    the Elm runtime package and its tests
conformance/
  cases/            proto inputs and the Elm expected from them
  harness/          Elm application the expected output compiles in
  routes/           route fixtures: the HTTP request a call becomes
  live/             the runtime run against a live server (`just live`)
examples/notes/     an example API, its Go server, and a browser app on its generated client
docs/               design and decisions
mise.toml           toolchain pin
Justfile            task recipes; `just` lists them
```

Both binaries generate record types, their default values and JSON
codecs for messages whose fields are scalars, enums, messages (recursive
ones too) or well-known types, singular, `optional`, repeated or in
maps, and custom types for enums and oneofs, a typed record per message
and enum holding its codecs and descriptor, and a module per service
with a call for every unary method. Each package of the given files is
generated whole, from every file declaring it; a package they only
import is not generated, as with any protoc plugin, and a reference to
it is an error naming the ways to add it (`buf generate
--include-imports`, the file on protoc's command line, or the CLI's
`--include-imports`). `google.protobuf` maps to the runtime instead, and
`google/api/http.proto` and `google/api/annotations.proto`, which only
carry `google.api.http`, are never generated, so `buf generate
--include-imports` gives no `Google.Api` module of their messages. Other
`google/api` files, such as `httpbody.proto`, generate when asked for.

The runtime package has two roots, `Proto` for data and `Rpc` for
calling:

| Module | Holds |
|---|---|
| `Proto.Json` | the proto3 JSON helpers generated codecs call |
| `Proto.Timestamp`, `Proto.Duration`, `Proto.Int64` | the well-known types' Elm forms and conversions |
| `Proto.Descriptor` | descriptors as data: messages, enums and methods |
| `Proto.Http` | a method's `google.api.http` rule as data |
| `Proto.Message`, `Proto.Enum` | typed records: a type's codecs with its descriptor |
| `Proto.Method` | a method's request encoder, response decoder and descriptor |
| `Proto.WellKnown` | the well-known types' typed records |
| `Proto.Registry` | descriptors by full name |
| `Proto.Any` | `google.protobuf.Any`: packing, unpacking and describing |
| `Rpc` | calls, config, sending over Connect or HTTP transcoding, errors |
| `Rpc.Code`, `Rpc.ErrorCode` | the codes an RPC ends with |

## Options

Both binaries take the same options: the protoc plugin as
`--elm-connect_opt=key=value,key=value`, the CLI as flags.

| Option | CLI flag | Values | Effect |
|---|---|---|---|
| `int64` | `--int64` | `string` (default), `int` | How 64-bit integers are held. `string` is exact; `int` gives Elm `Int`s, and a value outside ±(2^53 − 1) fails to decode. A field's `jstype` option (`JS_NUMBER`, `JS_STRING`) overrides it. |
| `unbound_methods` | `--unbound-methods` | `implicit` (default), `error` | What a method without a `google.api.http` rule gets. `implicit`: a call like any other, sent over transcoding on the implicit route (below). `error`: a `services::unbound_method` diagnostic, for servers that serve rules alone. |
| `streaming` | `--streaming` | `error` (default), `skip` | What a client, server or bidirectional streaming method gets. `error`: a `services::streaming` diagnostic. `skip`: left out of its service's module, with a warning on stderr, and the rest generated. |
| `enum_unknown` | `--enum-unknown` | `fail` (default), `zero` | What an enum value name the client does not know reads as; an unknown number reads as the zero value either way. `fail`: the decode fails, as protobuf's own parsers do. `zero`: the zero value, so a value the server adds after the client was generated does not fail the message it is in, at the cost of telling it apart from the zero value. |
| `rename` | `--rename` | `<proto full name>:<Elm name>`, repeatable | An Elm name in place of the one the naming rules derive, for a package (its module), service, method, message, enum, field, oneof or enum value. The escape for names that collide or have no Elm form. |

For example, to give `notes.v1.Note` the Elm type `Memo` and its field
`title` the record field `heading`:

```sh
protoc --elm-connect_out=generated \
  --elm-connect_opt=rename=notes.v1.Note:Memo,rename=notes.v1.Note.title:heading \
  notes.proto
elm-connect gen notes.proto --out generated \
  --rename notes.v1.Note:Memo --rename notes.v1.Note.title:heading
```

The CLI alone also takes `--include-imports`, named after buf's: it
generates the packages of every file the given ones import,
transitively, as well (bar `google/protobuf` and files declaring
nothing). Off by default, so the CLI generates what protoc and buf do
from the same files.

[`docs/design.md`](docs/design.md) §3.1, §3.4, §3.7, §3.8, §3.9, §4 and §6 have the details.

## Using the generated client

From this proto:

```proto examples/notes/proto/notes/v1/notes.proto excerpt
package notes.v1;

import "google/api/annotations.proto";

service NotesService {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option idempotency_level = NO_SIDE_EFFECTS;
    option (google.api.http) = {get: "/v1/{name=notes/*}"};
  }
  rpc Ping(google.protobuf.Empty) returns (google.protobuf.Empty) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}
```

the generator writes two modules: `Notes.V1`, the types and their
codecs, and `Notes.V1.NotesService`, one function per method:

```elm examples/notes/elm/generated/Notes/V1/NotesService.elm excerpt
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
ping : () -> Rpc.Call () ()
```

A call is data: the method, its request, and its HTTP bindings. A
config, also data, says where to send it and how; `Rpc.task` and
`Rpc.send` send a call with a config:

```elm examples/notes/elm/src/Snippets/Sending.elm#sending
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Rpc.send config (Notes.getNote { name = "notes/42" }) GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Rpc.send { config | transport = Rpc.Transcode } (Notes.getNote { name = "notes/42" }) GotNote
```

`Rpc.config` is Connect with every call POSTed; set `transport`,
`headers`, `timeout`, `withCredentials` or `retry` with record syntax.
Errors are one type for both transports, `Rpc.Error`: a `Status` the
server stated (an `Rpc.ErrorCode.ErrorCode`, a message, details and
where they were read from), an `Http` answer that stated none, a
`Transport` failure with no answer, or `Canceled`, a call the
application withdrew with `Rpc.cancel`. Every error has a code and a
message, `Rpc.code error` and `Rpc.message error`, a timeout reading as
`DeadlineExceeded`; the `Status` and `Http` errors keep the answer
itself (status, headers and body) for errors in a shape the runtime
does not read.

### Descriptors

Each message and enum also has a typed record, `Notes.V1.messageNote`
and `Notes.V1.enumVisibility`, holding its codecs and its descriptor:
its full name and its fields (or values) as data. `Notes.V1.registry`
holds the descriptors of the package, of every package it imports and
of the well-known types, by full name:

```elm examples/notes/elm/src/Snippets/Descriptors.elm#descriptors
import Notes.V1
import Proto.Message
import Proto.Registry


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.messageNote


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Registry.message "notes.v1.Note" Notes.V1.registry
        |> Maybe.map (.fields >> List.map .name)
        |> Maybe.withDefault []
```

### Any

`Proto.Any` packs a message into a `google.protobuf.Any` with its typed
record, and unpacks one the same way: `Nothing` when it holds another
type, `Just (Err problem)` when it holds this type but cannot be read.

```elm examples/notes/elm/src/Snippets/Any.elm#any
import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.pack Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any -> Maybe String
title any =
    case Proto.Any.unpack Notes.V1.messageNote any of
        Just (Ok note) ->
            Just note.title

        _ ->
            Nothing
```

An error's details are `Any`s, and `Rpc.details` gives those of one
type, here `google.rpc.BadRequest` from a package generated from
`google/rpc/error_details.proto` (the notes example generates it with buf
from googleapis):

```elm examples/notes/elm/src/Snippets/Details.elm#details
import Google.Rpc
import Rpc


violations : Rpc.Error -> List String
violations error =
    Rpc.details Google.Rpc.messageBadRequest error
        |> List.concatMap .fieldViolations
        |> List.map .description
```

A Connect server sends each detail as protobuf binary, with its JSON
beside it as `debug` when it chooses to; a detail without `debug` keeps
its type but does not unpack (`Proto.Any.BinaryOnly`).

### Wrapping the sending once

The config holds no functions (no interceptors, no token provider), so
an application sends every call through one function of its own that
builds the config from its state:

```elm examples/notes/elm/src/Api.elm#wrapper
rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call


config : Shared -> Rpc.Config
config shared =
    let
        base =
            Rpc.config shared.apiUrl
    in
    { base
        | transport = shared.transport
        , headers = [ ( "Authorization", "Bearer " ++ shared.token ) ]
    }
```

Since a call is a value, a wrapper can send it again. Refreshing an
expired token and retrying once:

```elm examples/notes/elm/src/Snippets/Refresh.elm#refresh
withRefresh : Task Rpc.Error Shared -> Shared -> Rpc.Call req res -> Task Rpc.Error res
withRefresh refresh shared call =
    rpc shared call
        |> Task.onError
            (\error ->
                if Rpc.code error == Rpc.ErrorCode.Unauthenticated then
                    refresh |> Task.andThen (\fresh -> rpc fresh call)

                else
                    Task.fail error
            )
```

Several calls failing at once would each refresh; an application that
cares keeps the refresh single-flight in its update. For retrying on
codes such as `Unavailable`, the config's `retry` policy needs no
wrapper.

### Rewriting a request

`Rpc.request` gives the HTTP request a call stands for, and
`Rpc.taskFromRequest` sends a request in its place and reads the answer
as the call's, so anything the config cannot say is a function between
the two:

```elm examples/notes/elm/src/Snippets/Signed.elm#signed
signed : Rpc.Config -> Rpc.Call req res -> Task Rpc.Error res
signed cfg call =
    let
        request =
            Rpc.request cfg call
    in
    { request | headers = ( "X-Signature", sign request ) :: request.headers }
        |> Rpc.taskFromRequest cfg call
```

`Rpc.response` is the other half: it reads an `Http.Response String`
as the call's answer, so both can be tested without a server.

### Methods without an HTTP rule

`Ping` has no `google.api.http` rule, and is generated like the
rest. Over Connect nothing changes. Over transcoding it is sent on the
implicit route, `POST /notes.v1.NotesService/Ping` with the request
as its JSON body, which is the request Connect sends. Servers serve
that route as follows:

| Server | Implicit route |
|---|---|
| grpc-gateway | with `generate_unbound_methods=true` |
| Envoy gRPC-JSON transcoder | with `auto_mapping: true` |
| Vanguard | always (v0.5 serves rules only; the Connect handler mounted beside it serves the route) |
| A Connect handler (connect-go, connect-es, …) | always: it is the Connect request |

For a server that serves rules alone, generate with
`unbound_methods=error`, and a method without a rule is a diagnostic
rather than a call that fails at run time.

## Developing

```sh
mise install    # Rust, Elm, elm-format, elm-test-rs, node, just
just check      # the gate CI runs
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow.

**Live verification.** `just live` runs the runtime, compiled into a
headless Elm program and driven from Node, against
[`examples/notes`](examples/notes): a Go server answering over Connect
(connect-go) and HTTP transcoding (Vanguard) from one port. Every
method over both transports, errors with details, timeouts, retries and
Connect GET and cancellation are covered; [`conformance/README.md`](conformance/README.md)
has the case format, and CI runs it on every pull request.
`just live` also runs the official
[Connect conformance suite](https://github.com/connectrpc/conformance)'s
unary JSON test cases (v1.0.6) against the runtime: all 40 pass.

**The example.** [`examples/notes`](examples/notes) is also a browser
application over either transport, with a walkthrough; `just
example-notes` serves it. The Elm blocks above are excerpts of it, and
`just check` fails when one drifts from its file.

## License

Dual-licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option. The Elm package is published to the package index under
MIT, since `elm.json` carries a single license identifier; that is one of
the two options and changes nothing about your choice.

The generator embeds two files from googleapis, under the Apache License
2.0; see [THIRD_PARTY.md](THIRD_PARTY.md).

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual-licensed as
above, without any additional terms or conditions.
