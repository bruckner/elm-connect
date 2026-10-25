# elm-connect documentation

elm-connect is an independent Elm implementation of ConnectRPC,
client-side only: a generator that turns `.proto` files into idiomatic
Elm (types, JSON codecs, defaults, descriptors and a typed client per
service), and a runtime that sends the calls over the Connect protocol
or through `google.api.http` transcoding. Start with
[install.md](install.md) and [quickstart.md](quickstart.md), and keep
[guide.md](guide.md) at hand while working on a project that uses it.
The rest are reference pages, for when a question comes up.

## Getting started

- [install.md](install.md): the binaries, the runtime in `elm.json`,
  googleapis, versions.
- [quickstart.md](quickstart.md): from a proto to a call, in `elm repl`
  and in a test.
- [trying.md](trying.md): a real call with no server of your own,
  against ConnectRPC's public demo server.
- [guide.md](guide.md): working on a project that uses elm-connect:
  regenerating, `check`, reading a diagnostic, the application's
  `elm.json`. `elm-connect guide` prints it.

## Reference

- [generator.md](generator.md): what a proto becomes in Elm, the
  options, `check`, and running the plugin.
- [calling.md](calling.md): configs, transports, retries, errors,
  tracing, cancelling, and the pure halves.
- [descriptors.md](descriptors.md): descriptors, the registry, `Any`,
  error details and update masks.
- [transcoding.md](transcoding.md): `google.api.http` in practice,
  server options, and where transcoders differ.
- [envoy.md](envoy.md): the notes example behind Envoy's gRPC-JSON
  transcoder, run with func-e and tested live.
- [diagnostics.md](diagnostics.md): every diagnostic code, and what
  gets past it.
- [compared.md](compared.md): the other Elm tools and the OpenAPI
  route.
- [specs.md](specs.md): the specifications elm-connect implements, with
  links and where each meets the code.

## The project

- [design.md](design.md): the design, with its reasons; the contract
  the code is held to.
- [decisions.md](decisions.md): what was decided, when, and what the
  alternative was.
- [roadmap.md](roadmap.md): what 1.0 leaves out and what may come after
  it.
- [CHANGELOG.md](../CHANGELOG.md): every release's notes; what is not
  yet released is under [changelog.d/](../changelog.d/README.md).
- [ARCHITECTURE.md](../ARCHITECTURE.md), [CONTRIBUTING.md](../CONTRIBUTING.md)
  and [AGENTS.md](../AGENTS.md): the code's shape, the contributor's
  workflow and the working agreement, for changing elm-connect itself.
- [examples/notes](../examples/notes): an API, its Go server, and a
  browser application on its generated client, with a walkthrough.
