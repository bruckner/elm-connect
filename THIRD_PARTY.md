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
its own copyright and license header.

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
