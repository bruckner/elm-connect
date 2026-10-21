# Roadmap

What may come after 1.0. Each entry says what it is, what it needs,
and whether it would ship in a minor release or need a major one,
under the compatibility rules of [design §8](design.md): within a
major, generated code compiles against every later runtime of that
major, the runtime's API only grows, and the same protos with the same
options generate the same modules, types and values. The page promises
no dates and no order. An entry is a direction, not a commitment; the
reasons behind the settled questions are in
[decisions.md](decisions.md).

## Server streaming

A method that returns a stream of messages. elm/http hands a program
the whole response at once, so a stream has to be read in JavaScript
and passed to Elm through a port: a new `Rpc.Stream` module and a
streaming method type beside `Proto.Method.Method` on the Elm side, and
a small vanilla-JS companion an Elm package cannot ship, published on
npm or copied into the application. Errors at the end of a stream map
onto the existing `Rpc.Error` kinds. A minor: today the generator
refuses a streaming method (`services::streaming`), or leaves it out
under `streaming=skip`, so nothing generated now would change.

Over transcoding the same mechanism reads three framings: grpc-gateway
streams newline-delimited JSON, a `{"result": …}` object per message
and an `{"error": …}` object for a failure, and Envoy's transcoder a
JSON array by default, newline-delimited JSON with
`stream_newline_delimited`, or server-sent events with
`stream_sse_style_delimited`. Which one a server uses is a setting on
`Rpc.Transport`, so it is a minor too, and it comes with server
streaming over Connect, not before.

## Binary protobuf

`application/proto` bodies instead of JSON. It needs binary codecs
written over elm/bytes, generated beside the JSON ones only when an
option asks for them, so the default output is unchanged; a way to
attach them to the opaque `Proto.Message.Message` and
`Proto.Method.Method` values; a bytes kind of `Rpc.Body`; and a codec
setting on `Rpc.Transport`. A minor. The codecs would not reuse
elm-protocol-buffers' types, so that another package's major never
forces one here.

## gRPC-Web, unary

The protocol elm-grpc speaks, for servers that serve gRPC-Web and not
Connect. It is a setting on `Rpc.Transport` over the binary codec,
plus reading gRPC-Web's frames and trailers out of a whole response
body. A minor, after binary protobuf.

## Editions and proto2

Today a proto2 file is `input::not_proto3` and a file that declares an
edition is `input::editions`. Accepting them turns an error into
output, so it is a minor: the descriptors already reserve
`CardinalityRequired` for `required` fields, and closed enums,
non-zero defaults and explicit presence become descriptor modifiers
and generated decoders. Groups and extensions would stay refused.

## Options in the proto

An `elm_connect/options.proto` of custom options, read from the
descriptors like `google.api.http`: renames written beside the
elements they rename, and the choice for unrecognised enum values (the
next entry) set per enum. It needs extension numbers from protobuf's
global registry. The option names and numbers freeze the day they
ship, since users' protos cite them, and which of a proto option and a
`rename` wins is decided then; `rename` keys stay full proto names so
that the two can live together. A minor: output changes only where a
proto uses them.

## Unrecognised enum values, as an option

Today an unknown enum number decodes to the zero value, and an unknown
name fails or, under `enum_unknown=zero`, decodes to the zero value
too. An option would give each enum a constructor holding the number
it did not recognise, `<Enum>Unrecognized Int`, which re-encodes what
was received. It is an option and never the default: as the default it
would add a branch to every `case` on every enum in every application.
A minor (a new option value); per enum through the proto options above.

## Well-known `Google.*` modules and `NullValue`

Today an application generates the `google.rpc` error details and any
other googleapis types it uses itself, from googleapis files, and a
field of the enum `google.protobuf.NullValue` is
`types::unsupported_well_known`. Prebuilt modules for the common
googleapis packages, and a mapping for `NullValue`, are additions: a
minor.

## Leaving comments out

Generated documentation carries each element's proto comment. An
option, `comments=off`, would leave the comments out and keep the
declaration lines, for an API whose comments are internal. A minor
(a new option).

## Emitting the runtime

