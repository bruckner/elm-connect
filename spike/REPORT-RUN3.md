# Editions spike, run 3: edition 2024 and the EXPANDED lift

**Answer:** Edition 2024 fit under the bound and was added; EXPANDED under the binary codecs was lifted. Edition 2024 files generate from both binaries. Against protoc 35.1 the fork shows 0 descriptor and 0 feature differences; all 25 new invalid cases are refused by fork, protoc and buf alike; the conformance suite passes on the 2023 and 2024 targets with 0 unexpected failures; after the EXPANDED lift, Editions_Proto3 fails exactly where proto3 fails. No blocker.

Branch `spike/editions`, HEAD 7a7af9a (local history rewritten with `--force-with-lease` to fold fixups). No PR, nothing merged. Free disk ≥ 16.3 GB throughout.

## Commits (from 0239708)
1. a6f5294 Size edition 2024 on top of the 2023 forks (`spike/SIZING-2024.md`)
2. e92c0c4 Support edition 2024 (prost-reflect)
3. df04f59 Parse edition 2024 files (protox-parse)
4. f88988f Compile edition 2024 files (protox)
5. e4616ee Compare edition 2024 descriptors with buf and protoc (`spike/editions-corpus-2024/`, invalid cases)
6. 116b359 Generate from edition 2024 files (generator, CLI, plugin, corpus, docs)
7. 6488ae2 Generate expanded repeated fields under binary (EXPANDED lift, conformance)
8. 7a7af9a Record the editions spike's third run (NOTES, POSTURE)

## Sizing and the decision
Read: protobuf v32.0 `descriptor.proto`, `descriptor.cc`, `parser.cc`; protobuf.dev editions pages; the 2025-06-27 news post; probes against protoc 35.1 and buf 1.73.0. What 2024 is: the six 2023 features keep their defaults; two new source-retention features, `enforce_naming_style` and `default_symbol_visibility`; grammar `import option`, `export`/`local` on messages and enums; rules: cross-file visibility checks on field types, extendees and method types (the method check found by probe), the STRICT nested-export rule, STYLE2024 naming; removals: `weak` imports, `ctype`, `java_multiple_files`. Estimate ~885 fork lines against a bound of ~1,200 → continued. Actual 1,128 (prost-reflect +933/−28, protox-parse +171/−8, protox +24/−4) plus 102 mechanical lines in `wkt.rs`; the overrun is mostly `build/symbols.rs` (572, sized ~360).

