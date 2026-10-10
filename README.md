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

## Layout (planned)

```
elm.json            the Elm runtime package  (bruckner/elm-connect)
src/                Connect.elm, Transcode.elm, and internals
tests/
Cargo.toml          Rust workspace
crates/
  elm-connect-gen/        descriptors → IR → Elm, with diagnostics
  protoc-gen-elm-connect/ the protoc plugin
  elm-connect/            standalone CLI (no protoc needed)
conformance/        .proto fixtures and golden Elm output
docs/               design and decisions
```

## License

MIT. See [LICENSE](LICENSE).
