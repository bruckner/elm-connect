# Roadmap

What may come after 1.0. Each entry says what it is, what it needs,
and whether it would ship in a minor release or need a major one,
under the compatibility rules of [design §8](design.md#8-compatibility-and-versioning): within a
major, generated code compiles against every later runtime of that
major, the runtime's API only grows, and the same protos with the same
options generate the same modules, types and values. The page promises
no dates and no order. An entry is a direction, not a commitment; the
reasons behind the settled questions are in
[decisions.md](decisions.md). A few entries are follow-ups of the 0.2
interface, to be settled before 1.0, and say so. gRPC-Web, once an
entry here, is a protocol now ([calling.md](calling.md#protocols)).

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
`stream_sse_style_delimited`. Which one a server uses would be a
modifier of `Rpc.Protocol.transcode`, so it is a minor too, and it
comes with server streaming over Connect, not before.

## Unknown fields

A field a decoder does not know is skipped, in proto3 JSON and in
binary alike, so a message read and written back loses it, where
protobuf's own runtimes keep such fields and write them again. Keeping
them needs somewhere to hold them, and a generated message is a plain
Elm record that an application builds with record syntax and compares
with `==`: a hidden field would show up in every record literal, and
Elm has no private record field. It would need an extra field the
generator adds to every message (or an opaque message type), which
changes every generated record, so a major, or an option that adds the
field, a minor. Two protobuf conformance cases need it.

## Editions and proto2

Today a proto2 file is `input::not_proto3` and a file that declares an
edition is `input::editions`. Accepting them turns an error into
output, so it is a minor: the descriptors already reserve
`CardinalityRequired` for `required` fields, and closed enums,
non-zero defaults and explicit presence become descriptor modifiers
and generated decoders. Groups and extensions would stay refused.
Two fields of one message whose names are the same once lowercased
without underscores (`aB` and `ab`), which protoc accepts and the
descriptor library refuses in any file but a proto2 one, are
`input::field_name_conflict`; accepting them as protoc does, once that
library's rule matches protoc's, is a minor too.

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

## Well-known `Google.*` modules

Today an application generates the `google.rpc` error details and any
other googleapis types it uses itself, from googleapis files. Prebuilt
modules for the common googleapis packages are an addition: a minor.

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

## Hooks: the client

Hooks are the client. `Rpc.Client` holds functions already, its
protocol's and those its modifiers install, and stays `==` because each
modifier also sets a data field compared before any function. A hook,
a function every call goes through, would be one more modifier that
installs it. Every use of an interceptor met so far maps onto data,
the trace or the pure halves ([calling.md](calling.md)), so none is
built. A minor: a new modifier.

## One outcome for every call

Today a cancelled call reports nothing, and a call sent with a retry
policy has no tracker, so it cannot be cancelled
([design §5.2](design.md#52-rpc)); an application that must cancel one
runs the loop itself, with `Rpc.Retry.next` and `Rpc.Call.withoutRetry`.
A model-held state machine (`Rpc.Pending`, stepped by an `update`) that
owns the retry loop would make a retried call cancellable and have
every call report exactly one outcome; a
streaming protocol would need the same machine, and would share it.
An addition beside `Rpc.send` and `Rpc.task`: a minor.

## A fake protocol for tests

Today a program's calls are tested through the pure halves:
`Rpc.request` shows what a call would send and `Rpc.response` reads an
answer, with no server. A protocol that answers from data the test
supplies would let `Rpc.task` and `Rpc.send` themselves run in a test.
The protocol's shape is the seam: it already holds the functions that
build a call's request and read its answer, so a fake one answers the
request it builds from the test's data in place of elm/http, and the
client and the calls stay as they are. A minor: `Rpc.Protocol` is
opaque, so a protocol is added without changing the others.

## A table-driven binary merge

A generated binary decoder, `merge*Bytes`, is one `case` arm per field,
each with a helper call and a record-update lambda: about four times
the source of the message's JSON decoder, and 64 % of a package module
generated with `codec=proto`. That section is where compile time can
be won. A table of fields
(`[ ( 1, Proto.Binary.string (\v r -> { r | name = v }) ), … ]`) read by
one runtime loop would roughly halve the source and the `codec=both`
compile time, for a lookup where the `case` compiles to a switch. Not
measured yet. A minor: the generated decoders keep their names and
types, and the runtime gains the table's reader.

## `Rpc.Client.problems` by construction

`Rpc.Client.problems` reports a bad base URL, header or size limit at
run time. Ruling them out by construction would put a `Result` where
the client is built: either typed inputs checked once
(`Rpc.baseUrl : String -> Result Problem BaseUrl`, after which
`Rpc.client` cannot fail) or one builder that reports every problem at
once. The `Result` form is the one favoured. A call's own headers, its
path values and the answers stay run-time failures whichever is
chosen. Revisited before 1.0, since either shape changes how every
application builds its client.

## A route table for Connect-only applications

A generated method carries its route functions, so a program that only
speaks Connect still carries the routes of every method with a
`google.api.http` rule: 129 to 151 B gzipped per method in the
measurement that kept them there. A table of routes given to
`Rpc.Protocol.transcode` would move that cost to the programs that
transcode. In the interpreter form measured it cost those programs
1,112 B and 43 to 217 % more time per transcoded request, so it was not
adopted. A table of generated functions, each a top-level `Value ->
Route`, should be smaller and faster, and is the form to measure if an
application full of rules that never transcodes asks for it. A minor:
an addition beside the routes on the method.

## A routes-off option

A generator option to leave out the route functions, for an
application that never transcodes. Deferred until requested: today such
an application deletes the `google.api.http` annotations from the
protos it generates from. A minor (a new option).

## `Any` and the registry

Three rough edges of `Proto.Any` under the binary codecs. The table
that converts an `Any`'s JSON to binary has no mirror, so an `Any` read
as binary and written as JSON falls back to Connect's `{type, value}`
form rather than the message's own JSON. The generated
`binaryRegistry` is the table that converts an `Any`'s JSON to binary,
which its name does not say. And every `codec=both` package carries the
conversion table as soon as one of its fields is an `Any`. A pass over
them is a minor if it adds the mirror and keeps the name; renaming
`binaryRegistry` is a break, so it is done before 1.0 or not at all.

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

## A gRPC service config's `retryPolicy`

A gRPC client takes its retry policy from a service config, a JSON
document with a `retryPolicy` per set of methods
([service config](https://github.com/grpc/grpc/blob/master/doc/service_config.md),
[gRFC A6](https://github.com/grpc/proposal/blob/master/A6-client-retries.md)):
`maxAttempts`, `initialBackoff`, `maxBackoff`, `backoffMultiplier` and
`retryableStatusCodes`. A decoder from that JSON to an `Rpc.Retry`, so an
application whose server already publishes one need not transcribe it.
Attempts, the two backoffs and the codes map as they are. The multiplier
is fixed at 2 here and would need a `withMultiplier` knob. gRPC's jitter
is ±20% of the wait where this policy draws from zero to it: a documented
difference, not a knob. The per-method `name` list is the application's
to apply, and pushback, throttling and hedging stay out. A function and a
knob on the opaque `Retry`: a minor.

## An npm wrapper and the Buf plugin

Today the CLI and the plugin are installed from a release's prebuilt
binaries or with `cargo install` ([install.md](install.md)). An npm
package that fetches the right binary for the platform, and
`protoc-gen-elm-connect` published as a remote plugin on the Buf Schema
Registry, so `buf generate` needs no install. No version impact: the
plugin's options are already the contract.

## Release branches

Releases are cut from `main`, and the release workflow refuses a tag
whose commit is not on it ([design §8.7](design.md#87-releasing)). If a
`1.x` ever needs patches beside a `2.x`, a `release/1.x` branch would
carry them, and the workflow's check would accept that branch beside
`main`. Nothing is needed until then. No version impact.

## The compatibility check in CI

From 1.1 on, a release checks by hand that code generated by the last
minor compiles against the new runtime, and that `elm diff` agrees
with the release's magnitude ([design §8.7](design.md#87-releasing)).
A CI job doing the same on every pull request would catch a break
when it is made rather than when a release is cut. No version impact.

## Agent affordances in the CLI

Diagnostics an agent or a tool can read without parsing the rendered
text: a machine-readable output of each problem's code, site and help,
and `elm-connect --explain <code>` printing what a code means and its
escape, as [diagnostics.md](diagnostics.md) lists them. Additive flags:
a minor. (`elm-connect guide`, printing the
[guide](guide.md), is built.)

## Small examples for learning from

The notes example was meant to double as the implementation to
consult, and serves verification well, but carrying two protocols,
the error panel and the live suite's needs makes it too much to learn
from first ([design §7](design.md#7-conformance)). Teaching wants a few short,
well-documented examples that each show one thing, kept compiling the
same way. No version impact.

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
- **Interceptors.** The pattern that replaces them (one function every
  call goes through, and the pure halves for rewriting a request) is
  in [calling.md](calling.md); a hook, if one is needed, is a client
  modifier ([Hooks](#hooks-the-client)).
- **Server code generation.** elm-connect generates clients.
- **Splitting the package.** One package holds the codecs and the
  calls. No `Proto` module imports an `Rpc` one, so a split stays
  possible, but it would move modules out of the package, which is a
  major; it is revisited only for a protocol whose runtime is mostly
  its own ([decisions.md](decisions.md#no-package-split)).
