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
