# Compared with other tools

As of 2026-10-20. The other projects move, so this page goes stale;
check their own pages for anything that decides a choice.

## The existing Elm protobuf stack

The Elm tools for protobuf, from the Elm package index and npm:

- **protoc-gen-elm** (npm `protoc-gen-elm` 4.0.4, 2024-08-24) generates
  Elm from protos under protoc, with **elm-protocol-buffers**
  (`eriktim/elm-protocol-buffers` 1.2.0, 2022-11-07) for the binary
  codecs, **elm-grpc** (`anmolitor/elm-grpc` 1.1.0, 2024-05-29) for
  calls, and `anmolitor/elm-protoc-types` (2.0.0, 2024-03-01) and
  `anmolitor/elm-protoc-utils` (2.3.0, 2024-02-29) for the well-known
  types. It is binary-first: with `--elm_opt=json` it also generates
  proto3 JSON codecs, but elm-grpc sends gRPC-Web, unary only, in
  protobuf binary.
- **tiziano88/elm-protobuf** (3.0.0, 2018) generates proto3 JSON codecs,
  with 64-bit integers as `Int` and no services.
- **feral-dot-io/protoc-gen-elmer** (1.0.1, 2022) generates binary
  codecs and a Twirp client.

None of them speaks the Connect protocol or `google.api.http`
transcoding. For a server that speaks binary gRPC-Web, protoc-gen-elm
with elm-grpc is the tool to use; elm-connect does not speak it.

## Coming from protoc-gen-elm

The codec names match (`encodeX`, `decodeX`, `defaultX`), and so do
recursive messages, which hold a wrapper type (`Node_`) on the field
that closes a cycle. What differs:

| protoc-gen-elm | elm-connect |
|---|---|
| a oneof is `Maybe` of a custom type, `Nothing` when unset | a custom type with an `…Unset` constructor, such as `NoteKindUnset`, as protobuf-es's `{ case: undefined }` |
| 64-bit integers are `Protobuf.Types.Int64`, opaque | `String`, the exact decimal; under `int64=int`, `Int` |
| `bytes` is `Bytes.Bytes` | the base64 `String`; under `bytes=bytes`, `Bytes.Bytes` |
| the well-known types come from elm-protoc-types (`Proto.Google.Protobuf.*`) | the runtime maps them: `Time.Posix`, `Proto.Duration.Duration`, `Maybe` for the wrappers, `Proto.Any.Any` ([generator.md](generator.md#what-a-proto-becomes)) |
| `Grpc.new rpc req \|> Grpc.addHeader … \|> Grpc.toCmd` | `Rpc.send config toMsg call`, with headers, timeout and retry in the config or on the call ([calling.md](calling.md)) |
| modules under `Proto.` (`Proto.Notes.V1`) | the package's own name (`Notes.V1`); `module_prefix=Proto` gives `Proto.Notes.V1`, except where a package would take one of the runtime's own `Proto.*` modules, which is the diagnostic `naming::reserved_module` |

protoc-gen-elm's `grpcDevTools` option feeds a browser extension;
elm-connect's `Rpc.sendTraced` gives the application a trace of each
call to log instead.

## The OpenAPI route

A team with protos can already get an Elm REST client: export OpenAPI
from them (grpc-gateway's `protoc-gen-openapiv2`, or
`sudorandom/protoc-gen-connect-openapi` for Connect endpoints) and
generate Elm from that with `wolfadex/elm-open-api-cli` (npm
`elm-open-api` 0.8.0, 2026-06-17). The OpenAPI document describes the
JSON's shape, not proto3 JSON's rules, so the client loses what the
protos said:

- 64-bit integers as exact strings, parsed from a string or a number;
- enums read by name or by number;
- the well-known types' JSON forms (`Timestamp`, `Duration`,
  `FieldMask` paths, `Struct`, the wrappers);
- a oneof's members as one custom type, so at most one is set;
- `Any`, and `google.rpc.Status` details unpacked by type;
- the Connect protocol: an OpenAPI client sends the REST routes only.

## What elm-connect has that its peers do not

1. One generated client that switches between Connect and
   `google.api.http` transcoding in its config. No Elm tool speaks
   either; outside Elm, Google's GAPIC generators switch between gRPC
   and REST the same way.
2. Generated codecs that follow proto3's canonical JSON mapping, which
   the OpenAPI route above loses
   ([generator.md](generator.md#what-a-proto-becomes)).
3. Tests against real servers: the official Connect conformance suite's
   unary JSON cases, and a live suite against connect-go, Vanguard and
   grpc-gateway, with the transcoders' differences published
   ([transcoding.md](transcoding.md#where-the-transcoders-differ)).
4. A retry policy gated on each method's declared idempotency, Connect
   GET with a URL cap, and cancellation.
5. A CLI that compiles protos itself, with no protoc, beside a
   conventional plugin for protoc and buf. The Elm generators above all
   need protoc.
6. Pure halves, `Rpc.request` and `Rpc.response`, so a client is tested
   without a server ([quickstart.md](quickstart.md#7-test-without-a-server)).
