- An `Any` read from proto3 JSON, or packed, keeps its message's JSON
  beside its binary, and writing it as JSON again writes that JSON as it
  arrived (defaults, proto names and unknown fields included), with no
  conversion and no registry. The read is as strict as before, `unpack`
  reads the binary, and an `Any` read from binary converts through the
  registry as before. A Connect error detail keeps its `debug` JSON the
  same way, where `proto-any`'s notes say it is not read.
- `==` on `Any` sees the JSON it keeps: an `Any` read from binary and
  the same one read from JSON are not `==`, where `proto-any`'s notes
  say `==` compares content. The new `Proto.Any.equal` compares the type
  URL and the binary alone.
