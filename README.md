# elm-connect

[![CI](https://github.com/bruckner/elm-connect/actions/workflows/ci.yml/badge.svg)](https://github.com/bruckner/elm-connect/actions/workflows/ci.yml)
[![crates.io](https://img.shields.io/crates/v/elm-connect)](https://crates.io/crates/elm-connect)
[![MSRV](https://img.shields.io/crates/msrv/elm-connect)](https://crates.io/crates/elm-connect)
[![License](https://img.shields.io/crates/l/elm-connect)](#license)
<!-- The Elm package badge is added when the package reaches the Elm package index, at 1.0. -->

An independent Elm implementation of [ConnectRPC](https://connectrpc.com/)
(client-side only), elm-connect allows Elm apps to call gRPC servers from
the browser.

elm-connect provides idiomatic Elm code generation from `.proto` files:
types, JSON codecs, defaults, descriptors, and type-safe API clients built
from gRPC service definitions. The runtime library allows generated
clients to use the [Connect protocol](https://connectrpc.com/docs/protocol/)
(e.g., to a Connect server or Envoy's Connect-gRPC bridge) or REST through
`google.api.http` gRPC transcoding (e.g., to grpc-gateway, Envoy's 
gRPC-JSON transcoder, or Vanguard).

You define your API with a clear, declarative schema in protobuf, and
elm-connect gives you a complete, faithful, functional, idiomatic, and
type-safe client out-of-the-box.

## Why elm-connect?

The existing Elm protobuf stack, protoc-gen-elm with elm-protocol-buffers
and elm-grpc (last released in 2024), is binary-first: it can generate
proto3 JSON codecs, but its only transport is binary gRPC-Web. An OpenAPI
export of the same protos, fed to an OpenAPI generator, gives a REST
client but loses proto3 JSON's rules and cannot switch to Connect.

What elm-connect adds:

- One generated client, switched between Connect, `google.api.http`
  transcoding and gRPC-Web by the protocol it is sent over
- Generated codecs for proto3 canonical JSON mapping
- The Connect conformance suite and live transcoders in CI, with the
  transcoders' differences published
- A retry policy gated on each method's idempotency
- A CLI that needs no protoc, beside a plugin for protoc and buf
- Pure halves, `Rpc.request` and `Rpc.response`, for tests without a
  server

[docs/compared.md](docs/compared.md) has the details, and a guide for
users of protoc-gen-elm.

## Status

Pre-release, version 0.1.0. The generator and the runtime work: unary
methods over Connect, over `google.api.http` transcoding and over
gRPC-Web, proto3 JSON and, over Connect and gRPC-Web, protobuf binary, Elm 0.19.0 to 0.19.2. The
runtime passes the unary JSON test cases of the official
[Connect conformance suite](https://github.com/connectrpc/conformance)
(v1.0.6), with the features declared in
[`conformance/live/conformance.yaml`](conformance/live/conformance.yaml):
HTTP/1.1, the Connect protocol, the JSON codec, no compression, unary
calls and Connect GET; with the proto codec
([`conformance-proto.yaml`](conformance/live/conformance-proto.yaml))
it passes all but four error-body cases that do not depend on the
codec; over gRPC-Web
([`conformance-grpcweb.yaml`](conformance/live/conformance-grpcweb.yaml))
it passes 79 of 85 cases, the rest listed with their reasons. A live
suite runs every method over Connect against connect-go v2.0.1, over
transcoding against Vanguard v0.5.0 and grpc-gateway v2.32.0, with the
route fixtures under both transcoders, and over gRPC-Web against
connect-go and Envoy's gRPC-Web filter.

Releases before 1.0 carry prebuilt binaries and put the crates on
crates.io; the Elm package reaches the package index at 1.0.
Messages travel as proto3 JSON, or over Connect and gRPC-Web as
protobuf binary with the generator's `codec=both` or `codec=proto`
([docs/calling.md](docs/calling.md#choosing-the-codec)). Streaming is
out of scope for 1.x; [docs/roadmap.md](docs/roadmap.md)
says what may come, and whether it would be a minor or a major
release.

## Install

Each release has prebuilt binaries of the CLI and the protoc plugin for
Linux, macOS and Windows on the
[Releases](https://github.com/bruckner/elm-connect/releases) page, with
checksums and build attestations to verify them. Or build them from
crates.io with Cargo. The CLI:
```sh
cargo install --locked elm-connect
```

The protoc plugin:
```sh
cargo install --locked protoc-gen-elm-connect
```

The CLI, `elm-connect`, needs nothing else. The plugin runs under protoc
or buf. The runtime is an Elm package, published to the package index from
1.0.0; until then, it can be read from a clone's `src/` as a source directory.
[docs/install.md](docs/install.md) has more details including verifying a
download, a complete `elm.json`, googleapis for protoc and buf, and how the
versions line up.

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
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Rpc.Json Notes.V1.GetNoteRequest Notes.V1.Note
ping : () -> Rpc.Call Rpc.Json () ()
```

Each type, call and descriptor carries the proto's comment and its
one-line declaration as its doc, so editor hover and `elm repl` show
what the proto says.

A call goes over either protocol, from the same generated code:

```elm examples/notes/elm/src/Snippets/Sending.elm#sending
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Protocol


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Notes.getNote { name = "notes/42" }
        |> Rpc.send client GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Notes.getNote { name = "notes/42" }
        |> Rpc.send (Rpc.client Rpc.Protocol.transcode "https://api.example.com") GotNote
```

[docs/quickstart.md](docs/quickstart.md) goes on from here: reading the
result, trying calls in `elm repl`, and testing without a server.

## Scope

- Unary methods only. A streaming method is a diagnostic, or is left
  out under `streaming=skip`.
- Calls in proto3 JSON, or over Connect and gRPC-Web in protobuf
  binary, with the codecs the generator writes under `codec=both` or
  `codec=proto` ([docs/generator.md](docs/generator.md#binary-codecs)).
  Transcoding is JSON.
- proto3 only. A proto2 file is the diagnostic `input::not_proto3`, and
  a file that declares an edition is `input::editions`.
- No interceptors: an application sends every call through one
  function of its own, which builds the client
  ([docs/calling.md](docs/calling.md#wrapping-the-sending-once)).

Check out [docs/roadmap.md](docs/roadmap.md) to see what we have planned
as the project grows.

## Documentation

[docs/README.md](docs/README.md) maps every page: getting started,
the reference pages, the specifications, and the design, decisions and
roadmap behind the project. [ARCHITECTURE.md](ARCHITECTURE.md) maps the
code for changing it, and [examples/notes](examples/notes) is a complete
application on a generated client, with a walkthrough.

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
the two options and changes nothing about your choice. `LICENSE` is a
third file holding the MIT text again, because `elm publish` requires a
file of that name; `just check` keeps it equal to `LICENSE-MIT`.

Code the generator writes from your protos is yours: it carries no
license of elm-connect's, and you may use it under any terms.

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
