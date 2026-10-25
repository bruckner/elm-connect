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
