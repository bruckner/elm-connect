# Sizing: editions 2023 in protox 0.10.0 and prost-reflect 0.16.5

Read from the pinned crates.io sources (`~/.cargo/registry/src/*/protox-0.10.0`,
`protox-parse-0.10.0`, `prost-reflect-0.16.5`) and, for reference behaviour, protobuf v32.0
(`src/google/protobuf/descriptor.proto`, `feature_resolver.cc`, `descriptor.cc`,
`compiler/parser.cc`, fetched read-only into the gitignored `spike/ref/`) and the editions
overview at protobuf.dev/editions.

## A constraint found first: prost-types has no editions fields

prost-types 0.14.4 (the newest release) is generated from a `descriptor.proto` that predates
editions: `FileDescriptorProto` has no `edition` (field 14), and no `*Options` message has
`features`. prost decodes unknown fields by dropping them. So:

- Anything that passes a file through `prost_types::FileDescriptorProto` loses its edition.
  That is protox-parse's public output type, `DescriptorPool::add_file_descriptor_proto`'s
  input, `FileDescriptor::file_descriptor_proto()`'s output, protox's
  `Compiler::file_descriptor_set()`, and protox's `GoogleFileResolver`.
- prost-reflect already carries its own crate-private copies of the descriptor messages
  (`descriptor/types.rs`) with options kept as encoded bytes, which is why custom options
  survive. Adding `edition` to its private `FileDescriptorProto` makes the edition survive
  every byte path (`decode_file_descriptor_proto`, `decode_file_descriptor_set`,
  `encode_to_vec`). Features already survive inside the encoded options.
- protox must therefore hand prost-reflect *bytes* for a parsed editions file, not a
  `prost_types` value. protox's `File` already has an `encoded: Option<Bytes>` slot that
  `Compiler::check_file` prefers (it is how a precompiled descriptor set is fed in), so the
  route exists.

This is not a blocker for the forks (no third fork is needed), but it shapes both APIs, and an
upstream solution would eventually want prost-types regenerated (a prost change, out of reach
of this spike).

## prost-reflect 0.16.5

