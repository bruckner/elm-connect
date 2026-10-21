# Envoy's gRPC-JSON transcoder

A gRPC service needs nothing of its own to serve an Elm client: put
Envoy in front of it with its
[gRPC-JSON transcoder](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/grpc_json_transcoder_filter),
and the client calls it over `Rpc.Transport.transcode`. Envoy reads the
`google.api.http` rules from a descriptor set of the service's protos,
turns each REST request into a gRPC call, and the answer back into
proto3 JSON. The service needs no Connect handler, no grpc-gateway code
and no HTTP server beyond its gRPC one.

The notes example runs this way in the live suite: Envoy 1.40.0, fetched
by func-e, in front of the example server's gRPC handler, with the
config in
[`conformance/live/envoy/envoy.yaml`](../conformance/live/envoy/envoy.yaml).
This page walks through that config, runs it by hand, shows what the
runtime reports for Envoy's two error forms, and lists where Envoy and
the route fixtures part. [transcoding.md](transcoding.md) covers what
the runtime sends over any transcoder.

## The config

The file has two listeners in front of one cluster:

| Port | Listener | Errors |
|---|---|---|
| 18081 | `status_body` | `convert_grpc_status: true`: a `google.rpc.Status` JSON body |
| 18082 | `grpc_headers` | Envoy's default: `grpc-status` and `grpc-message` headers, no body |
| 18080 | the cluster `notes` | the example server, called over gRPC |

The transcoder's settings on the first listener:

```yaml conformance/live/envoy/envoy.yaml#transcoder
proto_descriptor: target/live/notes.binpb
services: [notes.v1.NotesService, routes.v1.Routes]
# POST /<package>.<Service>/<Method> for every method,
# the implicit route a method without a rule is called at.
auto_mapping: true
# Decode a path variable as google.api.http says: every
# percent-encoded byte but a slash in a multi-segment
# variable. Envoy's default keeps the reserved
# characters encoded (%2B stays %2B), and the runtime
# encodes every reserved character it sends.
url_unescape_spec: ALL_CHARACTERS_EXCEPT_SLASH
# A gRPC error becomes a google.rpc.Status JSON body,
# details included, under the HTTP status of its code.
convert_grpc_status: true
# What the generated decoders read: proto3 JSON with
# lowerCamelCase names, defaults left out, enums by
# name. These are Envoy's defaults, written out.
print_options:
  add_whitespace: false
  always_print_primitive_fields: false
  always_print_enums_as_ints: false
  preserve_proto_field_names: false
# Envoy passes a request no method matches, or one
# with a query parameter that names no field, through
# to the server untranscoded; this server would then
# answer it with its own transcoder in Envoy's place.
# Envoy answers both itself here (404 and 400).
request_validation_options:
  reject_unknown_method: true
  reject_unknown_query_parameters: true
```

- `proto_descriptor` is a descriptor set of the protos with every
  import, which buf builds from the example's module:
  `buf build --as-file-descriptor-set -o ../../target/live/notes.binpb`
  in `examples/notes`. It must hold the error detail types the service
  sends (`google/rpc/error_details.proto` here) for Envoy to write them
  in a Status body.
- `services` lists the services Envoy transcodes; a service left out is
  not served.
