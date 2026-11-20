- The generator option `unknown_fields=drop|keep` (CLI
  `--unknown-fields`), default `drop`, says what becomes of a field that
  protobuf binary carries and the message's schema does not know, such
  as one a newer server added. Under `keep` every generated message
  record gains a last field, `unknownFields_ : Proto.Unknown.Fields`:
  a binary read keeps such fields there (and a declared field in a wire
  type its declaration does not take), by field number and in arrival
  order within one; a binary write puts them back after the known
  fields; `==` sees them. Proto3 JSON carries none: a JSON read gives
  none and a JSON write leaves them out. Every record literal of a
  generated message then names the field (`unknownFields_ =
  Proto.Unknown.empty`); a record built from the default by update
  needs nothing. Under `drop` the generated code is what it was.
- `Proto.Unknown`, a new module: `Fields`, `empty`, and the fields as
  data, `Value(..)`, `toList` and `fromList`. `Proto.Binary` gains
  `mergeKeep` and `unknown`, which code generated under `keep` calls.
- `Proto.Unknown` is a module of the runtime, so a proto package
  `proto.unknown` is now refused (`naming::reserved_module`), whatever
  `unknown_fields` says; move it with `rename` or `module_prefix`.
