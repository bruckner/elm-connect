# HTTP transcoding

Over `Rpc.Transport.transcode`, a call is sent as the REST request its
method's `google.api.http` rule describes, for a server behind
grpc-gateway, Envoy's gRPC-JSON transcoder or Vanguard. This page says
what the runtime sends, what it reads back, which server options it
works with, and where the transcoders it is tested against differ.
The `google.api.http` grammar and the other documents involved are
listed in [specs.md](specs.md).

What the live suite checks, it says so; the rest comes from the
transcoders' documentation and source, cited by option name so it can be
looked up. The live suite runs connect-go v2.0.1 behind Vanguard v0.5.0
and grpc-gateway v2.32.0, both with their default options, and behind
Envoy 1.40.0's gRPC-JSON transcoder with the config
[envoy.md](envoy.md) walks through
([`conformance/README.md`](../conformance/README.md)).

## What a call sends

A call goes over its rule's binding: the rule's own, or with
`Rpc.Call.viaBinding n` one of its `additional_bindings`. The request
is the binding's verb; the path filled from the request's fields; the
query from the fields outside the path and the body; and the body as
the binding says (`body: "*"`, one field, or none). Values are written
as proto3 JSON writes them, unquoted: enums by name, 64-bit integers in
decimal, timestamps in RFC 3339. The query holds only the fields that
are set: a field with presence when it is present, any other field when
it differs from its default.

A success is any 2xx, an empty body reading as `{}`, and the response
decoded from the field `response_body` names when the rule names one.

## Methods without an HTTP rule

A method without a `google.api.http` rule is generated like the rest.
Over Connect nothing changes. Over transcoding it is sent on the
implicit route, `POST /<package>.<Service>/<Method>` with the request as
its JSON body, which is the request Connect sends. In the notes
example, `Ping` is `POST /notes.v1.NotesService/Ping`. Servers serve
that route as follows:

| Server | Implicit route |
|---|---|
| grpc-gateway | with `generate_unbound_methods=true` (live) |
| Envoy gRPC-JSON transcoder | with `auto_mapping: true` (live) |
| Vanguard | always; v0.5 serves rules only, and the Connect handler mounted beside it serves the route (live) |
| A Connect handler (connect-go, connect-es, …) | always: it is the Connect request |

