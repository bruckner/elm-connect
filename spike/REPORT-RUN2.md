# Editions spike, run 2: report

**Answer:** Yes. Edition 2023 files now generate from both binaries. Explicit presence, IMPLICIT, LEGACY_REQUIRED, closed enums and declared defaults are mapped; everything else in scope is refused, each refusal naming the feature, the element and the scope it is inherited from. A file whose features only restate proto3 generates byte-identical output to its proto3 twin. The CLI, protoc 35.1 and buf 1.73.0 produce the same files for every editions case. No blocker. The mid-run scope change was taken: prost-types is vendored and regenerated, so no raw-byte workaround was built.

Branch `spike/editions`, HEAD 2ffd375. No PR, nothing merged.

## Commits (from 47b4e4e)
1. 361b64a Merge the binary codec spike into the editions spike (`git merge origin/spike/binary-codec`; only the spikes' notes conflicted → `spike/BINARY-NOTES.md`, `spike/BINARY-REPORT-RUN1.md`; binary legs ran).
2. c330a9d Vendor prost-types 0.14.4 unmodified (SHA-256 `f94967dc…` matches Cargo.lock; upstream 13646cde).
3. 1a768d3 Patch prost-types to the vendored copy (`[patch.crates-io]`, vendor workspace member, THIRD_PARTY.md; deny unchanged).
4. 17e074a Regenerate prost-types from protobuf 32.0 (prost-build 0.14.4, protoc 35.1; tool `spike/tools/prost-types-gen`).
5. ac67076 Carry the edition in prost_types descriptors (prost-reflect, protox-parse, protox).
6. 9f946b7 Generate from edition 2023 files (generator, runtime, corpus, docs).
7. 095e732 Generate edition 2023 files from the CLI.
8. cffc659 Claim edition 2023 in the plugin.
9. 4a9d007 Run the suites on edition 2023.
10. 2ffd375 Argue the forks' maintenance posture (`spike/POSTURE.md`).

Commits 6 and 7 fail the plugin's corpus replay test (the plugin claimed editions only at 8); nothing was pushed until 8 was in.

## What generates and what is refused
**Generated:** explicit presence on a scalar or enum outside a oneof → `CardinalityOptional` / `Maybe` (as proto3 `optional`); IMPLICIT → plain value. LEGACY_REQUIRED → `CardinalityRequired`, still a `Maybe` with an optional field's codecs (a missing required field decodes as `Nothing`). Closed enums: descriptor `|> Proto.Enum.withClosed`; JSON decoder `Proto.Json.closedEnum` fails on an unknown number as well as an unknown name; under `enum_unknown=zero` both read as the first value. Declared defaults: `|> Proto.Field.withDefault "5"` on the descriptor, the text as the proto writes it; the field stays a `Maybe`. Doc declarations write presence as a label and omit `features`; the package comment is read from the edition statement (protoc path 14, protox 12). EXPANDED under `codec=json` accepted.

**Refused:** `input::unsupported_feature` for `message_encoding = DELIMITED` (map entries exempt, as protoc), `utf8_validation = NONE`, `json_format = LEGACY_BEST_EFFORT` on a message or enum, and under `codec=binary|both` only `repeated_field_encoding = EXPANDED` and `enum_type = CLOSED` (binary decoders cannot treat an unknown number as an unknown field). `input::extensions` for extension ranges and extensions of messages outside `google.protobuf` (custom options and features fine). `input::editions` for 2024 or unknown; help says what is supported.

Sample (`editions_presence`):
```elm
type alias Note =
    { title : Maybe String      -- explicit, the 2023 default
    , stars : Maybe Int
    , shade : Maybe Shade
    , body : String             -- [features.field_presence = IMPLICIT]
    , author : Maybe Author
    , tags : List String
    , counts : Dict String Int
    , kind : NoteKind
    }
```
Sample diagnostic:
```
input::unsupported_feature
  × The field `unsupported.v1.Envelope.body` has `features.message_encoding =
  │ DELIMITED`, inherited from the file, which elm-connect does not generate.
```
The whole `test_messages_edition2023.proto` through the CLI: under `codec=both` 20 problems (16 `unsupported_feature`: 2 DELIMITED, 14 EXPANDED; 4 `extensions`); under `codec=json` 6.

**New corpus cases:** `editions_2023_proto3_equivalent` (codec_both's inputs through `spike/editions-twin.sh`), `editions_presence` (2 files), `editions_closed_enum` (2 packages), `editions_defaults`, `editions_required`, `editions_unsupported` (codec=both, 9 problems), `editions_2024` (reported as the CLI does on a protox parse error, via new library helper `unsupported_edition`). Plugin replay skips only `editions_2024` (protoc never sends it).

## Twin-output proof
- `editions_2023_proto3_equivalent/expected` equals `codec_both/expected` byte for byte: 20 modules, JSON and binary codecs, descriptors and docs; `diff -r` empty; test `the_proto3_equivalent_edition_generates_its_twin`.
- CLI test `the_proto3_twin_of_a_tree_is_current`: `check` sees no drift between a tree from the proto3 file and its twin.
- Notes example's edition 2023 translation (`spike/run-notes-twin.sh`): through the plugin under buf, 39 modules identical to `examples/notes/elm/generated`; through the CLI, 11 modules identical.

## Plugin and oracle
- Every response, errors included, sets `PROTO3_OPTIONAL | FEATURE_SUPPORTS_EDITIONS`, `minimum_edition = maximum_edition = EDITION_2023`, as ordinary struct fields (regenerated prost-types); the raw-byte version was discarded unbuilt. The edition check reads each file's edition from the decoded request. The pool is still built from the raw `proto_file` bytes because prost drops extension options (`google.api.http`).
- Oracle (`spike/run-plugin-oracle.sh`, `spike/ORACLE.md`): protoc 35.1 at `~/.local/share/mise/installs/protoc/35.1/bin/protoc` (not pinned), buf 1.73.0. For every editions modules case and codec_both, CLI, protoc and buf write identical files equal to expected. Both diagnostics cases report the same codes from all three. On edition 2024 protoc refuses the file itself; buf 1.73.0 sends it to the plugin anyway, so the plugin's own check is what refuses it there. First oracle run caught a corpus mistake (map of a closed enum whose first value isn't 0: protoc refuses; prost-reflect lacks the rule); fixed. Run 1's descriptor oracle rerun: still 0/0 differences.

## Conformance
Runner v32.0-rc2, `--enforce_recommended --maximum_edition 2023`, testee `codec=both`; full tally `spike/protobuf-conformance/tally-editions.md`; passes against the classified failure list.

| Message | Cases | Passed | Failed |
|---|---|---|---|
| Proto3 (regression baseline, unchanged from the binary spike) | 1468 | 1413 | 55 |
| Editions_Proto3 (proto3's message in edition 2023, subset) | 1468 | 1382 | 86 |
| TestAllTypesEdition2023 (subset) | 14 | 8 | 6 |

The runner exercises only 14 cases on TestAllTypesEdition2023, so proto3's message in edition 2023 was added as a second target. Its 86 failures: 55 are the twins of the 55 proto3 failures (same causes; no proto3 failure passes in the twin); 31 set an EXPANDED field the subset drops (28 `UnpackedOutput`, 3 oneof `MESSAGE.Merge` setting `corecursive.unpacked_int32`), classified unsupported. The 6 TestAllTypesEdition2023 failures set a delimited field or extension the subset drops.

Subsets (`strip-editions.sh`): from test_messages_edition2023, fields 201/202, extension range 120–200, extensions 120–122, `unpacked_*` 89–102; from test_messages_proto3_editions, `unpacked_*` 89–102 and the two NullValue fields.

**Connect live suite** (`just live`, proto3): passes, no drift; conformance 40/40 and 39/40 + 1 known. **Notes twin:** identical.

## Posture verdict (`spike/POSTURE.md`)
Rebase trial onto upstream heads in scratch clones: protox `main` and prost-reflect `main` no-op (both mains are the release commits); prost `master` (6 commits past release) clean; prost-reflect PR #204: 3 hunks in `build/names.rs` resolved by taking the fork's side, plus one semantic conflict (#204's test asserts EDITION_2023 is refused), suite passes after; prost PR #1347: 4 hunks in `protobuf.rs`, resolved by regenerating. Upstream churn in touched files: prost-reflect 0.16.0→0.16.5 +130/−72; protox 0.9→0.10 +63/−7. A rebase per upstream release costs minutes to an hour.

For `cargo install elm-connect` and the release: (c) vendoring and (d) git dependency cannot publish (`[patch]` and git deps don't reach crates.io; the release `verify` job runs the same `cargo package` that fails here; (d) also needs deny relaxed and public forks). (b) forks under our own names publishes immediately but means four crates to own indefinitely.

**Recommendation: (a) upstream first, with prost-types off the critical path.** Send the prost-reflect and protox PRs in run 1's shape (no prost-types change needed). Offer the prost-types regeneration separately as a slice of prost PR #1347. Keep editions off `main` until prost-reflect and protox release. Fall back to (b) only if a release needs editions before upstream acts. Semver: prost-reflect → 0.17 (`Syntax::Editions`); prost-types → 0.15 (new fields; `php_generic_services` removed); protox → 0.11.

## Draft upstream PR descriptions
1. **prost-reflect: "Update the embedded descriptor.proto to protobuf 32.0"** (as run 1; wkt.rs now also fills prost-types' new option fields with defaults).
2. **prost-reflect: "Support protobuf editions (edition 2023)"** (as run 1; plus: with regenerated prost-types, `from_prost`/`to_prost` carry the edition so pools from prost-types values and `file_descriptor_proto()` keep it; overlaps #204, whose test must move to 2024 or unknown syntax; against stock prost-types, run 1's private-field shape stands).
3. **protox: "Parse and compile edition 2023 files"** (with regenerated prost-types, `parse` sets `FileDescriptorProto.edition`, `parse_with_edition` is gone, protox's `src` is upstream's unchanged, +101 lines of tests; against stock prost-types, run 1's version).
4. **prost-types: "Regenerate from protobuf 32.0"**: `src/protobuf.rs` and `src/compiler.rs` regenerated with upstream's own bootstrap configuration (`tests/src/bootstrap.rs`: `compile_well_known_types`, `btree_map(["."])`, the `arbitrary` derive) from v32.0's protos, i.e. update `tests/src/include/google/protobuf` and rerun the bootstrap test; adds `FileDescriptorProto.edition` and `option_dependency`, `features` on every options message, `FeatureSet`, `FeatureSetDefaults`, `Edition`, `SymbolVisibility`, extension-range declarations, `CodeGeneratorRequest.source_file_descriptors`, `CodeGeneratorResponse.minimum_edition`/`maximum_edition`, `Feature::SupportsEditions`; breaking (new fields; `FileOptions.php_generic_services` removed); crate's tests pass with and without default features; a slice of tokio-rs/prost PR #1347.

## 1.0 reservations
- **Diagnostic codes:** `input::unsupported_feature`, `input::extensions` (new); `input::editions` now means "an edition other than 2023".
- **Runtime API (additive, minor):** `Proto.Field.withDefault : String -> Descriptor -> Descriptor`, `defaultValue : Descriptor -> Maybe String`; `Proto.Enum.withClosed`, `isClosed`; `Proto.Json.closedEnum`; opaque descriptor records gained fields.
- **Library API:** IR `Cardinality::Required`, `Annotations.default`, `Enum::new_closed`/`is_closed`; `diagnostics::UnsupportedFeature`, `first_statement`, `unsupported_edition`; `Problem::unsupported_feature` takes a `Spelling`.
- **Elm-form choices to fix before 1.0:** a required field is a `Maybe` and its decoder doesn't fail when missing; a default is descriptor data, not applied by generated code.
- **`check`:** records nothing new; the edition shows only as drift in the modules it changes (argued in NOTES).

## Gates
Passing: fmt-check, clippy, test, elm-check, snippets, changelog-check, zizmor, gitleaks, deny (unchanged), license. `package` fails by design (verifies against crates.io prost-reflect without `Syntax::Editions`). Vendored suites green except the two pristine failures (prost-reflect `lib.rs:77` doctest; 26 protox `compare.rs` tests needing the submodule). 33 protox-parse debug snapshots updated for the new empty fields. Clippy: 28 doc-indent warnings in the regenerated prost-types; vendor/ is not in the gate.

## Not done
- **EXPANDED under the binary codecs stays refused** per the run's decisions. It turned out the costliest refusal: the merged binary codecs already encode unpacked fields (`Field::unpacked` now reads EXPANDED too), so lifting it is deleting one check, and would make `test_messages_proto3_editions.proto` generate whole under `codec=both`.
- Not implemented: closed enums in the binary decoders (unknown number as unknown field); required fields as plain values; edition 2024 (run 3); feature extensions; prost-reflect's map-enum-first-value-0 rule.
- Minor doc gap: a closed enum's typed value still says "zero value" in its doc string.
- `spike/ref` now also holds v32.0's well-known-type protos and plugin.proto (fetched, never executed).

Disk stayed at or above 15.7 GB throughout.
