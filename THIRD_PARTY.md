# Third-party material

## googleapis

`crates/elm-connect-gen/googleapis/google/api/http.proto` and
`crates/elm-connect-gen/googleapis/google/api/annotations.proto` are
copied unmodified from [googleapis](https://github.com/googleapis/googleapis)
at commit `525d4c82dc1dd2fa3884198a8006a7bf5b48ac9d`. The generator
embeds them so that protos importing `google/api/annotations.proto`
compile without a googleapis checkout (`docs/design.md` §4).

They are Copyright Google LLC and licensed under the Apache License,
Version 2.0; a copy of the license is in [LICENSE-APACHE](LICENSE-APACHE)
and at <http://www.apache.org/licenses/LICENSE-2.0>. Each file carries
its own copyright and license header.