An option for the generator to write the runtime's own modules
(`Proto.*`, `Rpc`, `Rpc.*`) beside the generated code, from a copy
embedded in the binary, so vendoring the runtime is one flag and its
version always matches the generated code. It needs `check` to treat
the emitted runtime as generated, and a way for an application to drop
the copy when it installs the package. A minor.

## Hooks: `Rpc.Client`

`Rpc.Config` holds no functions, so it stays comparable and safe in a
model, and every use of an interceptor maps onto data, the trace or
the pure halves ([calling.md](calling.md)). If hooks turn out to be
needed anyway, an opaque `Rpc.Client`, built from a `Config` plus
hooks and sent through functions of its own, can be added beside
`Rpc.task` without changing it. A minor.

## A fake transport for tests

Today a program's calls are tested through the pure halves:
`Rpc.request` shows what a call would send and `Rpc.response` reads an
answer, with no server. A transport that answers from data the test
supplies would let `Rpc.task` and `Rpc.send` themselves run in a test.
A minor: `Rpc.Transport` is opaque, so a transport is added without
changing the others.

## Validation

Checking a request on the client before it is sent, from what the
descriptors already carry, such as a `REQUIRED` field left empty or an
`OUTPUT_ONLY` field set. Additive runtime functions over the
descriptors: a minor.

## Resource names and pagination

Helpers for the API design conventions many protos follow: resource
names (`users/{user}/notes/{note}`) read and written from their
patterns, and the `page_token` / `next_page_token` loop that lists a
collection page by page. Additive runtime modules: a minor.

## Update masks from two values

The field mask of what changed between two values of a message,
computed from its descriptor. The notes example has one
(`examples/notes/elm/src/Snippets/UpdateMask.elm`); in the runtime it
would be an addition: a minor.

## `Retry-After` and `RetryInfo`

A retry policy waits by its own backoff. Honouring the server's
`Retry-After` header on a 429 or 503, or a `google.rpc.RetryInfo`
error detail, would be a new setting on the opaque `Rpc.Retry`: a
minor.

## Envoy in the live suite, and an Envoy example

The live suite runs against connect-go, Vanguard and grpc-gateway. A
documented example with Envoy's gRPC-JSON transcoder in front of the
same service, run by the live suite with its differences recorded as
the other transcoders' are, would exercise Envoy's header-only errors
(`grpc-status` headers and no body, which the runtime already reads as
`Rpc.Error.GrpcHeaders`) against a real Envoy. No version impact.

## Prebuilt binaries, an npm wrapper and the Buf plugin

Today the CLI and the plugin are installed with `cargo install`.
Prebuilt binaries attached to each release, an npm package that
fetches the right one, and `protoc-gen-elm-connect` published as a
remote plugin on the Buf Schema Registry, so `buf generate` needs no
install. No version impact: the plugin's options are already the
contract.

## Agent affordances in the CLI

Diagnostics an agent or a tool can read without parsing the rendered
text: a machine-readable output of each problem's code, site and help,
and `elm-connect --explain <code>` printing what a code means and its
escape, as [diagnostics.md](diagnostics.md) lists them. Additive flags:
a minor. (`elm-connect guide`, printing the
[agent guide](agent-guide.md), is built.)

## Consolidating the test suites

A pass over the test layers (the conformance corpus, the route
fixtures, the property tests, the codec round trips and the live
suite) to remove what they repeat. Nothing a user sees changes: no
version impact.

## Not planned

- **Client and bidirectional streaming.** A browser cannot stream a
  request body to a server, except Chrome over HTTP/2, and connect-es
  does not offer these in browsers either. A headless program under
  Node could, as connect-node's clients do; that would be a Node-only
  addition, taken up if asked for. If browsers change, they would be
  additions like server streaming.
- **Interceptors.** The config is data; the pattern that replaces them
  (one function every call goes through, and the pure halves for
  rewriting a request) is in [calling.md](calling.md).
- **Server code generation.** elm-connect generates clients.
- **Splitting the package.** One package holds the codecs and the
  calls. No `Proto` module imports an `Rpc` one, so a split stays
  possible, but it would move modules out of the package, which is a
  major; it is revisited only for a transport whose runtime is mostly
  its own ([decisions.md](decisions.md#no-package-split)).
