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

## Run 2: the plugin, driven by protoc and buf

`spike/run-plugin-oracle.sh OUT` (PROTOC set) runs the plugin under protoc 35.1
(`~/.local/share/mise/installs/protoc/35.1/bin/protoc`, its existing install, not
pinned in mise.toml) and buf 1.73.0 (pinned) over every `editions_*` corpus case and
`codec_both`, and diffs their output with the CLI's for the same protos and options
and with the case's expected modules (version placeholder put back). Result:

```
editions_2023_proto3_equivalent	20 modules	protoc=same buf=same expected=same 
editions_2024	diagnostics	expected= 1 input::editions;	cli= 1 input::editions;	protoc= 1 input::editions;	buf= 1 input::editions;
  protoc says: future.proto: is a file using edition 2024, which isn't supported by code generator protoc-gen-elm-connect.  Please ask the owner of this code generator to add support or switch back to a maximum of edition 2023.--elm-connect_out: input::editions
  buf says: Failure: plugin /Users/bruckhauser/Documents/elm-connect-wt/spike-editions/target/debug/protoc-gen-elm-connect: input::editions
editions_closed_enum	8 modules	protoc=same buf=same expected=same 
editions_defaults	3 modules	protoc=same buf=same expected=same 
editions_presence	5 modules	protoc=same buf=same expected=same 
editions_required	4 modules	protoc=same buf=same expected=same 
editions_unsupported	diagnostics	expected= 2 input::extensions; 7 input::unsupported_feature;	cli= 2 input::extensions; 7 input::unsupported_feature;	protoc= 2 input::extensions; 7 input::unsupported_feature;	buf= 2 input::extensions; 7 input::unsupported_feature;
  protoc says: --elm-connect_out: input::unsupported_feature
  buf says: Failure: plugin /Users/bruckhauser/Documents/elm-connect-wt/spike-editions/target/debug/protoc-gen-elm-connect: input::extensions
codec_both	20 modules	protoc=same buf=same expected=same 
```

Every modules case: the CLI, protoc and buf write the same files, equal to the
expected modules. Both diagnostics cases report the same codes from all three
front ends. On edition 2024, protoc refuses the file itself (the plugin claims
2023 at most) and still prints the plugin's answer; buf 1.73.0 sends the file
to the plugin anyway, so the plugin's own check of the request's edition is
what refuses it there.

