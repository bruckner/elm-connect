- Over Connect and gRPC-Web, a 200 whose content type is not the
  protocol's at all, such as a proxy's HTML page or an image, is read as
  a failure: a Connect error body or `grpc-status` headers it carries
  are the error, and one with no status is an `HttpStatus` error, code
  `unknown`, where it was a `BadResponse` (`internal`). A 200 with no
  content type is still the answer, and transcoding still reads any
  success whatever its content type.
- A 200 of another of the protocol's content types than the call reads
  (`application/json` under Connect's proto codec, `application/proto`
  under its JSON codec, `application/grpc-web+json` over gRPC-Web) is
  still a `BadResponse`, now naming both types under either codec.
