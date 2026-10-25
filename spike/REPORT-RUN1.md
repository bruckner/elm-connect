# Editions spike, run 1: report

**Answer:** Yes. With vendored forks of protox-parse/protox 0.10.0 and prost-reflect 0.16.5, edition 2023 files parse, compile and resolve their features. The descriptors match buf 1.73.0 and protoc 35.1 field for field on a 4-file edition-2023 corpus, and the resolved features match on all 516 elements. No blocker. One thing outside the two forks pushes back: prost-types (see "Where upstream resisted"); the forks work around it without a third fork.

Branch `spike/editions` HEAD f2743ef (history rewritten once with force-with-lease to fold a clippy fix into the CLI commit). No PR, nothing merged.

## Commits (from dfe7d38)
1. 3764ac1 Size editions support in protox and prost-reflect (`spike/SIZING.md`)
2. 0e0e81e Vendor protox 0.10.0 and prost-reflect 0.16.5 unmodified (from the `.crate` files; SHA-256 matches Cargo.lock)
3. e3e24a2 Patch protox and prost-reflect to the vendored copies (`[patch.crates-io]`, `exclude = ["vendor"]`, `vendor/Cargo.toml` test workspace, THIRD_PARTY.md)
4. d5aeb1d Restore protox-parse's upstream test snapshots (242 `.snap` files the package does not ship, from upstream 847875cd)
5. cd29eea Add a generator for prost-reflect's descriptor.proto (`spike/tools/wkt-descriptor`)
6. 766dc14 Update the embedded descriptor.proto to protobuf 32.0 (prost-reflect)
7. 7d3958f Support protobuf editions (edition 2023) (prost-reflect)
8. 4ccd9e4 Parse edition 2023 files (protox-parse)
9. df8a6b6 Compile edition 2023 files (protox)
10. 04636c7 Refuse compiled editions files in the CLI (elm-connect; docs updated)
11. 9e3c4e0 Check the targets of feature options (prost-reflect)
12. 09c1981 Match protoc's JSON name check in editions files (prost-reflect)
13. 829416f Compare the forks' descriptors with buf and protoc (corpus, invalid cases, `spike/ORACLE.md`, `spike/NOTES.md`, `spike/run-oracle.sh`, `spike/tools/compare-descriptors`)
14. f2743ef Record the protobuf test protos in THIRD_PARTY.md

## Sizing (estimate → actual)
| Crate | Code est. | Tests est. | Actual code | Actual tests |
|---|---|---|---|---|
| prost-reflect | ~950 | ~450 | +1313/−37 hand-written in 13 files, plus wkt.rs regenerated (+487/−175) | +1145 in 47 files (YAML data, snapshots, 5 API/codec tests) |
| protox-parse | ~265 | ~200 | +205/−18 | +137 tests, plus a 493-line debug snapshot |
| protox | ~30 | ~120 | +25/−4 | +90 |

## `git diff --stat` against pristine 0e0e81e
- **prost-reflect src:** api.rs +114; build/features.rs +733 (new); build/mod.rs +3; build/names.rs 70; build/resolve.rs +5; error.rs 36; features.rs +331 (new); mod.rs +18; tag.rs +13; types.rs +14; text_format/format.rs 2; text_format/parse/mod.rs 4; lib.rs 7; reflect/wkt.rs +487/−175. 14 files, +1800/−212.
- **prost-reflect tests:** 47 files, +1145/−1.
- **protox-parse** (from d5aeb1d, snapshots excluded): ast 3, error.rs 32, generate/mod.rs 84, lex 1, lib.rs 32, parse/mod.rs 53, tests.rs 137, one new snapshot 493. 8 files, +817/−18. (Snapshot restore: 242 files, +13217.)
- **protox:** compile/mod.rs 4, file/mod.rs 25, tests/compiler.rs 76, one snapshot 14. 4 files, +115/−4.

