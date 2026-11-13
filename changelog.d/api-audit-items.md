- `Proto.Error.Reason`'s reason for a 64-bit integer an `Int` cannot
  hold is `IntOutOfRange`, so `Proto.Error(..)` and `Rpc.Code(..)` can
  be exposed together; the binary report's note already uses the
  new name.
