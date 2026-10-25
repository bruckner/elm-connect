# Specifications

The documents elm-connect implements, or reads its inputs by, and where
each one meets the code. No copies are kept in this repository; the
links go to the sources, which move. [design.md](design.md) says what
elm-connect takes from each and where it departs, and the page named
beside each link says what the runtime or the generator does about it.

## Connect

- [Connect protocol](https://connectrpc.com/docs/protocol/): the unary
  request and response over HTTP, `Connect-Protocol-Version`, the JSON
  error shape and its codes, the mapping from an HTTP status to a code,
  and GET for methods without side effects. `Rpc.Transport.connect` and
  `connectGet` ([calling.md](calling.md)).
- [Connect conformance suite](https://github.com/connectrpc/conformance):
  the official test runner; the live suite runs the runtime under it
  with the features
  [`conformance/live/conformance.yaml`](../conformance/live/conformance.yaml)
  declares ([conformance/README.md](../conformance/README.md)).

## Protocol Buffers

- [Language guide, proto3](https://protobuf.dev/programming-guides/proto3/):
  what the generator reads. A proto2 file and a file that declares an
  [edition](https://protobuf.dev/editions/overview/) are refused
  ([diagnostics.md](diagnostics.md), [roadmap.md](roadmap.md)).
- [ProtoJSON format](https://protobuf.dev/programming-guides/json/):
  the JSON the generated codecs write and read, on both transports
  ([generator.md](generator.md)).
- [Protobuf conformance suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance):
  protobuf's test runner for parsers and serializers. `just
  protobuf-conformance` runs it, opt-in and outside the gate, against the
  runtime's proto3 JSON codecs through the Elm generated for its
  `test_messages_proto3.proto`: JSON in and JSON out, with protobuf
  binary, JSPB, text, proto2 and editions answered skipped. The cases
  that fail are listed and classified in
  [`conformance/protobuf/failure_list.txt`](../conformance/protobuf/failure_list.txt)
  ([conformance/protobuf/README.md](../conformance/protobuf/README.md)).
- [Well-known types](https://protobuf.dev/reference/protobuf/google.protobuf/):
  `Timestamp`, `Duration`, `FieldMask`, `Any`, the wrappers and the
  rest, and their JSON ([generator.md](generator.md),
  [descriptors.md](descriptors.md)).
- [Style guide](https://protobuf.dev/programming-guides/style/) and
  [proto limits](https://protobuf.dev/programming-guides/proto-limits/):
  the naming conventions the Elm names assume, and the bounds the
  generator holds to ([design.md §3](design.md#3-generated-types)).
- [`descriptor.proto`](https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/descriptor.proto)
  and [`plugin.proto`](https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/compiler/plugin.proto):
  the generator's input, and the protocol `protoc-gen-elm-connect`
  speaks with protoc and buf ([generator.md](generator.md)).

## HTTP transcoding

- [`google.api.http`](https://github.com/googleapis/googleapis/blob/master/google/api/http.proto):
  the `HttpRule` grammar, in the comments of the proto itself, that
  `Rpc.Transport.transcode` follows ([transcoding.md](transcoding.md)).
- [AIP-127](https://google.aip.dev/127), HTTP and gRPC transcoding;
  [AIP-134](https://google.aip.dev/134), update masks under PATCH;
  [AIP-126](https://google.aip.dev/126), enums: the API design rules the
  rules and the generated code are read against
  ([transcoding.md](transcoding.md), [descriptors.md](descriptors.md)).
- The transcoders the live suite runs against:
  [grpc-gateway](https://github.com/grpc-ecosystem/grpc-gateway),
  [Envoy's gRPC-JSON transcoder](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/grpc_json_transcoder_filter)
  and [Vanguard](https://github.com/connectrpc/vanguard-go). Where they
  differ: [transcoding.md](transcoding.md), [envoy.md](envoy.md).

## gRPC

- [`google.rpc.Status`](https://github.com/googleapis/googleapis/blob/master/google/rpc/status.proto),
  [`google.rpc.Code`](https://github.com/googleapis/googleapis/blob/master/google/rpc/code.proto)
  and the [error details](https://github.com/googleapis/googleapis/blob/master/google/rpc/error_details.proto):
  the error body under transcoding, the codes `Rpc.Code` names, and the
  details `Rpc.Error.details` reads ([calling.md](calling.md),
  [descriptors.md](descriptors.md)).
- [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md):
  the `grpc-status`, `grpc-message` and `grpc-status-details-bin`
  headers a transcoder may answer with, which the runtime reads
  ([transcoding.md](transcoding.md)).
- [gRPC-Web](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md):
  not a transport of the runtime ([roadmap.md](roadmap.md)).

## HTTP and formats

- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110), HTTP semantics:
  methods, the token a custom verb must be, status codes.
- [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986), URIs: how path
  values and query parameters are percent-encoded.
- [RFC 3339](https://www.rfc-editor.org/rfc/rfc3339), timestamps: how
  `Timestamp` is written in JSON and in a query.