## Oracle (`spike/ORACLE.md`)
**Corpus:** `test_messages_edition2023.proto` and `test_messages_proto3_editions.proto` (protobuf v32.0); the notes example translated by hand to edition 2023 (file-level IMPLICIT, the `optional` field EXPLICIT); a feature matrix: explicit/implicit/LEGACY_REQUIRED presence, defaults, closed and open enums, packed and expanded, delimited singular/repeated/oneof/extension, maps, utf8 NONE/VERIFY, json_format, reserved identifiers, a service and a method.

| | Descriptor diffs | Feature diffs |
|---|---|---|
| buf 1.73.0 vs fork | 0 | 0 |
| protoc 35.1 vs fork | 0 | 0 |

Element counts per file 185, 237, 51, 43. A pool built from buf's or protoc's bytes resolves the same features as one built from protox's own parse. Negative control (two features mutated) caught: 2 descriptor diffs, 41 feature diffs. protoc 35.1 from its existing install path, not pinned, not in mise.toml. One corpus adjustment: protoc refuses a map whose enum values do not start at 0; buf accepts it.

**Invalid-file table (`spike/editions-invalid/`, 22 cases):** the fork refuses everything protoc refuses, with three exceptions: `implicit_default` (buf accepts; protoc and fork refuse); `map_closed_enum_nonzero` (protoc refuses; buf and fork accept; prost-reflect lacks this rule in every syntax, not editions-specific); `edition = "2024"` (protoc and buf accept; fork refuses by design). `foo`/`FOO` field names accepted by all three after commit 12.

## Where upstream resisted
- **prost-types 0.14.4 (newest) has no `FileDescriptorProto.edition` and no `features` on any options message.** prost drops unknown fields, so anything through a `prost_types` value loses the edition: `parse`, `add_file_descriptor_proto`, `file_descriptor_proto()`, `Compiler::file_descriptor_set()`, `GoogleFileResolver`. Workaround: the edition rides in prost-reflect's private descriptor types; protox passes editions files to the pool as bytes (`File::encoded`); protox-parse gains `parse_with_edition`. For run 2: prost-types' `CodeGeneratorResponse` has no `minimum_edition`/`maximum_edition` and no FEATURE_SUPPORTS_EDITIONS value, so the plugin must append those fields as raw bytes.
- **prost-reflect embedded a descriptor.proto older than protobuf 26:** `Utf8Validation.NONE` is 1 there, 3 in protoc; no EDITION_2024 or 2024 features. Upstream's tool for `wkt.rs` is unpublished; a generator was written; the regenerated literal is rustfmt-clean.
- **Upstream's `UnknownSyntax` path built its error label before the file was in the pool** → the #203 panic. Fixed in the editions commit; overlaps the operator's PR #204.
- **`Syntax::Editions` is a new variant on an exhaustive public enum:** semver-breaking for prost-reflect (0.17).
- Smaller: prost-reflect's proto3 camel-case check is stricter than current protoc; it refuses JSON-name conflicts protoc only warns about under LEGACY_BEST_EFFORT. Pre-existing, left.

## Gates
Passing: fmt-check, clippy, test (all workspace tests), elm-check, snippets, changelog-check, zizmor, gitleaks, license. `deny` passes with `deny.toml` unchanged (path patches are not git sources). `package` **fails as predicted:** verification builds against crates.io prost-reflect, which has no `Syntax::Editions`, so commit 10 does not compile there.

Vendored suites green except two failures present on the pristine copies: prost-reflect's `lib.rs:77` doctest needs `prost-reflect-build` (not on crates.io); 26 of protox's `tests/compare.rs` need the protobuf git submodule (other 19 pass with `PROTOC` set). Two pre-existing upstream clippy warnings in protox (`io_other_error`).

## Not done
Edition 2024; feature extensions (carried, not resolved); protoc's target check for custom options generally (only the six 2023 features); the map-enum-starts-at-0 rule; unknown closed-enum values to unknown fields and `utf8_validation = NONE` not stopping prost's UTF-8 rejection (both as before); any generator mapping or plugin edition claim (the CLI keeps refusing editions files); the conformance runner (codecs covered by prost-reflect unit tests only); no changelog fragment.

