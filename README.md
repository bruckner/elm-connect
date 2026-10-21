# elm-connect

elm-connect generates an Elm client from `.proto` files and calls the API
over JSON: with the [Connect protocol](https://connectrpc.com/docs/protocol/)
(connect-go, connect-es, connect-python, or Envoy's Connect-gRPC bridge
in front of a gRPC server), or as REST through `google.api.http` rules
(grpc-gateway, Envoy's gRPC-JSON transcoder, Vanguard). The generated
code is the same for both; the transport is a field of the config a call
is sent with. A call is data, and so is the config, so what a call sends
and how it reads the answer can be checked without a server.

## Status

Pre-release, version 0.1.0. The generator and the runtime work: unary
methods over Connect and over `google.api.http` transcoding, proto3
JSON, Elm 0.19.0 to 0.19.2. The runtime passes the unary JSON test cases
of the official [Connect conformance suite](https://github.com/connectrpc/conformance)
(v1.0.6), with the features declared in
[`conformance/live/conformance.yaml`](conformance/live/conformance.yaml):
HTTP/1.1, the Connect protocol, the JSON codec, no compression, unary
calls and Connect GET. A live suite runs every method over Connect
against connect-go v2.0.1 and over transcoding against Vanguard v0.5.0
and grpc-gateway v2.32.0, with the route fixtures under both
transcoders.

Nothing is on crates.io or the Elm package index yet; 1.0 is the next
release. Streaming, binary protobuf and gRPC-Web are out of scope for
1.x; [docs/roadmap.md](docs/roadmap.md) says what may come, and whether
it would be a minor or a major release.

## Install

```sh
cargo install --locked --git https://github.com/bruckner/elm-connect elm-connect
cargo install --locked --git https://github.com/bruckner/elm-connect protoc-gen-elm-connect
```

The CLI, `elm-connect`, needs nothing else; the plugin runs under protoc
or buf. The runtime is an Elm package, read from a clone's `src/` as a
source directory until it is published (`elm install
bruckner/elm-connect` then). [docs/install.md](docs/install.md) has a
complete `elm.json`, googleapis for protoc and buf, and how the versions
line up.

## Quick start

From this proto:

```proto examples/notes/proto/notes/v1/notes.proto excerpt
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

`elm-connect gen -I proto notes/v1/notes.proto --out generated` writes
`Notes.V1`, the types and their JSON codecs, and `Notes.V1.NotesService`,
one function per method:

```elm examples/notes/elm/generated/Notes/V1/NotesService.elm excerpt
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
ping : () -> Rpc.Call () ()
```

A call goes over either transport, from the same generated code:

```elm examples/notes/elm/src/Snippets/Sending.elm#sending
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Transport


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Notes.getNote { name = "notes/42" }
        |> Rpc.send config GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Notes.getNote { name = "notes/42" }
        |> Rpc.send { config | transport = Rpc.Transport.transcode } GotNote
```

[docs/quickstart.md](docs/quickstart.md) goes on from here: reading the
result, trying calls in `elm repl`, and testing without a server.

## Scope

- Unary methods only. A streaming method is a diagnostic, or is left
  out under `streaming=skip`.
- JSON only: proto3 JSON, no binary protobuf.
- proto3 only. A proto2 file is the diagnostic `input::not_proto3`, and
  a file that declares an edition is `input::editions`.
- No streaming, no gRPC-Web.
- No interceptors: the config is data, so an application sends every
  call through one function of its own
  ([docs/calling.md](docs/calling.md#wrapping-the-sending-once)).

## Compared with

The existing Elm protobuf stack, protoc-gen-elm with elm-protocol-buffers
and elm-grpc (last released in 2024), is binary-first: it can generate
proto3 JSON codecs, but its only transport is binary gRPC-Web. An OpenAPI
export of the same protos, fed to an OpenAPI generator, gives a REST
client but loses proto3 JSON's rules (64-bit integers as exact strings,
enums by name or number, the well-known types' forms, oneofs, `Any`,
status details) and cannot switch to Connect. What elm-connect adds:

- one generated client, switched between Connect and `google.api.http`
  transcoding in its config;
- a CLI that needs no protoc, beside a plugin for protoc and buf;
- the Connect conformance suite and live transcoders in CI, with the
  transcoders' differences published;
- a retry policy gated on each method's idempotency;
- pure halves, `Rpc.request` and `Rpc.response`, for tests without a
  server.

[docs/compared.md](docs/compared.md) has the details, and a guide for
users of protoc-gen-elm.

## Documentation

- [docs/install.md](docs/install.md): the binaries, the runtime in
  `elm.json`, googleapis, versions.
- [docs/quickstart.md](docs/quickstart.md): from a proto to a call, in
  `elm repl` and in a test.
- [docs/generator.md](docs/generator.md): what a proto becomes in Elm,
  the options, `check`, and running the plugin.
- [docs/calling.md](docs/calling.md): configs, transports, retries,
  errors, tracing, cancelling, and the pure halves.
- [docs/descriptors.md](docs/descriptors.md): descriptors, the registry,
  `Any`, error details and update masks.
- [docs/transcoding.md](docs/transcoding.md): `google.api.http` in
  practice, server options, and where transcoders differ.
- [docs/compared.md](docs/compared.md): the other Elm tools and the
  OpenAPI route.
- [docs/diagnostics.md](docs/diagnostics.md): every diagnostic code, and
  what gets past it.
- [docs/design.md](docs/design.md): the design, with its reasons.
- [examples/notes](examples/notes): an API, its Go server, and a browser
  application on its generated client, with a walkthrough.

## Developing

```sh
mise install    # the toolchain: Rust, Elm, elm-format, elm-test-rs, node, Go, buf, just, …
just check      # the gate CI runs
just live       # the runtime against the example server, and the Connect conformance suite
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the workflow, and
[`conformance/README.md`](conformance/README.md) the test layers.

## License

Dual-licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option. The Elm package is published to the package index under
MIT, since `elm.json` carries a single license identifier; that is one of
the two options and changes nothing about your choice.

The generator embeds files from googleapis, under the Apache License
2.0, and ports elm-format's Markdown parser and printer, under the BSD
3-Clause License; see [THIRD_PARTY.md](THIRD_PARTY.md).

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual-licensed as
above, without any additional terms or conditions.

### Trademarks

elm-connect is an independent project. It is not affiliated with, sponsored
by or endorsed by the Connect project, the Cloud Native Computing Foundation
or The Linux Foundation. Connect RPC™ is a trademark of The Linux Foundation;
the name elm-connect says which protocol the generated clients speak.