| Where | What changes | Est. lines |
|---|---|---|
| `descriptor/mod.rs` | `Syntax::Editions`; a public `Edition` enum; a resolved `Features` value (six core features, typed enums) stored on every `*Inner` (file, message, field, oneof, extension, enum, enum value, service, method); `edition` on `FileDescriptorInner` | 120 |
| `descriptor/types.rs` | `edition: Option<i32>` (tag 14) on the private `FileDescriptorProto`; `from_prost`/`to_prost` leave it alone (prost-types cannot hold it) | 10 |
| `descriptor/build/names.rs` `visit_file` | accept `syntax = "editions"`; require a known `edition` (2023); error for other editions | 40 |
| `descriptor/build/names.rs` `visit_message`, `visit_enum` | the camel-case JSON name check and the first-enum-value-zero check are syntax-based today; for editions files they depend on resolved features (`json_format`, `enum_type`), which only exist after options are interpreted, so they move to a new pass for editions files (proto2/proto3 behaviour unchanged) | 30 |
| new `descriptor/build/features.rs` | feature resolution after `resolve_options`: per-edition defaults (2023 and the legacy PROTO2/PROTO3 rows), merge file → message → (field / oneof → field / enum → value / extension by scope), service → method; legacy inference for proto2/proto3 (required → LEGACY_REQUIRED, group → DELIMITED, `packed` → encoding) so the accessors answer for every file; recompute `cardinality`, `supports_presence`, `is_packed` and the group kind for editions fields; validation (below) | 450 |
| `descriptor/build/mod.rs` | call the features pass after `resolve_options` | 5 |
| `descriptor/build/resolve.rs` `visit_field`, `visit_extension` | leave the syntax-based computations for legacy files; editions files get theirs from the features pass | 10 |
| `descriptor/api.rs` | `FileDescriptor::edition()`, `features()` on each descriptor, `EnumDescriptor::is_closed()`, docs of `supports_presence`/`is_packed`/`is_group`/`cardinality` updated for editions | 150 |
| `descriptor/error.rs` | new error kinds: unknown edition, editions file without an edition, feature errors (with labels at the `features` option path) | 120 |
| `dynamic/*`, `dynamic/serde/*` | none expected: the binary codec asks `is_packed`, `is_group`, `supports_presence`; serde asks `supports_presence`/`has`. Checked by tests rather than edits. Text format names a field by its type name when `is_group()`; a DELIMITED field that is not group-like (name ≠ lowercased type name) must keep its field name (protoc's `IsGroupLike`) | 20 |
| tests (`descriptor/tests.rs` style, `tests/data/*.yml` + snapshots style) | resolution and inheritance at each level, each validation, each API, codec round trips (packed/expanded, delimited, presence) | 450 |

Validation to port (protobuf `descriptor.cc` `ValidateFileFeatures`, `ValidateFieldFeatures`,
`ValidateOptions(EnumDescriptor)`, `ResolveFeaturesImpl`; `feature_resolver.cc`
`ValidateMergedFeatures`, `ValidateFeatureLifetimes`):
- features set in a proto2/proto3 file ("Features are only valid under editions");
- a feature set to its `*_UNKNOWN` value or an unknown number; a feature introduced after the
  file's edition (`enforce_naming_style`, `default_symbol_visibility` in a 2023 file);
- file-level `field_presence = LEGACY_REQUIRED`;
- `LABEL_REQUIRED`, `TYPE_GROUP`, or the `packed` option in an editions file;
- implicit presence with a default; implicit presence on a closed enum field; required extension;
- `field_presence` on a oneof member, a repeated field, an extension (except LEGACY_REQUIRED),
  or IMPLICIT on a message field; `repeated_field_encoding` on a singular field; PACKED on a
  non-packable field; `utf8_validation` on a non-string (map with a string key/value allowed);
  `message_encoding` on a non-message or map field;
- the first value of an open enum must be 0; JSON name conflicts are errors when the message's
  `json_format` is ALLOW.
- DELIMITED is not applied to map fields or the fields of map entries (`PostProcessFieldFeatures`).

Custom feature extensions (`pb.cpp`, `pb.java`, …): carried in the encoded options and ignored
by resolution; the `pb.*` files are not bundled, so a file that sets them must import them.

## protox-parse 0.10.0

| Where | What changes | Est. lines |
|---|---|---|
| `ast/mod.rs` | `Syntax::Editions` carrying the edition; `File` keeps it | 20 |
| `parse/mod.rs` `parse_file`, `parse_syntax` | accept `edition = "2023";` as the first statement (an identifier token, so no lexer change); unknown edition is an error naming it (protoc: `Unknown edition "…"`) | 50 |
| `generate/mod.rs` `generate_file_descriptor` | `syntax = "editions"`; the edition recorded | 15 |
| `generate/mod.rs` `generate_field_descriptor`, `generate_field_label` | editions rules: no `optional`/`required` labels, no `group`; defaults allowed (feature validation lives in the pool); no `proto3_optional`; map entries get the map field's `features.*` options copied onto key and value (protoc `GenerateMapEntry`) | 60 |
| `parse/mod.rs` `parse_reserved` | editions reserve names as identifiers, not strings; proto2/proto3 the reverse (protoc `ParseReserved`) | 30 |
| `error.rs` | new kinds: unknown edition, label/group not allowed in editions, reserved name form | 50 |
| `lib.rs` | carry the edition out (see the constraint above): the parsed file is returned with its edition, and an encoding that includes field 14 | 40 |
| tests (`tests.rs`, `parse/tests.rs` style with insta snapshots) | each rule above | 200 |

## protox 0.10.0

| Where | What changes | Est. lines |
|---|---|---|
| `file/mod.rs` `File::from_source` | when the parsed file has an edition, set `encoded` to the encoding with the edition so `check_file` decodes it into the pool | 20 |
| `compile/mod.rs` `file_descriptor_set` | docs: prost-types drops the edition; `encode_file_descriptor_set` keeps it | 10 |
| tests (`tests/compiler.rs`, `src/compile/tests.rs` style) | an editions file compiles, round-trips through `encode_file_descriptor_set`, features resolve through `descriptor_pool()` | 120 |

## Totals and what has to be consulted

prost-reflect ≈ 950 lines of code + ≈ 450 of tests; protox-parse ≈ 265 + 200; protox ≈ 30 + 120.
The reference behaviour to consult while writing: `descriptor.cc` lines 1396–1454
(`GetParentFeatures`), 4235–4270 (feature-derived accessors), 5961–6030 (`ResolveFeaturesImpl`),
6030–6060 (`PostProcessFieldFeatures`), 8792–8910 (validation); `feature_resolver.cc` 335–420;
`parser.cc` 646–690 (edition statement), 1166–1215 (map entry features), 1745–1800 (reserved),
2385–2430 (labels, groups); `descriptor.proto` 1012–1199 (`FeatureSet` and its
`edition_defaults`).

Upstream tests in the published crates: prost-reflect ships `src/descriptor/tests.rs`, the
YAML-driven `tests/main.rs` and unit tests across `dynamic/`; its conformance and proptest
suites live in other workspace crates not on crates.io. protox ships `tests/compiler.rs`,
`tests/wkt.rs`, `tests/compare.rs` (needs the protobuf git submodule under `tests/protobuf`,
absent from the package) and `src/*/tests.rs`. protox-parse ships its unit and snapshot tests.
The baseline run in step 2 records which of these pass on the pristine copies.