## What 2024 adds (`git diff --stat a6f5294 HEAD`)
- **prost-reflect (13 src files):** `build/symbols.rs` 572 (new), `features.rs` 121, `build/features.rs` 80, `api.rs` 67, `error.rs` 45, `types.rs` 19, `build/mod.rs` 19, `resolve.rs` 12, `mod.rs` 10, `lib.rs` 9, `names.rs` 4, `options.rs` 2, `tag.rs` 1. Tests +1032 (19 YAML cases with snapshots, 2 resolution tests). The 2024 defaults row; the two new features as typed enums on `Features`, each refused in a 2023 file, `default_symbol_visibility` only on file targets. Visibility carried through decode and `to_prost`; cross-file checks use protoc's message text; STRICT allows the namespace-enum exception. Option imports kept apart from imports (option-only types say "imports only for use in options"); a missing option dependency is left out, as protoc's pool does (buf does not send such files). STYLE2024 naming checks use protoc's six texts and underscore rule, run only when asked via new `DescriptorPool::enforce_naming_style` (off by default, as protoc's C++ pool). Removals refused: `ctype`, `java_multiple_files`, weak imports, option imports before 2024.
- **protox-parse (7 src files):** accepts `"2024"`; `import option` fills `option_dependency` (path 15) with protoc's ordering error and the before-2024 error; `export`/`local` on top-level and nested message/enum (leading comment kept, span starts at `message` as protoc); `import weak` an error in 2024; 23 AST debug snapshots gain `visibility: None`; tests +168.
- **protox (2 src files):** loads option-imported files like imports with spans and duplicate detection across both lists; its pool checks naming style; tests +327.
- **prost-types:** unchanged (run 2's regeneration already has the 2024 fields).

## Oracle (`spike/ORACLE.md`)
Corpus `spike/editions-corpus-2024/` (10 files, 518 elements): the two v32.0 conformance protos rewritten to 2024 (minimal changes protoc needs: drop `ctype` in both, `java_multiple_files` in the 2023 file, STYLE_LEGACY on the proto3 file whose test names break STYLE2024); a visibility matrix (EXPORT_TOP_LEVEL, STRICT, LOCAL_ALL, a 2023 file, a user of all); an option-import pair; a naming file. v32.0 ships no `test_messages_edition2024*.proto`.

| Reference | Descriptor diffs | Feature diffs |
|---|---:|---:|
| protoc 35.1 (`--retain_options`) vs fork | 0 | 0 |
| buf 1.73.0 vs fork | 1 | 1 |
| The 2023 corpus vs protoc and vs buf | 0 | 0 |

The buf difference is buf's: 1.73.0 drops `option_dependency` from its images. Without `--retain_options`, protoc strips the source-retention features; that drove the naming-flag decision (a pool always checking names would refuse the proto3 rewrite once its opt-out was stripped).

**Invalid table:** 25 new cases, all refused by protoc, buf and the fork: visibility 4 cross-file, 2 STRICT, 3 modifier/target; option imports 3; removals 3; naming 10 (package, message, field, field_1, oneof, enum, enum value, trailing underscore, service, method). `edition_2024` now accepted by all three; run 1's three differences unchanged. Without the opt-out, the fork's 19 naming errors on the proto3 rewrite match protoc's text for text.

**Lockstep (CLI = protoc = buf):** both twins, `editions_2024_visibility`, `editions_expanded`, the 2023 cases and `codec_both` identical from all three and equal to expected. `editions_2024_option_import` matches under protoc; under buf one doc line differs (buf does not send the option-imported file, so a custom option is missing from one field's declaration). `editions_2024_naming` and `editions_unknown`: protoc and buf refuse the file before the plugin runs; the CLI reports `input::naming_style` (×6) and `input::editions`. `editions_unsupported`: same codes from all three (2 `input::extensions`, 6 `input::unsupported_feature`).

## Conformance (runner v32.0-rc2, `--enforce_recommended`, `codec=both`)
| Message | Cases | Passed before | Passed after | Failed after |
|---|---:|---:|---:|---:|
| Proto3 | 1468 | 1413 | 1413 | 55 |
| Editions_Proto3 (unstripped `unpacked_*`, NullValue stripped) | 1468 | 1382 | **1413** | 55 |
| TestAllTypesEdition2023 | 14 | 8 | 8 | 6 |
| Suite | | 2803 | **2834** | 116, 0 unexpected |

All 31 EXPANDED cases pass and left `failure_list.txt`. Left: 55 proto3 failures, their 55 twins, 6 delimited cases. The 2024 run (`spike/protobuf-conformance/run-2024.sh`, testee from the 2024 rewrites, `--maximum_edition 2024`) tallies identically: 2834 / 116 / 0 unexpected; the 2024 modules differ from 2023's only in doc lines for the dropped `ctype`. Connect live suite (proto3): 40/40, then 39/40 + 1 known, no drift.

## Generator and plugin decisions
- **Visibility does not change generated output.** A client generator emits every type its files define; visibility is a cross-file rule the fork enforces (protobuf.dev says the same). `editions_2024_visibility` pins it, plus a test that its modules equal those from the same files with modifiers and `default_symbol_visibility` removed.
- **Plugin claims** `FEATURE_SUPPORTS_EDITIONS`, `minimum_edition = EDITION_2023`, `maximum_edition = EDITION_2024`; its own check refuses anything else (tested with `EDITION_99997_TEST_ONLY`).
- **Naming errors reach users through the CLI only:** protoc and buf refuse such files before any plugin runs, and the plugin's pool does not re-check because protoc strips the opt-out. Plugin replay skips the case.
- **New corpus cases:** `editions_2024_proto3_equivalent` (byte-identical to `codec_both`; the twin test covers both editions), `editions_2024_visibility`, `editions_2024_option_import`, `editions_2024_naming`, `editions_expanded`; `editions_2024` became `editions_unknown` (`edition = "2025"`).
- **Docs updated:** design §1 and §3.10, diagnostics, guide (and CLI copy), roadmap, decisions, README. No changelog fragment.

## Draft upstream PR follow-ups
1. **prost-reflect, "Support edition 2024"** (after the 2023 PR): 2024 defaults; `enforce_naming_style` and `default_symbol_visibility` resolved and typed; symbol visibility through decode and `to_prost`, exposed as `visibility()`/`visibility_keyword()`, with protoc's cross-file checks and the STRICT rule; `option_dependency` carried as `option_dependencies()`, option-only types refused with specific help, a missing option dependency tolerated as protoc's pool does; opt-in STYLE2024 via `DescriptorPool::enforce_naming_style` with protoc's messages; refuses weak imports, `ctype`, `java_multiple_files` in 2024; API additive (`Edition` already non-exhaustive); 19 YAML cases; 0 differences vs protoc 35.1 and buf 1.73.0 on a 10-file corpus.
2. **protox, "Parse and compile edition 2024 files":** protox-parse `edition = "2024"`, `import option` with protoc's ordering/before-2024 errors, `export`/`local` with comments kept, `import weak` refused; protox loads option imports and enables naming checks in its compiler pool; depends on the prost-reflect 2024 PR.
3. **prost-types:** nothing new.

## Updated 1.0 reservations
New diagnostic code `input::naming_style` (CLI only). `input::editions` now means editions after 2024. Removed `UnsupportedFeature::Expanded` (EXPANDED no longer refused under binary). Library API: `diagnostics::naming_style`, `LineColSpan::from_bytes`; `unsupported_edition` accepts 2024. Runtime API: none. `check`: nothing new. Still open from run 2: required fields are a `Maybe`; defaults are descriptor data.

## Gates
Passing: fmt-check, clippy, test, elm-check, snippets, changelog-check, zizmor, gitleaks, deny (unchanged), license. `package` fails by design. Vendored suites green apart from the known pristine failures. Clippy on vendored crates: pre-existing protox `io_other_error` warnings and regenerated prost-types doc indents.

## Posture
Updated in `spike/POSTURE.md`. The forks grew by about two thirds of run 1's code, mostly one new prost-reflect file touching no upstream code path, so rebase cost per upstream release grows only a little. Verdict stands: (a) upstream first, same order and versions (prost-reflect 0.17, protox 0.11).

## Not done
Feature extensions (`pb.cpp`, `pb.java` 2024 defaults) carried, not resolved; closed enums in the binary decoders (still refused under binary); required fields as plain values; prost-reflect's map-enum-first-value-0 rule; naming errors through the plugin (no front end sends such files); buf's missing option-imported file in plugin requests (recorded, not worked around); no 2024-specific runner messages at v32.0-rc2 (the 2024 run reuses the 2023 message names); the run-1 negative control and the notes twin were not rerun.
