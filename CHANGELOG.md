# Changelog

All notable changes to this project are recorded here, one section per
release. The Elm package and the crates share one version and are
released together, under one tag (design §8); each section is also its
GitHub Release's notes. Changes since the last release are collected as
fragments under [`changelog.d/`](changelog.d/README.md) and folded into
a new section when the release is cut.

## Unreleased

The notes for the next release are under
[`changelog.d/`](changelog.d/README.md).

## 0.1.0 — 2026-10-22

The first release, a pre-release: the generator and the runtime as they
stand on the way to 1.0. The release carries prebuilt binaries of
`elm-connect` and `protoc-gen-elm-connect` for Linux (musl), macOS and
Windows on x86-64 and arm64, with a `SHA256SUMS` file and build
provenance attestations; the crates are published to crates.io; the Elm
package `bruckner/elm-connect` reaches the package index at 1.0.0. The
173 notes written change by change while this release was built, in
their final form, are in
[the CHANGELOG at 321ff92](https://github.com/bruckner/elm-connect/blob/321ff92/CHANGELOG.md).

### Generated code

- A module per proto package: a record type alias per message, its
  fields in declaration order; a custom type per enum and per oneof (an
  unset constructor, held in one record field); `Dict` for maps, by key
  kind (`List ( Bool, v )` for a `bool` key); `Maybe` for fields with
  presence and for singular messages, `List` for repeated fields;
  wrapper types that close recursive messages; a `default…` value per
  message; proto3 JSON encoders and decoders per type; descriptors in a
  module per message and enum, and a `registry` per package.
- The well-known types: `Timestamp`, `Duration`, `FieldMask`, `Empty`
  (as `()`), the wrappers, `Struct`, `Value`, `ListValue` and `Any`,
  each with a runtime type or codec.
- A module per service with one function per method, from its request
  to an `Rpc.Call` that carries the method's `google.api.http` bindings
  as data, and a descriptor per method with its idempotency level and
  each field's `google.api.field_behavior`.
- Every module carries the proto's comments as documentation,
  cross-linked and printed in elm-format's form, and names the
  elm-connect release it was generated for (`elmConnectVersion_`), so
  a runtime of another release is a compile error.
- Encoders leave out every field at its default, as protobuf-go's
  `protojson` does. Decoders are strict: integers range-checked (64-bit
  values as canonical decimal text, exact past 2^53), base64 validated,
  a oneof with two set members refused, a field under both its JSON and
  its proto name refused, an unknown enum name failing by default, map
  keys validated by kind, and `__proto__` kept as an ordinary key.
- Proto names become Elm names by stated rules (design §3.7): leading
  capitals and plural acronyms (`IDs` → `ids`), nested enum prefixes,
  reserved words, and file names Windows reserves. What cannot be named
  is a diagnostic with a `rename` escape.

### Options

- `int64=int`: 64-bit integers as `Int`, within ±(2^53 − 1).
- `bytes=bytes`: `bytes` fields as elm/bytes' `Bytes` rather than
  base64 text.
- `enum_unknown=zero`: an unknown enum name reads as the zero value,
  for clients that outlive server deploys.
- `streaming=skip`: streaming methods left out of their service's
  module, each with a warning.
- `unbound_methods=error`: a method without an HTTP rule refused
  rather than sent over the implicit route.
- `rename=<proto full name>:<Elm name>`: any generated name replaced,
  with derived names following.
- `module_prefix=<Module>`: every generated module under a prefix.
- The CLI takes each as a flag (`--int64 int`); the plugin as
  `--elm-connect_opt`.

### Diagnostics

- Every problem has a code in a family (`input::`, `naming::`,
  `types::`, `services::`, `route::`, `options::`), a message in
  elm-connect's words, a site (a snippet from the CLI, `file:line:col`
  from the plugin), a help that names the escape as the front end
  spells it, and a did-you-mean where one fits.
  [`docs/diagnostics.md`](docs/diagnostics.md) lists them all; the
  codes become permanent at 1.0.
- Warnings never fail a run: a skipped streaming method, a module in
  the runtime's namespace or shadowing a core package's, and two
  bindings no router serves together.
- `google.api.http` rules are checked against their messages: the path
  template's grammar, variables, `body`, `response_body`, additional
  bindings, query parameters, literals and verbs a URL can hold, cycles
  and depth.
- Editions files and proto2 are refused, with the escape named; two
  fields whose names agree once lowercased without underscores, which
  protoc accepts, are refused with their sites.

### The runtime: `Rpc`

- `Rpc.call` builds a call from a method and its request; `Rpc.send`,
  `Rpc.task` and their traced forms send it, and `Rpc.request` and
  `Rpc.response` are the pure halves. A config is plain data:
  transport, base URL, headers, timeout, credentials and a retry
  policy; `Rpc.checkConfig` reports its problems where it is built.
