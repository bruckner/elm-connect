- New protocol: `Rpc.Protocol.grpcWeb` calls unary methods over
  gRPC-Web in protobuf binary, for a server or proxy that serves it
  (connect-go, Envoy's gRPC-Web filter, grpcwebproxy), with code
  generated under `codec=proto` or `codec=both`. A call is one POST of
  the request in a gRPC-Web frame as `application/grpc-web+proto`, with
  `X-Grpc-Web: 1` and the client's timeout as `grpc-timeout`. The
  answer's status is read from the trailers frame in its body, or from
  its headers when it has none, with `grpc-message` percent-decoded and
  the details from `grpc-status-details-bin`. `withReadMaxBytes` and
  `withWriteMaxBytes` count the messages, not their frames;
  `withConnectGet` and `withMaxGetUrl` leave it as it is.
  `Rpc.Protocol.name` gives `"grpc-web"`. A program that does not name
  it carries none of its code.
- `Rpc.Error.GrpcTrailers` is given now: it is the source of a status
  read from a gRPC-Web answer's trailers frame. A traced call gives
  those trailers in `Rpc.Trace.trailers`.