## Estimate for run 2
One full Opus run comparable to this one: ~1.5–2.5K lines of generator, plugin and diagnostics code plus corpus cases and expected output. Risks: `test_messages_edition2023.proto` uses delimited fields and extensions, which run 2's scope refuses, so the whole file would be refused — conformance on it needs a subset or DELIMITED support; the plugin must read the edition from raw bytes and write the response's edition fields by hand; the pre-1.0 reservations (diagnostic codes, whether `check` records the edition) are open.

## Draft upstream PR descriptions
**1. prost-reflect: "Update the embedded descriptor.proto to protobuf 32.0".** The descriptor.proto embedded for the global pool predates protobuf 26. Since then `FeatureSet.Utf8Validation.NONE` moved from 1 to 3, and Edition, FeatureSet and the options gained edition 2024's values and fields. Option resolution falls back to the embedded file, so `features.utf8_validation = NONE` resolved to a value protoc rejects. The literal in `src/reflect/wkt.rs` is regenerated from v32.0 in the existing style; other well-known types unchanged; options prost-types does not model are still dropped; the private `FileDescriptorProto` gains `edition` (field 14) so an edition survives decode and re-encode (`from_prost` leaves it unset). Generated with protoc 35.1 and a small printer; can be added to the repo.

**2. prost-reflect: "Support protobuf editions (edition 2023)".** Accepts `syntax = "editions"` with EDITION_2023 and resolves features as protoc does: edition defaults (PROTO2, PROTO3, 2023 rows of v32's `FeatureSet` as a table, tested against the embedded file); inheritance file → message → oneof → field, enum → value, extensions from their declaring scope, file → service → method; for proto2/proto3, protoc's inference (`required` → LEGACY_REQUIRED, groups → DELIMITED, `packed`). New API: `Syntax::Editions`, `Edition`, `FileDescriptor::edition()`, `Features` with typed enums, `features()` on every descriptor, `EnumDescriptor::is_closed()`. For editions files `supports_presence`, `is_packed`, `is_group`, `cardinality`/`is_required` follow the features, so the binary and JSON codecs need no changes; text format names a delimited field by its type only when it looks like a group. Validation ports descriptor.cc and feature_resolver.cc (features outside editions; unknown values; 2024-only features; feature targets; required presence at file level; `required` labels, groups and `packed` in editions files; defaults and closed enums on implicit fields; required extensions; field_presence on oneof members/repeated/extensions and IMPLICIT on message fields; encoding/utf8/message_encoding where inapplicable; an open enum's first value must be 0). Editions files skip the proto3 camel-case check, matching protoc. Unknown syntax and edition errors are reported after the file is in the pool, fixing the label panic (#204). Breaking: `Syntax` gains a variant. Not included: feature extensions, edition 2024, editions descriptors passed as `prost_types` values. Tests: YAML cases with snapshots per rule, plus resolution, binary, JSON and text-format tests; checked against buf 1.73.0 and protoc 35.1 on protobuf's editions conformance protos with no differences.

**3. protox: "Parse and compile edition 2023 files".** protox-parse: accepts `edition = "2023";` producing `syntax = "editions"`; editions parser rules (no `optional`/`required` labels, no groups, reserved names as identifiers, defaults allowed, no synthetic oneofs); copies a map field's `features.*` onto its entry's key and value fields as protoc does; any other edition is "unknown edition"; `parse_with_edition` returns the edition prost_types cannot carry. protox: `File::open`/`from_source` hand an editions file to the pool as bytes including field 14; `encode_file_descriptor_set` and `descriptor_pool` keep the edition; `file_descriptor_set` documents that it loses it. Depends on the prost-reflect editions PR. Output matches buf 1.73.0 and protoc 35.1 field for field.

## Notes
One deny log was briefly written to `~/Documents/elm-connect-wt/` and moved to the scratchpad. `vendor/target` and `spike/tools/*/target` are gitignored and left in place; ~22 GB free at the end.
