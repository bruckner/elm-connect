# protoc-gen-elm-connect

A protoc and buf plugin that generates Elm clients for protobuf APIs:
one Elm module per proto package, with types, JSON codecs, defaults,
descriptors and a typed call for each unary method, to use with the
[`bruckner/elm-connect`](https://github.com/bruckner/elm-connect) Elm
package, a client-side implementation of Connect, over the Connect
protocol or `google.api.http` transcoding.

```sh
cargo install --locked protoc-gen-elm-connect
protoc -I proto --elm-connect_out=generated proto/notes/v1/notes.proto
```

With buf, name it as a local plugin in `buf.gen.yaml`:

```yaml
version: v2
plugins:
  - local: protoc-gen-elm-connect
    out: generated
```

`protoc-gen-elm-connect --help` lists the options
(`--elm-connect_opt=`, or `opt:` in `buf.gen.yaml`). The
[README](https://github.com/bruckner/elm-connect/blob/main/README.md) covers installing, the options and the Elm
side; [`docs/diagnostics.md`](https://github.com/bruckner/elm-connect/blob/main/docs/diagnostics.md) explains every
diagnostic code. To generate without protoc, use the
[`elm-connect`](https://crates.io/crates/elm-connect) CLI.

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE)
or [MIT license](LICENSE-MIT) at your option.
