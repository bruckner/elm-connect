# Third-party material

## googleapis

`crates/elm-connect-gen/googleapis/google/api/http.proto`,
`crates/elm-connect-gen/googleapis/google/api/annotations.proto` and
`crates/elm-connect-gen/googleapis/google/api/field_behavior.proto` are
copied unmodified from [googleapis](https://github.com/googleapis/googleapis)
at commit `525d4c82dc1dd2fa3884198a8006a7bf5b48ac9d`. The generator
embeds them so that protos importing `google/api/annotations.proto` or
`google/api/field_behavior.proto` compile without a googleapis checkout
(`docs/design.md` §3.9, §4).

They are Copyright Google LLC and licensed under the Apache License,
Version 2.0; a copy of the license is in [LICENSE-APACHE](LICENSE-APACHE)
and at <http://www.apache.org/licenses/LICENSE-2.0>. Each file carries
its own copyright and license header. The crate ships this notice beside
them, in
[`crates/elm-connect-gen/googleapis/NOTICE.md`](crates/elm-connect-gen/googleapis/NOTICE.md),
and its own copy of the license.

The notes example vendors three googleapis files,
`examples/notes/third_party/googleapis/google/api/annotations.proto`,
`google/api/http.proto` and `google/rpc/error_details.proto`, exported
unmodified from the Buf Schema Registry's `buf.build/googleapis/googleapis`
module (its README.md names the commit). They are Copyright Google LLC and
licensed under the Apache License, Version 2.0; the module's license is
beside them in `examples/notes/third_party/googleapis/LICENSE`.

## Connect conformance suite

`conformance/live/suite/elm/` and `conformance/live/suite/js/` are
generated (by protoc-gen-elm-connect and protoc-gen-es) from the
`connectrpc.conformance.v1` protos of the
[Connect conformance suite](https://github.com/connectrpc/conformance),
v1.0.6, which are Copyright The Connect Authors and licensed under the
Apache License, Version 2.0; a copy of the license is in
[LICENSE-APACHE](LICENSE-APACHE). The generated JavaScript keeps the
protos' license header.

The protos themselves are vendored, unmodified, in
`conformance/live/suite/proto/`, exported from the Buf Schema Registry's
`buf.build/connectrpc/conformance` module at the commit labelled v1.0.6
(its README.md names it), with the module's license in
`conformance/live/suite/proto/LICENSE`.

## Protocol Buffers test messages

`conformance/protobuf/proto/google/protobuf/test_messages_proto3.proto`
is [protobuf](https://github.com/protocolbuffers/protobuf)'s
`src/google/protobuf/test_messages_proto3.proto` at v32.0, modified by
`conformance/protobuf/strip-null-value.sh`, which removes its two
`google.protobuf.NullValue` fields (`conformance/protobuf/README.md`). It
is Copyright 2008 Google Inc. and licensed under the BSD 3-Clause License,
as its header says; protobuf's `LICENSE` at v32.0 is beside it, in
`conformance/protobuf/proto/LICENSE`. The Elm
in `conformance/protobuf/generated/` is generated from it and keeps its
comments. The conformance suite's runner, `conformance_test_runner`, is
fetched at run time and not kept in the repository.

## Eliza

`examples/eliza/proto/connectrpc/eliza/v1/eliza.proto` is copied
unmodified from [connectrpc/examples-go](https://github.com/connectrpc/examples-go)
(commit `8bde2b90ec0a7f23df3de5824bed0b6ea2043305`, the same file as the
Buf Schema Registry's `buf.build/connectrpc/eliza` at commit
`233fca715f49425581ec0a1b660be886`). It is Copyright The Connect Authors
and licensed under the Apache License, Version 2.0, as its header says; a
copy of the license is in [LICENSE-APACHE](LICENSE-APACHE). The Elm in
`examples/eliza/generated/` is generated from it and keeps its comments.

## elm-format's Markdown parser and printer

`crates/elm-connect-gen/src/elm/markdown.rs` ports two parts of
[elm-format](https://github.com/avh4/elm-format) 0.8.8 to Rust so that
generated doc comments are already in the form `elm-format` prints
(`docs/design.md` §3.1): the Markdown parser it vendors as
`elm-format-markdown` (a fork of John MacFarlane's Cheapskate) and its
Markdown printer, `ElmFormat.Render.Markdown`. The port departs from them
where elm-format would lose or rewrite text; the file's doc comment lists
each departure.

The parser is Copyright (c) 2013 John MacFarlane and Copyright (c) 2017
Aaron VonderHaar; the printer is Copyright (c) 2015-2023 Aaron VonderHaar
and the elm-format contributors. Both are licensed under the BSD 3-Clause
License; copies are in
[`crates/elm-connect-gen/third_party/elm-format/`](crates/elm-connect-gen/third_party/elm-format/),
which ships inside the `elm-connect-gen` crate.
