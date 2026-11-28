- Writing a message as JSON counts an `Any` it holds where a JSON read
  does. A message on a cycle that holds an `Any`, read from binary and
  written as JSON, counted the `Any` one level lower than a read: 100
  messages deep, its `Any` was refused by a JSON read (the `Any` is level
  101) but written after a binary read. The write now refuses it with
  `TooDeep`, named `google.protobuf.Any`, exactly where the read does;
  nothing a JSON read accepts is refused. Generated code writes such an
  `Any` with `Proto.Json.Encode.any`, and `Proto.Json.Encode.deeper` counts
  from 1 as a read does; regenerate.
