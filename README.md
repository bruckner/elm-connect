# elm-connect

Elm clients for protobuf APIs, generated from `.proto` files.

One generator, one runtime, two transports:

- **Connect** — the [Connect protocol](https://connectrpc.com/docs/protocol/)
  over JSON, for servers built with connect-go, connect-es, connect-python,
  or Envoy's Connect filter.
- **Transcode** — REST over JSON driven by `google.api.http` annotations,
  for servers behind grpc-gateway or Envoy's gRPC-JSON transcoder.

Generated code is transport-neutral: types, JSON codecs, and per-method
descriptors. Which transport a method can be called over is a type, not a
runtime surprise.

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

Both binaries generate record types and JSON codecs for messages whose
fields are scalars, enums, messages or well-known types, singular,
`optional`, repeated or in maps, and custom types for enums and oneofs;
recursive messages are reported as not generated yet. The runtime package
holds the JSON helpers those codecs call and the timestamp and duration
types.

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

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual-licensed as
above, without any additional terms or conditions.
