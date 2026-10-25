# Notes: editions spike, run 1

Working notes that do not belong in code comments: the decisions taken while forking, and the
traps met. The commit messages under `vendor/` carry the rest.

## Decisions

- **Vendored crates are excluded from the workspace.** As path patches inside the workspace
  they would become members, so the gate's `clippy -D warnings`, `cargo test --workspace` and
  `cargo deny` (dev-dependencies of members) would run over upstream code and its test
  dependencies. `exclude = ["vendor"]` keeps the gate on elm-connect; `vendor/Cargo.toml` is a
  workspace of the three crates, patched to each other, that runs their own suites.
- **The edition travels as bytes.** prost-types 0.14.4 (the newest) has no
  `FileDescriptorProto.edition` and no `features` on any options message, and prost drops
  unknown fields. prost-reflect's private descriptor types gain `edition`; protox hands an
  editions file to the pool through `File::encoded` (the slot a precompiled set already uses),
  with field 14 appended to the encoded descriptor; protox-parse returns the edition beside the
  descriptor (`parse_with_edition`). Anything that goes through a `prost_types` value
  (`Compiler::file_descriptor_set`, `FileDescriptor::file_descriptor_proto`,
  `add_file_descriptor_proto`) keeps `syntax = "editions"` and loses the edition.
- **Feature defaults are a table, not read from the pool.** The embedded `descriptor.proto` is
  built from prost-types values, so its `edition_defaults` options are dropped; protoc and
  protobuf-go also compile the defaults in. The table (`Features::defaults`) carries the
  PROTO2, PROTO3 and 2023 rows of protobuf 32.0's `FeatureSet`.
- **The embedded descriptor.proto was stale.** prost-reflect 0.16.5 embedded a pre-26
  `descriptor.proto` whose `Utf8Validation.NONE` is 1; protoc writes 3. Option resolution in a
  pool without its own `descriptor.proto` uses the embedded one, so `features.utf8_validation =
  NONE` came out as 1. The literal was regenerated from protobuf 32.0
  (`spike/tools/wkt-descriptor`, an own tool: the generator upstream used is not published).
- **Legacy files get features too**, inferred as protoc infers them, so `features()` is defined
  for every descriptor; their derived properties (`supports_presence`, `is_packed`, ...) are still
  computed as before, from the syntax.
- **Feature targets are checked** for the six 2023 features, because protoc and buf refuse
  `field_presence` on a message. No 2023 feature targets a oneof, enum value, service or method,
  so "features at every level" can only mean inheritance there.