For a server that serves rules alone, generate with
`unbound_methods=error`, and a method without a rule is a diagnostic
rather than a call that fails at run time
([generator.md](generator.md#options)).

## Responses: server options the client reads

The decoders are lenient where proto3 JSON allows a choice, so these
server options need nothing on the client (from the decoders and the
runtime's unit tests; the live suite runs each transcoder with its
defaults):

| Server option | grpc-gateway (`protojson.MarshalOptions` in `runtime.JSONPb`) | Envoy (`print_options`) | The client |
|---|---|---|---|
| fields by proto name | `UseProtoNames` | `preserve_proto_field_names` | accepts either name; an object holding both fails |
| enums as numbers | `UseEnumNumbers` | `always_print_enums_as_ints` | accepts names and numbers |
| defaults written out | `EmitUnpopulated` | `always_print_primitive_fields` | reads them as the defaults they are |
| indentation | `Indent` | `add_whitespace` | no effect |

A server that wraps responses in an envelope of its own (grpc-gateway's
`runtime.WithForwardResponseRewriter`) sends something that is no
longer the response message: the client cannot read it, and the call
fails with `BadResponse`. Read such an answer through the pure halves
([calling.md](calling.md#the-pure-halves)), or unwrap it on the server.

## Errors

grpc-gateway and Vanguard, and Envoy with `convert_grpc_status: true`,
answer an error with a `google.rpc.Status` body, `{"code": 5, "message":
…, "details": […]}`, and the HTTP status of its code. The runtime reads
it as `RpcStatus` with source `StatusBody` (live, under all three).

### Errors in headers

Envoy's transcoder, unless `convert_grpc_status: true`, answers an error
with an HTTP status and the `grpc-status` and `grpc-message` headers,
and no body. The runtime reads those headers as `RpcStatus` with source
`GrpcHeaders`, the message percent-decoded (live, against Envoy and
against the example server's `/grpc-status/<code>/…` route). Envoy
forwards no error details this way. With `convert_grpc_status: true`,
Envoy sends a `google.rpc.Status` body with the details instead, which
reads as above ([envoy.md](envoy.md#errors) compares the two).

A browser shows a cross-origin answer's headers to the page only when
the server lists them in `Access-Control-Expose-Headers`. Without
`grpc-status` there, the error has no status to read, and is an
`HttpStatus` error with the code inferred from the HTTP status.
[envoy.md](envoy.md#a-page-on-another-origin) configures Envoy's CORS
filter so.

## Request headers and metadata

The runtime sends the config's and the call's headers as they are,
over both transports. Which of them reach the service is the
transcoder's choice. grpc-gateway's default (`runtime.DefaultHeaderMatcher`)
forwards the standard HTTP headers, such as `Authorization` and
`Cookie`, as metadata prefixed `grpcgateway-`, and a header named
`Grpc-Metadata-<key>` as the metadata `<key>`; any other header is
dropped. Name a custom header `Grpc-Metadata-<key>` for grpc-gateway, or
set `runtime.WithIncomingHeaderMatcher` on the server. In the other
direction grpc-gateway sends the service's response metadata as
`Grpc-Metadata-<key>` headers and its trailers as `Grpc-Trailer-<key>`
headers, which the runtime leaves among the answer's headers
(`Rpc.Trace.headers`). From grpc-gateway's source, not the live suite.
Envoy forwards every header as metadata by its own name, and the
service's metadata back as headers (live).

## Path escaping

The runtime percent-encodes a path value's every byte but RFC 3986's
unreserved characters. In a single-segment variable, such as
`{message_id}`, that includes `/`; in a variable whose template has
several segments, such as `{name=notes/*}`, `/` stays. That is what
`google/api/http.proto` asks, and Vanguard serves it (live). Two server
settings decide whether a `/` inside a single-segment value survives:

- grpc-gateway's default unescaping mode, `UnescapingModeLegacy`,
  decodes the whole path before matching, so `%2F` becomes a separator
  and the call is a 404 (live). `runtime.WithUnescapingMode(runtime.UnescapingModeAllExceptReserved)`
  follows `http.proto` and serves it.
- Envoy's `url_unescape_spec` defaults to
  `ALL_CHARACTERS_EXCEPT_RESERVED`, which leaves every reserved
  character in a multi-segment variable encoded, `%2B` and `%3A` as
  well as `%2F` (live). `ALL_CHARACTERS_EXCEPT_SLASH` follows
  `http.proto` and serves them ([envoy.md](envoy.md#the-config)).

## Where the transcoders differ

The live suite runs every route fixture against Vanguard, grpc-gateway
and Envoy in front of the same service. Where a transcoder answered
other than `google/api/http.proto` and proto3 JSON say:

- grpc-gateway v2.32.0 forwards a `google.protobuf.FieldMask` query
  value's paths as written, so a mask sent in the query in its JSON form
  (`mask=displayName`) reaches the service as a path no field has, and
  the call fails.
- grpc-gateway v2.32.0, under its default unescaping mode, answers 404
  for a single-segment path variable holding `%2F` (above).
- Vanguard v0.5.0 rejects an empty `google.protobuf.StringValue` sent as
  `label=` with 400 `INVALID_ARGUMENT`. The fix,
  [connectrpc/vanguard-go#208](https://github.com/connectrpc/vanguard-go/pull/208),
  is merged, but not in a release as of 2026-10-20.
- Envoy 1.40.0 serves neither of two bindings with one verb and path
  shape, without a warning (the generator warns of such pairs,
  `route::ambiguous_binding`), and answers a `HEAD` binding with a body
  ([envoy.md](envoy.md#where-envoy-and-the-fixtures-part)).

Where neither side is wrong, the transcoders still answer differently:

- an unknown query parameter: Vanguard rejects it, grpc-gateway drops
  it, Envoy passes the request on untranscoded unless
  `reject_unknown_query_parameters` has it answer 400;
- a verb the path has no route for: Vanguard and grpc-gateway answer
  `UNIMPLEMENTED`, with HTTP 405 and 501; Envoy passes the request on
  unless `reject_unknown_method` has it answer 404 in plain text;
- a `PATCH` without an update mask: grpc-gateway fills `update_mask`
  with the fields the body sets (its `allow_patch_feature`, on by
  default), Vanguard and Envoy pass the request as sent.

The full readings are in
[`conformance/live/known-divergent-gateway.json`](../conformance/live/known-divergent-gateway.json),
[`conformance/live/known-divergent-vanguard.json`](../conformance/live/known-divergent-vanguard.json)
and [`conformance/live/known-divergent-envoy.json`](../conformance/live/known-divergent-envoy.json).
