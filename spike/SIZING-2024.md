# Sizing: edition 2024 on top of the edition 2023 forks

Read from protobuf v32.0 (`spike/ref/src/google/protobuf/descriptor.proto`, `descriptor.cc`,
`compiler/parser.cc`), protobuf.dev's editions feature and overview pages and the
2025-06-27 news post announcing edition 2024 for 32.x, and checked by running protoc 35.1 and
buf 1.73.0 on probe files (kept outside the worktree).

## What edition 2024 is, against 2023

| Area | 2024 | Where protoc does it |
|---|---|---|
| Edition value | `EDITION_2024 = 1001` | parser edition statement |
| Defaults of the six 2023 features | unchanged (EXPLICIT, OPEN, PACKED, VERIFY, LENGTH_PREFIXED, ALLOW); no 2024 row for them | `FeatureSet` `edition_defaults` |
| New core features | `enforce_naming_style` (STYLE_LEGACY ≤2023, STYLE2024 from 2024; targets file, extension range, message, field, oneof, enum, enum value, service, method; retention SOURCE); `default_symbol_visibility` (EXPORT_ALL ≤2023, EXPORT_TOP_LEVEL from 2024; file only; SOURCE) | `descriptor.proto` 1112–1164 |
| Language features (`pb.cpp`, `pb.java`, `pb.go`) | defaults move (`string_type` VIEW, `nest_in_file_class` NO, `api_level` OPAQUE, …) | not resolved by the forks (feature extensions are carried, not resolved, as in 2023) |
| `import option "x.proto";` | 2024 only; must follow ordinary imports; into `FileDescriptorProto.option_dependency` (15); only extensions (custom options) of an option-imported file resolve, a message or enum from it is "not imported" | `parser.cc` `ParseImport`; `descriptor.cc` `FindSymbol` (`option_dependencies_` admits only field symbols), `ValidateOptions(FileDescriptor)` |
| `export` / `local` | 2024 only, before `message`/`enum` at top level and nested; into `visibility` (DescriptorProto 11, EnumDescriptorProto 6); before anything else an error | `parser.cc` `ParseVisibility` |
| Effective visibility | keyword if set; else by `default_symbol_visibility`: EXPORT_ALL → export; EXPORT_TOP_LEVEL → nested local; LOCAL_ALL, STRICT → local | `descriptor.cc` `Symbol::GetEffectiveVisibility` |
| Cross-file checks | a field type, an extendee, and (by probe) a method's input/output type defined in another file must be export; message text mirrored ("Symbol \"a.v1.Hidden\", defined in \"a.proto\"  is not visible from \"c.proto\". It is explicitly marked 'local' …" / "It defaulted to local from file-level 'option features.default_symbol_visibility = 'EXPORT_TOP_LEVEL'; …") | `IsVisibleFrom`, `GetVisibilityError` |
| STRICT | a nested `export message` or `export enum` is an error, except an enum inside a top-level local message with exactly `reserved 1 to max;` | `CheckVisibilityRules`, `IsEnumNamespaceMessage` |
| STYLE2024 | package lower_snake_case (dots allowed); message, enum, service, method TitleCase (alnum, capital first); field, oneof lower_snake_case; enum value UPPER_SNAKE_CASE; underscore rules (no leading/trailing, `_` followed by a letter); six error texts plus the opt-out suffix; run only when the file has no other error, before the visibility rules | `ValidateNamingStyle`, `ContainsBadUnderscores`, `IsValid*Name`; enforced by protoc's CLI and by buf (probed) |
| Removed in 2024 | `import weak` (parser and pool), `ctype` field option, `java_multiple_files` file option | `parser.cc` 2545, `descriptor.cc` 8526–8545, 8634 |

Facts from the probes: protoc 35.1 and buf 1.73.0 agree on every visibility and naming case
tried (texts differ; codes agree); buf also refuses a STRICT file whose namespacing message
does not reserve all numbers; protoc 35.1 aborts (a CHECK failure, exit 134) on an
`import option` of a missing file under `--descriptor_set_out`, buf reports it.

## Estimate (lines of code before tests)

| Crate | What | Code | Tests |
|---|---|---|---|
| protox-parse | `"2024"` accepted; `import option` (AST, ordering error, pre-2024 error, generate field 15); `export`/`local` at top level and nested (AST, pre-2024 behaviour as protoc's, error when not before message/enum, generate fields 11/6); `import weak` refused in 2024; error kinds | ~200 | ~150 + snapshots |
| protox | load option-imported files like imports (`add_import`, topological order of the set) | ~30 | ~60 |
| prost-reflect | private `types.rs` carry `option_dependency`/`visibility` both ways (~25); `Edition::Edition2024`, the 2024 defaults row, `enforce_naming_style`/`default_symbol_visibility` in `Features` with typed enums, the "not introduced" check kept for 2023 (~90); public API: `SymbolVisibility`, `visibility()` on message/enum, `FileDescriptor::option_dependencies()` (~70); option dependencies: their own transitive set used only for option-name resolution, "only imported for options" help on a type found through one (~60); visibility checks at field types, extendees, method types with protoc's texts, STRICT nested-export rule with the namespace exception (~150); STYLE2024 validation over every element with protoc's texts (~150); 2024 removals: option imports before 2024, weak imports, `ctype`, `java_multiple_files` (~50); error kinds and labels (~60) | ~655 | ~500 (YAML cases + snapshots) |
| generator | edition gate admits 2024; nothing else (visibility and naming are pool rules, no new feature maps to output) | ~20 | corpus cases |
| plugin | `maximum_edition = EDITION_2024`; the edition check | ~15 | ~30 |
| oracle corpus | 2024 rewrites of the two conformance protos, visibility matrix (~8 files), option-import case, naming case; invalid table +~20 cases | data | — |

**Forks total ≈ 885 lines of code** (protox-parse 200 + protox 30 + prost-reflect 655).

## Decision

The brief's bound is roughly run 1's protox-parse change (+205) plus half of run 1's
prost-reflect feature work (+1313 / 2 ≈ 656), stated as > 1,200 lines of code before tests.
The estimate (~885) is under the stated bound, though near the 861-line sum that motivated
it. **Continue with steps 1–4.** If the prost-reflect diff passes ~1,100 lines of code while
writing it, that is reported as an overrun rather than hidden.