- **The CLI still refuses editions.** With protox parsing them, the CLI's `input::editions`
  problem (built from protox's parse error) stopped firing; it now also fires on a compiled file
  whose syntax is editions. Generating from editions is run 2.

## Traps

- prost-reflect's upstream `UnknownSyntax` path built its error label before the file was in
  the pool, which panics (the reported `syntax = "editions"` panic); the label is now built
  after the file is added.
- `cargo fmt --all` from the root does not format the vendored crates; run it with
  `--manifest-path vendor/Cargo.toml`.
- insta writes `.snap.new` files when a snapshot is missing; the packages of protox-parse ship
  none, so its suite fails from the package alone until the upstream snapshots are restored.
- rustfmt silently leaves a 3,000-line single-line literal unformatted inside `vec![...]` at
  depth; format the literal alone and indent it in.
- prost-reflect's `Debug` of a `FieldDescriptor` prints its default value, which for a
  recursive message type recurses forever.

# Notes: editions spike, run 2

## Decisions

- **`check` records nothing about the edition.** `check` regenerates from
  the protos it is given and compares modules; the `-- Options:` header
  records only what is not in the protos (the options). The edition is in
  the protos, so a change of edition that changes output is drift `check`
  reports as the modules that differ, and one that does not (a file moved
  to its proto3-equivalent edition 2023 twin) is no drift, which is right:
  nothing a user maintains against moved. Recording it would make that
  harmless move a header-only diff in every module. The CLI test
  `the_proto3_twin_of_a_tree_is_current` pins it.
- **The CLI generates edition 2023.** Run 1's post-compile refusal is gone;
  `input::editions` is now only the CLI's report, in place of protox's
  parse error, for a file declaring an edition protox does not parse
  (2024), through `elm_connect_gen::diagnostics::unsupported_edition`,
  which the corpus harness uses too. A 2023 file that fails to parse
  keeps the parser's errors.
- **The plugin claims editions natively.** With prost-types regenerated, the
  response's `supported_features` carries `FEATURE_SUPPORTS_EDITIONS` and
  `minimum_edition`/`maximum_edition` are ordinary fields (EDITION_2023 both),
  set on every response, errors included; the edition check reads
  `request.proto_file[i].edition` from the decoded request. The pool is still
  built from the request's raw `proto_file` bytes, for the extension options
  (`google.api.http`) prost drops, as before; the edition rides in those bytes
  too. No raw-byte splicing was needed in the end; the spliced version written
  before the prost-types regeneration was discarded unbuilt into a commit.
- **The plugin's own edition check stays.** buf 1.73.0 sends an edition 2024
  file to a plugin that claims 2023 at most; protoc refuses it first.
- **Conformance runs two edition 2023 messages.** The runner (v32.0-rc2) at
  `--maximum_edition 2023` runs 14 cases on `TestAllTypesEdition2023` (the
  editions-specific ones: delimited fields and extensions, maps, length-prefixed
  fields) and the whole proto3 suite again on proto3's message written in
  edition 2023 (`Editions_Proto3`, 1,468 cases). The testee answers both, from
  subsets (`spike/protobuf-conformance/strip-editions.sh`); the tally and its
  classification are in `spike/protobuf-conformance/tally-editions.md`. The
  binary codec spike merged cleanly (its notes renamed), so binary legs ran.
- **EXPANDED is the costliest refusal.** test_messages_proto3_editions.proto,
  protobuf's own proto3-in-editions file, writes proto3's `[packed = false]`
  as `repeated_field_encoding = EXPANDED`, so under codec=both the canonical
  editions twin of proto3 is refused although its proto3 original generates:
  the merged binary codecs already encode unpacked fields (`Field::unpacked`),
  and `unpacked()` already reads EXPANDED, so lifting the refusal is deleting
  the check. Kept, as the decision for this run says; the report raises it.
- **The notes example's edition 2023 translation generates today's code**:
  `spike/run-notes-twin.sh` (39 modules through the plugin under buf, equal
  to examples/notes/elm/generated; 11 through the CLI, equal to the proto3
  file's).
- **prost-types is vendored and regenerated** (operator's scope change for
  this run). Command, from the worktree, with protoc 35.1 from its existing
  install and prost-build 0.14.4 (the prost-types release's own):
  `mise exec -- env PROTOC=$HOME/.local/share/mise/installs/protoc/35.1/bin/protoc
  cargo run --manifest-path spike/tools/prost-types-gen/Cargo.toml --
  spike/ref/src OUT`, then `OUT/google.protobuf.rs` → `src/protobuf.rs` and
  `OUT/google.protobuf.compiler.rs` → `src/compiler.rs`. Inputs: protobuf
  v32.0's descriptor.proto, compiler/plugin.proto and the well-known types
  prost-types carries, fetched read-only into `spike/ref/src`. The
  configuration (compile_well_known_types, `btree_map(["."])`, the
  `arbitrary` derive on every type) turned out to be exactly upstream's own
  bootstrap test (prost `tests/src/bootstrap.rs`), which regenerates the same
  files from the repository's `tests/src/include` protos; an upstream PR is
  that directory updated to v32.0 and the two files regenerated. The first
  attempt lacked `btree_map` (the crate is no_std-capable and uses
  BTreeMap), which the crate's own `conversions.rs` caught at once. Three
  plugin.proto doc comments come out differently from the shipped files
  (upstream's comment sanitizer has changed since); clippy flags 28 of the
  regenerated doc lists as over-indented. Neither is in the gate, which does
  not lint vendor/.
- **What the side channels became.** protox-parse's `parse_with_edition` is
  removed (`parse` sets `FileDescriptorProto.edition`); protox's
  `parse_source` and its use of `File::encoded` for editions files are
  removed, so `protox/src` is upstream's again; prost-reflect's
  `from_prost`/`to_prost` carry the edition. prost-reflect keeps its private
  `edition` field and `Edition` enumeration in its own descriptor types,
  since those types, not prost-types', are what its pool decodes into. The
  wkt.rs literals fill prost-types' new options fields with defaults, so
  the embedded descriptor.proto still lacks its own `edition_defaults` etc.
  (the resolver keeps its table, as before).
- **Required fields are a `Maybe`.** `LEGACY_REQUIRED` keeps one Elm form
  per presence: the field is held and coded as an optional one, and only
  its descriptor (`CardinalityRequired`) and its declaration say required.
  A plain value would need a third field shape (encoder that always writes,
  decoder that fails when absent, and a cycle-safe form for a required
  message field). Decoding does not fail on a missing required field; the
  conformance suite has no edition 2023 case that tests it.
- **Defaults are descriptor data.** A field with a default has explicit
  presence (protoc refuses one on an implicit field), so it is a `Maybe`
  and its default is the value it means while `Nothing`; generated code does
  not apply it. `Proto.Field.withDefault` carries the text as the proto
  writes it (`FieldDescriptorProto.default_value`: C-escaped bytes, an enum
  value's name).

# Notes: editions spike, run 3

## Decisions

- **Sizing drove going ahead** (`spike/SIZING-2024.md`): ~885 lines of fork
  code estimated against the brief's bound of ~1,200; the result is 1,128
  (prost-reflect 933, protox-parse 171, protox 24), plus 102 mechanical
  lines in prost-reflect's `wkt.rs` literals. The overrun against the
  estimate is prost-reflect's: `build/symbols.rs` (572 lines, the
  visibility, naming and STRICT checks with protoc's messages) was sized at
  ~360, and the missing-option-dependency and naming-flag decisions below
  were not foreseen.
- **Visibility does not change generated output.** A client generator emits
  every type its files define; `export`/`local` decide which other files
  may refer to a type, a cross-file rule the descriptor pool enforces
  (field types, extendees, method input and output types, as protoc 35.1
  checks them by probe; `descriptor.cc` shows the first two). A local
  nested type of a generated file is still generated: a field of its own
  file may use it. protobuf.dev says the same ("does not affect
  code-generation"). Pinned by `editions_2024_visibility` and the test
  that its modules equal those of the same files without the modifiers and
  without `default_symbol_visibility`.
- **Naming style is checked when a pool asks for it.** protoc's C++
  `DescriptorPool` checks names only when told to (`enforce_naming_style_`,
  which protoc's CLI sets); prost-reflect gains
  `DescriptorPool::enforce_naming_style(bool)`, off by default, and protox's
  compiler turns it on. Found by the oracle: protoc strips
  source-retention options (both new 2024 features are SOURCE) from the
  descriptor sets it writes without `--retain_options` and from the
  `proto_file`s it sends plugins, so a pool that always checked names would
  refuse `test_messages_proto3_editions.proto`'s 2024 rewrite, whose
  STYLE_LEGACY opt-out protoc had stripped. The plugin's pool therefore
  does not check names; protoc and buf refuse such files before any plugin
  runs. Visibility checks stay always on: stripping only loosens them
  (a stripped STRICT or LOCAL_ALL file reads as EXPORT_TOP_LEVEL), so they
  cannot refuse a file protoc accepted.
- **The CLI renders naming errors as `input::naming_style`**, one problem
  per name, the fork's message (protoc's text without the opt-out clause)
  and a help that names the style and the opt-out, sited at the name, in
  place of protox's error, through
  `elm_connect_gen::diagnostics::naming_style`, which the corpus harness
  uses too (`front_end_case`). Through the plugin there is nothing to
  render: protoc and buf refuse the file first (the lockstep oracle shows
  their own messages), and the plugin's replay test skips the case as it
  skips `editions_unknown`. The brief asked for the rendering "through the
  CLI and the plugin"; the plugin half does not exist for this rule.
- **A missing option dependency is not an error in the pool.** buf 1.73.0
  leaves the option-imported file out of a plugin's request (and out of
  its images' `option_dependency` altogether); protoc's pool tolerates a
  missing one by default (`enforce_option_` off: a placeholder file). The
  fork leaves it out of `option_dependencies()`. protox still loads option
  imports from source like imports, and a missing one is its usual
  "import not found".
- **`input::editions` is for editions after 2024.** The corpus case is now
  `editions_unknown` (`edition = "2025"`); the plugin's check refuses any
  edition other than 2023 and 2024 (tested with `EDITION_99997_TEST_ONLY`).
  The plugin claims `minimum_edition = EDITION_2023`,
  `maximum_edition = EDITION_2024`.
- **The 2024 rewrites of protobuf's two editions protos** change only what
  protoc requires: `edition = "2024"`, the four `ctype` options removed
  (2024 forbids `ctype`; the string type is a C++ matter) from each,
  `java_multiple_files` removed from the 2023 one, and STYLE_LEGACY on the
  proto3 one, whose JSON-name test fields (`field__name4_`, `FieldName8`,
  …) and enum values (`moo`, `kTrue`) break STYLE2024. No
  `test_messages_edition2024*.proto` exists at v32.0 (the tree has only
  `unittest_lite_edition_2024.proto`, a C++ unit test).
- **EXPANDED lifted.** One check in `check_field_features` and the
  `UnsupportedFeature::Expanded` variant deleted; the codecs needed
  nothing. `check` needs nothing either: the edition and its features are
  in the protos.

## Traps

- `protoc -o` strips source-retention options unless `--retain_options`:
  the oracle compares with it; without it the 2024 features vanish.
- protoc 35.1 aborts (CHECK failure in `GetTransitiveDependencies`, exit
  134) when an `import option` names a missing file and `-o` is given.
- buf's `--path` takes paths relative to the directory buf runs in
  (`mise exec -C` moves it to the repository root): pass absolute ones.
- `git stash -u`/`pop` around an autosquash restored a staged rename into
  the index, and the next `git add <dir>` + commit took it along; recommit
  by path from a soft reset.
- insta rewrites a snapshot's header (`source:`, `expression:`) when it
  blesses under a workspace other than upstream's; the run kept the
  upstream headers by hand so the protox-parse diff is the content line.