- `auto_mapping: true` serves `POST /<package>.<Service>/<Method>` for
  every method, the implicit route the runtime calls a method without a
  rule on ([transcoding.md](transcoding.md#methods-without-an-http-rule)).
- `url_unescape_spec: ALL_CHARACTERS_EXCEPT_SLASH` decodes path
  variables as `google/api/http.proto` asks. The default,
  `ALL_CHARACTERS_EXCEPT_RESERVED`, leaves the reserved characters the
  runtime percent-encodes as they came, so a note named `notes/a b+c`
  reaches the service as `notes/a b%2Bc`, and a multi-segment value
  holding `:` keeps `%3A` (the transcode case "percent-encoded path"
  and the fixture "a multi-segment variable keeps /" fail under it).
- `print_options` are Envoy's defaults, written out: lowerCamelCase
  names, defaults left out, enums by name. The decoders accept the
  other choices too ([transcoding.md](transcoding.md#responses-server-options-the-client-reads)).
- `request_validation_options`: by default Envoy passes a request no
  method matches, or one with a query parameter that names no field, on
  to the cluster untranscoded. Behind it is a gRPC server, which would
  answer with an error of its own; the example server also transcodes,
  so it would answer in Envoy's place. With both set, Envoy answers
  404 and 400 itself, in plain text.

The cluster speaks HTTP/2 without TLS (h2c), which gRPC needs and the
example server accepts:

```yaml conformance/live/envoy/envoy.yaml#h2c
# gRPC needs HTTP/2; the server speaks it without TLS (h2c).
typed_extension_protocol_options:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
    explicit_http_config:
      http2_protocol_options: {}
```

One route passes the server's canned answers (`/status/<n>/`,
`/grpc-status/<code>/`) and `/healthz` through with the transcoder
disabled for it; they are the live suite's, not part of a deployment.

A page served from another origin needs Envoy's CORS filter too, with
`grpc-status` and `grpc-message` in `expose_headers` when errors travel
in headers; without them the browser hides the status and the error is
an `HttpStatus` one ([transcoding.md](transcoding.md#errors-in-headers)).
The live suite calls from Node, where CORS does not apply, so the
config has none; this is from Envoy's documentation, not the live
suite.

## Running it

func-e downloads and runs a pinned Envoy, on Linux and macOS, without
Docker. It is pinned in `mise.toml`, and the Envoy release in
`conformance/live/envoy/envoy-version`:

```sh
mise install                    # func-e, with the other tools
just live-envoy                 # build, start the server and Envoy, run the suite
```

By hand, from the repository root (Envoy reads the descriptor set's
path relative to where it runs):

```sh
(cd examples/notes && buf build --as-file-descriptor-set -o ../../target/live/notes.binpb)
just example-notes 127.0.0.1:18080 &           # the server, with the browser example
ENVOY_VERSION=$(cat conformance/live/envoy/envoy-version) func-e run -c conformance/live/envoy/envoy.yaml
curl http://127.0.0.1:18081/v1/notes/welcome
```

Envoy logs to the terminal, and func-e keeps a copy of each run's log
under `~/.local/state/func-e/envoy-runs/`.

func-e checks the archive it downloads against the SHA-256 that
Tetrate's index (`envoy-versions.json`) lists beside it, fetched over
HTTPS from the same archive, so the suite trusts Tetrate's archive and
its index, with the index's checksum. Envoy's project publishes Linux
binaries and container images; the macOS build is Tetrate's. func-e
1.6.0 hashes only the bytes its unpacker has read when the tar stream
ends, so a right archive sometimes fails that check (1.40.0's last 20
bytes go unread) and leaves the unpacked binary in place, unchecked;
`just live-envoy` then fetches the archive itself and checks it against
the same digest (the `envoy-install` recipe).

## Errors

The same two calls, through each listener, as the live suite sends
them (`cases/transcode.json` through `status_body`, `cases/envoy.json`
through `grpc_headers`):

| Call | `status_body` (`convert_grpc_status: true`) | `grpc_headers` (default) |
|---|---|---|
| `GetNote` of a missing note | 404, `{"code":5,"message":"notes/missing does not exist","details":[ErrorInfo]}` | 404, `grpc-status: 5`, `grpc-message: notes/missing does not exist`, empty body |
| `CreateNote` without a title | 400, `{"code":3,…,"details":[BadRequest]}` | 400, `grpc-status: 3`, `grpc-message: a note needs a title`, empty body |

What `Rpc.Error` gives the application:

| | `status_body` | `grpc_headers` |
|---|---|---|
| `Rpc.Error.code` | `Rpc.Code.NotFound`, `Rpc.Code.InvalidArgument` | the same |
| `Rpc.Error.message` | the service's message | the same, percent-decoded |
| `source` | `StatusBody` | `GrpcHeaders` |
| `Rpc.Error.details` | the `ErrorInfo` and `BadRequest` | none: Envoy forwards no `grpc-status-details-bin` |

So convert errors when the client reads details; `Google.Rpc`'s
`BadRequest` field violations, for one, only arrive that way. Either
way the runtime reads the code from the status, not from the HTTP
status.

Envoy's own answers are plain text, and the runtime infers their code
from the HTTP status: a path no method matches is 404
`Could not resolve <path> to a method.`, an `HttpStatus` error with
`Rpc.Code.Unimplemented`. Envoy's HTTP/1.1 codec also writes its own reason
phrase, `Unknown` for a status it has no name for, so a 418 from the
service arrives with the message `Unknown` (`cases/envoy.json`).

Headers the call sends reach the service as gRPC metadata, by name, and
the service's response metadata comes back as headers (the
`x-echo` case of `cases/notes.json`): unlike grpc-gateway, Envoy needs
no `Grpc-Metadata-` prefix.

## Where Envoy and the fixtures part

The route fixtures run against `status_body`
([`known-divergent-envoy.json`](../conformance/live/known-divergent-envoy.json)
records each answer, with a reading):

- `routes.proto` holds two pairs of bindings with one verb and path
  shape: `GetMessage`'s `GET /v1/{name=messages/*}` and
  `GET /v1/messages/{message_id}`, and `UpdateMessage` and
  `UpdateMessageWhole` on `PATCH /v1/messages/{message_id}`. Envoy's
  path matcher marks each such path ambiguous and then matches neither,
  with no word at startup: five fixtures get 404 (http_proto.json "a
  variable with a multi-segment template", "fields outside the path
  become query parameters", "a body field", "body * holds every field
  not in the path"; bodies.json "an unset body field is an empty
  object"). Vanguard refuses the second binding and grpc-gateway lets
  one win; no router serves that rule whole, but Envoy's silence is
  the surprise. Check a service's rules for such pairs before putting
  Envoy in front of it.
- A custom `HEAD` binding (encoding.json "a custom HTTP method"): Envoy
  transcodes the request right but writes the response body after the
  headers, which an answer to `HEAD` must not have. Node's HTTP parser
  fails the exchange, so the runtime under the suite reports
  `NetworkError`; what a browser does with the stray bytes is not
  verified.
- As under the other transcoders, a path value under an unset message
  reaches the service as a set, empty message (query.json "a path value
  under an unset message is its default; defaults are written").

Where Envoy agrees and another does not: an empty
`google.protobuf.StringValue` sent as `label=` is accepted (Vanguard
rejects it), and a `google.protobuf.FieldMask` in the query is read in
its JSON form (grpc-gateway keeps it as written). The probes of the
other files answer: an unknown query parameter 400 (with
`reject_unknown_query_parameters`), a verb without a route 404 (with
`reject_unknown_method`), and `PATCH` without an update mask is passed
on as sent, as Vanguard does.

## The live suite

`just live` runs `just live-envoy` after the Vanguard and grpc-gateway
runs: the transcode cases of `cases/notes.json` and `cases/transcode.json`
and the route fixtures against `status_body`, and `cases/envoy.json`
against `grpc_headers`. The ports are variables at the top of the
Justfile's Envoy recipes (`envoy_origin_port`, `envoy_port`,
`envoy_headers_port`, `envoy_admin_port`); the recipe writes a copy of
the config with them into `target/live/envoy.yaml`. Against an Envoy
you started yourself:

```sh
node conformance/live/run.mjs --server http://127.0.0.1:18081 --origin http://127.0.0.1:18080 --transport transcode conformance/live/cases/notes.json conformance/live/cases/transcode.json
node conformance/live/routes.mjs --server http://127.0.0.1:18081 --known conformance/live/known-divergent-envoy.json
node conformance/live/run.mjs --server http://127.0.0.1:18082 conformance/live/cases/envoy.json
```

`--origin` names the example server behind the proxy, for the cases'
canned answers ([`conformance/README.md`](../conformance/README.md)).
CI runs the same in its `live` job, with func-e's downloads cached on
`envoy-version`.