- Two transports: Connect (unary, JSON, GET for methods without side
  effects when asked) and HTTP transcoding from the call's
  `google.api.http` binding (path, query, body, custom verb, response
  body), a method without a rule going over the implicit
  `POST /<service>/<method>`.
- Errors are `Rpc.Error`: `RpcStatus`, a status the server stated in a
  Connect body, a `google.rpc.Status` body or `grpc-status` headers,
  with its details as `Proto.Any`; `HttpStatus`; `BadResponse`; and
  `NoAnswer` (timeout, network, bad URL, a header a browser refuses,
  a body over its limit). Every error has a code and a message.
- `Rpc.Retry`: capped, jittered backoff on chosen codes, idempotent
  methods only unless allowed. `Rpc.Trace`: status, headers and
  trailers, duration, attempts and the request, as JSON or one log
  line. `Rpc.Transport.withReadMaxBytes` and `withWriteMaxBytes` bound
  the bodies.
- A base URL holding `?` or `#`, a timeout that is not a positive
  number, a lone surrogate in a path and a long `grpc-message` header
  are each handled where they once threw, overflowed or sent the wrong
  request.
- `Rpc.Config`, `Rpc.Request` and `Rpc.Response` are frozen records;
  `Transport`, `Retry`, `Trace`, `Body`, `Call` and `Error` are opaque
  or in modules of their own, so a release can add to them without a
  major.

### The runtime: `Proto`

- `Proto.Json`: the proto3 JSON codecs, scalars, 64-bit integers as
  text or `Int`, bytes as text or `Bytes`, enums, maps by key kind,
  oneofs, the well-known types and `Any`, with field encoders that
  leave out defaults. `Proto.Timestamp`, `Proto.Duration`,
  `Proto.Int64`, `Proto.Bytes`, `Proto.Any` (pack, unpack, describe
  through a registry) and `Proto.WellKnown`.
- Descriptors: `Proto.Message`, `Proto.Enum`, `Proto.Method`,
  `Proto.Field`, `Proto.EnumValue`, `Proto.Registry` and `Proto.Http`,
  opaque, built by positional functions and read by plain nouns;
  `Proto.Version` holds the release sentinel.
- The package depends on elm/json 1.1.4 or newer, elm/http, elm/time
  and elm/bytes. Decoding a message takes time linear in its fields.

### The CLI and the plugin

- `elm-connect gen` compiles protos itself (`-I`, `--include-imports`,
  the embedded `google/api` files), writes the modules and warns of
  stale ones; `elm-connect check` reports drift between the protos and
  the tree under `--out`, for CI (exit 1 on drift, 2 when it cannot
  tell); `elm-connect guide` prints the user guide; `--help` explains
  each command, with examples.
- `protoc-gen-elm-connect` runs under protoc and buf with the same
  options and diagnostics, and leaves `google/api/http.proto` and
  `annotations.proto` ungenerated under `--include-imports`.

### Verification

- A conformance corpus pins generated modules, diagnostics and
  warnings per case; the generated codecs are tested on sampled values
  written by prost-reflect under every option; property tests check
  the codecs' laws and request building; route fixtures are replayed
  through the runtime against a Rust reference.
- A live suite: an example API ([`examples/notes`](examples/notes))
  served by connect-go with Vanguard, grpc-gateway and Envoy
  transcoding, driven headless from Node over both transports; the
  Connect conformance suite, 40 of 40 unary cases; the transcoders'
  divergences recorded with a reading of who is right.
- CI builds with Elm 0.19.0, 0.19.1 and 0.19.2; the gate runs rustfmt,
  clippy, elm-format, the tests, the documentation's snippets, zizmor,
  gitleaks, cargo deny and cargo package.

### Documentation and project

- The README is the front page; guides under [`docs/`](docs/README.md)
  for installing, a quick start, the generator, calling, descriptors,
  transcoding, Envoy, diagnostics and the specifications; the design
  as a present-tense specification with `decisions.md` and
  `roadmap.md`; [`docs/guide.md`](docs/guide.md) for anyone, agent or
  not, working on a project that uses elm-connect.
- Dual-licensed MIT OR Apache-2.0, the Elm package under MIT, with a
  `LICENSE` file for `elm publish`; generated code is the user's. The
  crates carry crates.io metadata, READMEs, the licenses and the
  googleapis notice; `rust-version` is the pinned toolchain; Dependabot
  proposes grouped updates; `SECURITY.md`, `SUPPORT.md`, a Code of
  Conduct, issue forms and a pull request template; a release workflow
  that builds, attests and publishes behind the maintainer's approval.
