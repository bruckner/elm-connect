# Oracle: the vendored protox and prost-reflect against buf and protoc

Run 1 of the editions spike, 2026-10-25, at the commit that adds this file.

## What was compared

Corpus, `spike/editions-corpus/` (all edition 2023):

| File | From |
|---|---|
| `test_messages_edition2023.proto` | protobuf v32.0, `conformance/test_protos/`, unmodified (file-level DELIMITED, groups as delimited fields, extensions, maps, a oneof) |
| `test_messages_proto3_editions.proto` | protobuf v32.0, `editions/golden/`, unmodified (proto3 semantics as edition 2023 features; imports six well-known types) |
| `notes/v1/notes.proto` | the notes example, translated by hand: `edition = "2023"`, `option features.field_presence = IMPLICIT`, and `optional int64 revision` as `int64 revision [features.field_presence = EXPLICIT]`; imports `google/api/annotations.proto` from `examples/notes/third_party/googleapis` |
| `matrix/v1/matrix.proto` | written for the spike: explicit, implicit and LEGACY_REQUIRED presence, defaults (scalar and closed enum), closed and open enums, packed and expanded encodings (file default EXPANDED, field PACKED), DELIMITED singular, repeated, oneof and extension fields, maps (one of a closed enum), UTF-8 validation NONE and VERIFY, json_format at file, message and enum, reserved names as identifiers, a service and a method |

The two protobuf files keep their license headers; the license is `spike/editions-corpus/LICENSE-protobuf`.

References: buf 1.73.0 (`mise exec -- buf build --exclude-source-info`, as mise.toml pins it) and
protoc 35.1 (`~/.local/share/mise/installs/protoc/35.1/bin/protoc`, already installed; not added to
mise.toml). `spike/run-oracle.sh OUT` (with `PROTOC` set) rebuilds both sets and runs the comparison.

Two comparisons per reference, by `spike/tools/compare-descriptors`:

1. Descriptors: each corpus file's `FileDescriptorProto` from the reference set and from the
   vendored protox (`Compiler::encode_file_descriptor_set`, imports included, no source info),
   both decoded with protobuf 32.0's `descriptor.proto` and compared as canonical JSON, every
   field (options and their `features` included). `source_code_info` is removed from both.
2. Features: a pool built by the vendored prost-reflect from the reference set
   (`DescriptorPool::decode`) against the pool protox built from its own parse, for every file,
   message, field, oneof, extension, enum, enum value, service and method: the resolved
   `Features`, and for fields `supports_presence`, `is_packed`, `is_group`, `cardinality` and the
   default value; for enums `is_closed`; for files `syntax` and `edition`.

A negative control (a copy of the corpus with one field's presence and the file's repeated
encoding changed, built with protoc) was reported as 2 descriptor and 41 feature differences, so
the comparison does see changes.

## Results

| File | Elements | buf: descriptor diffs | buf: feature diffs | protoc: descriptor diffs | protoc: feature diffs |
|---|---:|---:|---:|---:|---:|
| `test_messages_edition2023.proto` | 185 | 0 | 0 | 0 | 0 |
| `test_messages_proto3_editions.proto` | 237 | 0 | 0 | 0 | 0 |
| `notes/v1/notes.proto` | 51 | 0 | 0 | 0 | 0 |
| `matrix/v1/matrix.proto` | 43 | 0 | 0 | 0 | 0 |

No differences: protox's descriptors are buf's and protoc's field for field (including
`edition`, `syntax`, labels, the map entries' copied `features`, defaults and reserved names),
and the pool resolves the same features from buf's or protoc's bytes as from protox's parse.

One corpus change was needed: protoc refuses a map whose enum value type does not start at 0
("Enum value in map must define 0 as the first value", in every syntax), which buf accepts, so
the matrix's closed enum used as a map value starts at 0 and a second closed enum (`Sparse`)
covers a closed enum that does not.

## Invalid files

`spike/editions-invalid/` holds one rule per file; `run-oracle.sh` runs each through protoc, buf
and the vendored protox's binary:

| Case | protoc 35.1 | buf 1.73.0 | fork |
|---|---|---|---|
| `optional_label`, `required_label`, `group_field`, `reserved_string` | refused | refused | refused (parser) |
| `packed_option`, `features_in_proto3`, `feature_from_2024`, `unknown_feature_value`, `feature_target` | refused | refused | refused |
| `file_legacy_required`, `extension_required`, `oneof_field_presence`, `repeated_field_presence`, `message_implicit_presence` | refused | refused | refused |
| `implicit_closed_enum`, `open_enum_first_value`, `utf8_non_string`, `message_encoding_non_message` | refused | refused | refused |
| `implicit_default` (implicit presence with `default`) | refused | **accepted** | refused |
| `map_closed_enum_nonzero` (map of a closed enum not starting at 0) | refused | accepted | **accepted** |
| `json_name_conflict` (`foo` and `FOO`) | accepted | accepted | accepted |
| `edition_2024` | accepted | accepted | **refused** ("unknown edition '2024'") |

Differences and their reasons:

- `implicit_default`: buf 1.73.0 accepts a default on an implicit-presence field; protoc and the
  fork refuse it. The fork follows protoc.
- `map_closed_enum_nonzero`: protoc's map rule is not implemented in prost-reflect for any
  syntax (a proto2 map of such an enum is accepted today too). Not editions-specific; left out.
- `edition_2024`: deliberate. The spike supports edition 2023 only (operator decision); 2024
  needs `export`/`local`, `import option` and the naming-style and visibility features.
- The messages differ in wording (each tool has its own); every refusal is located at the
  construct protoc names (the fork's label points at the option value or keyword).

## Gaps the oracle does not cover

- Custom feature extensions (`features.(pb.cpp).…`): not in the corpus; the fork carries them in
  the options and resolves nothing from them.
- protoc's general option `targets` check for custom options; the fork checks the targets of the
  six edition 2023 features only.
- JSON names: protoc downgrades a JSON name conflict to a warning under `json_format =
  LEGACY_BEST_EFFORT`; prost-reflect refuses it in every syntax, as before. prost-reflect's
  proto3 camel-case check (`foo` against `FOO`) is stricter than protoc 35.1; editions files
  skip it.
- The binary and JSON codecs under these features are exercised by prost-reflect's tests
  (`editions_binary_encoding`, `editions_json_and_text_format`), not by the conformance runner;
  that is run 2.
