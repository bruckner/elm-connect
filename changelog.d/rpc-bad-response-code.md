- `Rpc.Error.BadResponse` has a `Code` as its first argument,
  `BadResponse code problem answer`, and `Rpc.Error.code` of one is that
  code: `Unimplemented` for a unary gRPC-Web answer with status 0 and no
  message or more than one, as connect-es and connect-go give it, and
  `Internal` otherwise, as before. A pattern `BadResponse problem answer`
  becomes `BadResponse _ problem answer`.
