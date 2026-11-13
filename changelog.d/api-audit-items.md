- `Proto.Error.Reason`'s reason for a 64-bit integer an `Int` cannot
  hold is `IntOutOfRange`, so `Proto.Error(..)` and `Rpc.Code(..)` can
  be exposed together; the binary report's note already uses the
  new name.
- `Rpc.Retry.next` takes the failed call's `error : Rpc.Error.Error` in
  place of `code : Rpc.Code.Code`, and reads the code itself; like the
  runtime's own loop it stops on a `BadUrl`, where nothing was sent.
  Replace `code = Rpc.Error.code err` with `error = err`.
