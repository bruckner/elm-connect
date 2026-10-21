# elm-connect-gen

The library behind
[`protoc-gen-elm-connect`](https://crates.io/crates/protoc-gen-elm-connect)
and the [`elm-connect`](https://crates.io/crates/elm-connect) CLI: it
turns a protobuf descriptor pool into Elm modules for the
[`bruckner/elm-connect`](https://github.com/bruckner/elm-connect) Elm
package, or into diagnostics for what has no Elm form.

It is published so that `cargo install` can build the two binaries. Its
API is not covered by elm-connect's compatibility contract and may change
in any release; to generate Elm, install one of the binaries instead.

The crate embeds three googleapis files, under the Apache License 2.0;
[`googleapis/NOTICE.md`](googleapis/NOTICE.md) says where they come from.

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE)
or [MIT license](LICENSE-MIT) at your option.
