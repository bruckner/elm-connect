# Changelog

All notable changes to this project are recorded here. The Elm package
follows Elm's enforced semantic versioning; the crates follow Cargo's.

## Unreleased

- Toolchain, Cargo workspace, conformance harness seed and CI; no
  generation yet.
- `elm-connect-gen`: protobuf descriptors to a typed IR of messages,
  enums, oneofs, maps and well-known types, with the Elm naming rules and
  diagnostics for names Elm cannot take. Nothing is emitted yet.
- `elm-connect-gen`: a typed Elm AST for generated code and a printer
  whose output elm-format 0.8.8 accepts unchanged.
- Generation, end to end for messages of singular scalar fields: record
  type aliases with proto3 JSON encoders and decoders, from both
  `elm-connect gen` and `protoc-gen-elm-connect`. Other constructs are
  reported as `generate::unimplemented`. The runtime package
  `bruckner/elm-connect` starts with `Connect.Json`, and the conformance
  corpus with its first case, `scalars`.
- Generation of proto3 `optional` fields and singular message fields as
  `Maybe`, and repeated fields as `List`, with the `cardinality`
  conformance case. Decoders accept a field under its proto name as well
  as its JSON name (`Connect.Json.fieldEither`), and 32-bit integers as
  strings and in exponent notation (`Connect.Json.int32`);
  `Connect.Json.encodeMaybe` encodes `Nothing` as `null`.
- Generation of enums as custom types, encoded by name and decoded by name
  or number through `Connect.Json.enum`, an unknown value reading as the
  zero value, with the `enums` conformance case. Enum values keep their
  declaration order in the IR; a negative value no longer drops its enum.
- The printer keeps an application's leading arguments on its first line
  when only the last argument spans lines.
- Generation of oneofs as custom types with an unset constructor, held in
  one record field at the oneof's declared position, with the `oneofs`
  conformance case. The runtime gains `Connect.Json.oneof`, `member` and
  `memberEither`.
- Generation of map fields as `Dict String V` (string and 64-bit integer
  keys) or `Dict Int V` (32-bit integer keys), with `Connect.Json.intDict`
  and the `maps` conformance case. A `bool` map key is the
  `types::map_key` diagnostic (`map_bool_key` case), the corpus's first
  diagnostics case.
- Generation of the well-known types of design section 3.5, with the
  `well_known` conformance case and the `any_field` diagnostics case. The
  runtime gains `Connect.Timestamp` (RFC 3339 to and from `Time.Posix`),
  `Connect.Duration` (an exact, opaque duration with proto3 JSON's
  `"1.5s"` form), and `Connect.Json` codecs for timestamps, durations,
  field masks and `Empty`; it now depends on elm/time.
- Generation of recursive messages: a field that closes a cycle of record
  fields holds the target's wrapper type (`type Node_ = Node_ Node`),
  decoded lazily, as are oneof members that close a cycle, with the
  `nesting` conformance case. Every construct of the type layer is now
  generated; nothing reports `generate::unimplemented`.
- The `packages` conformance case (qualified references to another
  generated package and its import), and diagnostics cases for a generate
  set that is not closed (`packages_not_generated`) and a package cycle
  (`packages_cycle`). A case may now hold an `include/` directory of protos
  that are imported but not generated. Rendered diagnostics carry no
  trailing whitespace.
- The `naming` conformance case (reserved-word fields and oneofs, a
  `json_name` override, enum values with and without the conventional
  prefix and with digits) and the `naming_collision` diagnostics case.
- CI compiles the runtime package and the conformance corpus with Elm
  0.19.0 and 0.19.1 as well (`conformance/compile-with.sh`,
  `just compile-with`).
