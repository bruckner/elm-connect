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
docs/               design and decisions
mise.toml           toolchain pin
Justfile            task recipes; `just` lists them
```

Both binaries generate record types, their default values and JSON
codecs for messages whose fields are scalars, enums, messages (recursive
ones too) or well-known types, singular, `optional`, repeated or in
maps, and custom types for enums and oneofs, a typed record per message
and enum holding its codecs and descriptor, and a module per service
with a call for every unary method.

The runtime package has two roots, `Proto` for data and `Rpc` for
calling:

| Module | Holds |
|---|---|
| `Proto.Json` | the proto3 JSON helpers generated codecs call |
| `Proto.Timestamp`, `Proto.Duration`, `Proto.Int64` | the well-known types' Elm forms and conversions |
| `Proto.Descriptor` | descriptors as data: messages, enums, methods and their HTTP bindings |
| `Proto.Message`, `Proto.Enum`, `Proto.Method` | typed records: a type's codecs with its descriptor |
| `Proto.WellKnown` | the well-known types' typed records |
| `Proto.Registry` | descriptors by full name |
| `Rpc` | calls, config, sending over Connect or HTTP transcoding, errors |
| `Rpc.Code`, `Rpc.ErrorCode` | the codes an RPC ends with |

## Options

Both binaries take the same options: the protoc plugin as
`--elm-connect_opt=key=value,key=value`, the CLI as flags.

| Option | CLI flag | Values | Effect |
|---|---|---|---|
| `int64` | `--int64` | `string` (default), `int` | How 64-bit integers are held. `string` is exact; `int` gives Elm `Int`s, and a value outside ±(2^53 − 1) fails to decode. A field's `jstype` option (`JS_NUMBER`, `JS_STRING`) overrides it. |
| `unbound_methods` | `--unbound-methods` | `implicit` (default), `error` | What a method without a `google.api.http` rule gets. `implicit`: a call like any other, sent over transcoding on the implicit route (below). `error`: a `services::unbound_method` diagnostic, for servers that serve rules alone. |
| `descriptors` | `--descriptors` | `on` (default), `off` | Whether each message's and enum's descriptor lists its fields and values, and each package module has a `registry`. `off`: the trees are empty and there is no registry, for smaller modules. An application that never reads them pays nothing for them either way: dead-code elimination drops them. |

[`docs/design.md`](docs/design.md) §3.4, §3.9 and §4 have the details.

## Using the generated client

From this proto:

```proto
package notes.v1;

import "google/api/annotations.proto";

service NotesService {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option idempotency_level = NO_SIDE_EFFECTS;
    option (google.api.http) = { get: "/v1/{name=notes/*}" };
  }
  rpc Summarize(SummarizeRequest) returns (Summary);
}
```

the generator writes two modules: `Notes.V1`, the types and their
codecs, and `Notes.V1.NotesService`, one function per method:

```elm
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
summarize : Notes.V1.SummarizeRequest -> Rpc.Call Notes.V1.SummarizeRequest Notes.V1.Summary
```

A call is data: the method, its request, and its HTTP bindings. A
config, also data, says where to send it and how; `Rpc.task` and
`Rpc.send` send a call with a config:

```elm
import Notes.V1.NotesService as Notes
import Rpc


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


-- POST https://api.example.com/notes.v1.NotesService/GetNote
viaConnect : Cmd Msg
viaConnect =
    Rpc.send config (Notes.getNote { name = "notes/42" }) GotNote


-- GET https://api.example.com/v1/notes/42
viaTranscoding : Cmd Msg
viaTranscoding =
    Rpc.send { config | transport = Rpc.Transcode } (Notes.getNote { name = "notes/42" }) GotNote
```

`Rpc.config` is Connect with every call POSTed; set `transport`,
`headers`, `timeout`, `withCredentials` or `retry` with record syntax.
Errors are one type for both transports, `Rpc.Error`: an `Rpc` failure
with an `Rpc.ErrorCode.ErrorCode`, a message, details and where they were read
from, or a `Transport` failure.

### Descriptors

Each message and enum also has a typed record, `Notes.V1.messageNote`
and `Notes.V1.enumVisibility`, holding its codecs and its descriptor:
its full name and its fields (or values) as data. `Notes.V1.registry`
holds the descriptors of the package, of every package it imports and
of the well-known types, by full name:

```elm
import Notes.V1
import Proto.Message
import Proto.Registry


-- "type.googleapis.com/notes.v1.Note"
noteUrl : String
noteUrl =
    Proto.Message.typeUrl Notes.V1.messageNote


-- the proto names of Note's fields, in declaration order
noteFields : List String
noteFields =
    Proto.Registry.message "notes.v1.Note" Notes.V1.registry
        |> Maybe.map (.fields >> List.map .name)
        |> Maybe.withDefault []
```

### Wrapping the sending once

The config holds no functions (no interceptors, no token provider), so
an application sends every call through one function of its own that
builds the config from its state:

```elm
rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call


config : Shared -> Rpc.Config
config shared =
    let
        base =
            Rpc.config shared.apiUrl
    in
    { base | headers = [ ( "Authorization", "Bearer " ++ shared.token ) ] }
```

Since a call is a value, a wrapper can send it again. Refreshing an
expired token and retrying once:

```elm
withRefresh : Task Rpc.Error Shared -> Shared -> Rpc.Call req res -> Task Rpc.Error res
withRefresh refresh shared call =
    rpc shared call
        |> Task.onError
            (\error ->
                case error of
                    Rpc.Rpc { code } ->
                        if code == Rpc.ErrorCode.Unauthenticated then
                            refresh |> Task.andThen (\fresh -> rpc fresh call)

                        else
                            Task.fail error

                    _ ->
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

```elm
signed : Rpc.Config -> Rpc.Call req res -> Task Rpc.Error res
signed cfg call =
    let
        request =
            Rpc.request cfg call
    in
    Rpc.taskFromRequest cfg call
        { request | headers = ( "X-Signature", sign request ) :: request.headers }
```

`Rpc.response` is the other half: it reads an `Http.Response String`
as the call's answer, so both can be tested without a server.

### Methods without an HTTP rule

`Summarize` has no `google.api.http` rule, and is generated like the
rest. Over Connect nothing changes. Over transcoding it is sent on the
implicit route, `POST /notes.v1.NotesService/Summarize` with the request
as its JSON body, which is the request Connect sends. Servers serve
that route as follows:

| Server | Implicit route |
|---|---|
| grpc-gateway | with `generate_unbound_methods=true` |
| Envoy gRPC-JSON transcoder | with `auto_mapping: true` |
| Vanguard | always |
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
