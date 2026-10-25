- `Proto.Method.Method` and `Proto.Message.Message` are now aliases of
  unions inside the package, so the package documentation and compiler
  errors may name them `Proto.Internal.Method.Method` and
  `Proto.Internal.Message.Message`. Every function's type is unchanged,
  and both stay opaque.
