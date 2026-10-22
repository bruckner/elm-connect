# elm-connect

The `elm-connect` command generates Elm clients for protobuf APIs
straight from `.proto` files, without protoc: one Elm module per proto
package, with types, JSON codecs, defaults, descriptors and a typed call
for each unary method, to use with the
[`bruckner/elm-connect`](https://github.com/bruckner/elm-connect) Elm
package, a client-side implementation of Connect, over the Connect
protocol or `google.api.http` transcoding.

```sh
cargo install --locked elm-connect
elm-connect gen -I proto -o generated notes/v1/notes.proto
elm-connect check -I proto -o generated notes/v1/notes.proto
```

`elm-connect --help` says where to start and lists the options, and
`elm-connect guide` prints the guide to working on a project with it. The
[README](https://github.com/bruckner/elm-connect/blob/main/README.md) covers installing, the options and the Elm
side; [`docs/diagnostics.md`](https://github.com/bruckner/elm-connect/blob/main/docs/diagnostics.md) explains every
diagnostic code. For protoc and buf, the same generator ships as
[`protoc-gen-elm-connect`](https://crates.io/crates/protoc-gen-elm-connect).

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE)
or [MIT license](LICENSE-MIT) at your option.