The first run caught a corpus mistake: `editions_closed_enum` had a map whose
values were a closed enum starting at 1, which protoc refuses ("Enum value in
map must define 0 as the first value") and prost-reflect accepts in every
syntax (run 1's known gap). The case now uses a closed enum starting at 0 for
the map.

Run 1's descriptor oracle (`spike/run-oracle.sh`) was rerun after prost-types
was regenerated and the edition side channels removed: still 0 descriptor and
0 feature differences against buf 1.73.0 and protoc 35.1 on all four corpus
files, and the same invalid-file table.

## Run 3: edition 2024

`spike/run-oracle.sh OUT` now builds two corpora: the edition 2023 one above and
`spike/editions-corpus-2024/` (one module of its own, since its rewrites reuse the 2023 files'
package and message names). protoc runs with `--retain_options`: without it protoc strips
source-retention options from the set it writes, and edition 2024's `enforce_naming_style` and
`default_symbol_visibility` are source-retention features. The comparison now also covers each
file's option dependencies and each message's and enum's visibility keyword and resolved
visibility.

| File | From |
|---|---|
| `test_messages_proto3_editions.proto` | the v32.0 file with `edition = "2024"`, `option features.enforce_naming_style = STYLE_LEGACY;` (its JSON-name test fields break STYLE2024) and its four `ctype` options removed (2024 forbids `ctype`) |
| `test_messages_edition2023.proto` | the v32.0 file with `edition = "2024"`, `java_multiple_files` and its four `ctype` options removed |
| `vis/v1/defaults.proto` | EXPORT_TOP_LEVEL: top-level default export, nested default local, nested `export` message and enum, top-level `local` message and enum used in their own file |
| `vis/v1/strict.proto`, `vis/v1/local_all.proto` | STRICT (with the namespacing enum exception) and LOCAL_ALL (with nested exports) |
| `vis/v1/legacy.proto` | an edition 2023 file whose nested types a 2024 file uses |
| `vis/v1/use.proto` | uses every exported symbol of the four, as field types and method types |
| `opt/v1/options.proto`, `opt/v1/use.proto` | custom field and message options used through `import option` |
| `naming/v1/naming.proto` | STYLE2024 names with digits, a map, a oneof, a nested enum, and a message that opts out with STYLE_LEGACY |

protoc 35.1 and buf 1.73.0 accept every file. Without the opt-out, the rewrite of
`test_messages_proto3_editions.proto` is refused by the fork with the same 19 naming errors as
protoc, text for text (15 fields, 4 enum values).

| Reference | Descriptor diffs | Feature diffs |
|---|---:|---:|
| protoc 35.1 (`--retain_options`) vs fork, 10 files, 518 elements | 0 | 0 |
| buf 1.73.0 vs fork | 1 | 1 |

The one buf difference is buf's: buf 1.73.0 leaves `option_dependency` out of the descriptors
it writes (`opt/v1/use.proto` has no `optionDependency` in buf's image, and so no option
dependencies in a pool built from it); protoc writes it, and the fork matches protoc.

Without `--retain_options`, protoc's set differs from the fork's by the stripped features (4
files), and a pool built from it would refuse `test_messages_proto3_editions.proto` if it checked
names, because the opt-out is gone. That is why prost-reflect checks names only when a pool asks
(`DescriptorPool::enforce_naming_style`, which protox's compiler turns on), as protoc's C++
`DescriptorPool` does: the same stripping applies to the `proto_file`s protoc sends a plugin.

### Invalid files, edition 2024

`spike/editions-invalid/` gained 25 cases (`deps/` holds the files they import; buf builds each
case with `deps/`):

| Case | protoc 35.1 | buf 1.73.0 | fork |
|---|---|---|---|
| `vis_local_explicit`, `vis_nested_default`, `vis_local_all_method`, `vis_extendee_local` (field type, method type, extendee not visible) | refused | refused | refused |
| `vis_strict_nested_message`, `vis_strict_nested_enum` | refused | refused (as "does not reserve all field numbers") | refused |
| `vis_modifier_on_service`, `vis_modifier_in_2023`, `vis_feature_on_message` | refused | refused | refused (parser for the first two) |
| `option_import_type`, `option_import_in_2023`, `option_import_order` | refused | refused | refused |
| `weak_import_2024`, `ctype_2024`, `java_multiple_files_2024` | refused | refused | refused |
| `naming_package`, `naming_message`, `naming_field`, `naming_field_digit_underscore`, `naming_oneof`, `naming_enum`, `naming_enum_value`, `naming_enum_value_trailing_underscore`, `naming_service`, `naming_method` | refused | refused | refused |
| `edition_2024` (run 1's refusal) | accepted | accepted | **accepted** now |

The fork's naming and visibility messages are protoc's texts (one doubled space and protoc's
quoting of the feature value tidied); the rest keep the fork's wording. Run 1's three
differences (`implicit_default`, `map_closed_enum_nonzero`, `json_name_conflict`) are unchanged.
The 2023 corpus still shows 0 and 0 against both references.

### Run 3: the plugin on edition 2024

`spike/run-plugin-oracle.sh` now also passes a case's `include/` (as `-I` to the CLI and
protoc; to buf as module files, generating only the input with `--path`). Result:

```
editions_2023_proto3_equivalent	20 modules	protoc=same buf=same expected=same 
editions_2024_naming	diagnostics	expected= 6 input::naming_style;	cli= 6 input::naming_style;	protoc=	buf=
  protoc says: naming.proto:6:9: Message name user_profile should be TitleCase (features.enforce_naming_style = STYLE_LEGACY can be used to opt out of this check)
  buf says: naming.proto:6:9:message type name should be PascalCase
editions_2024_option_import	2 modules	protoc=same buf=DIFFERS expected=same 
editions_2024_proto3_equivalent	20 modules	protoc=same buf=same expected=same 
editions_2024_visibility	8 modules	protoc=same buf=same expected=same 
editions_closed_enum	8 modules	protoc=same buf=same expected=same 
editions_defaults	3 modules	protoc=same buf=same expected=same 
editions_expanded	3 modules	protoc=same buf=same expected=same 
editions_presence	5 modules	protoc=same buf=same expected=same 
editions_required	4 modules	protoc=same buf=same expected=same 
editions_unknown	diagnostics	expected= 1 input::editions;	cli= 1 input::editions;	protoc=	buf=
  protoc says: future.proto:2:11: Unknown edition "2025".
  buf says: future.proto:2:11:unrecognized `edition` declaration value
editions_unsupported	diagnostics	expected= 2 input::extensions; 6 input::unsupported_feature;	cli= 2 input::extensions; 6 input::unsupported_feature;	protoc= 2 input::extensions; 6 input::unsupported_feature;	buf= 2 input::extensions; 6 input::unsupported_feature;
  protoc says: --elm-connect_out: input::unsupported_feature
  buf says: Failure: plugin <root>/target/debug/protoc-gen-elm-connect: input::extensions
codec_both	20 modules	protoc=same buf=same expected=same 
```

(`editions_expanded`, EXPANDED under `codec=both`, and `editions_unsupported` without its
EXPANDED problem, are from the EXPANDED lift.) Every edition 2024 modules case but one: the CLI, protoc and buf write the same files, equal
to the expected modules; both twins equal `codec_both`. `editions_2024_option_import` under
buf differs in one line: buf 1.73.0 does not send a plugin the file named by `import option`
(the request's `forms.proto` lists it in `option_dependency`, but `proto_file` lacks it), so
the plugin cannot name the custom option, and the field's one-line declaration in its doc
comment leaves `[(labels.v1.display) = "Title"]` out; the generated code is otherwise the same.
protoc sends the file, and matches the CLI. The first run of this case failed outright under
buf ("imported file 'labels.proto' has not been added"): prost-reflect now leaves out a missing
option dependency, as protoc's descriptor pool does, rather than refusing the file.

On `editions_2024_naming` and `editions_unknown`, protoc and buf refuse the file themselves,
before the plugin runs (their first lines above), and the CLI reports `input::naming_style`
and `input::editions` in their place. The plugin's own corpus replay skips those two cases.
