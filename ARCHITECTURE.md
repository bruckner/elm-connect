# Architecture

elm-connect has two halves that ship as one version: a generator, in
Rust, that turns proto files into Elm modules, and a runtime, the Elm
package in `src/`, that generated code calls. This page maps both for
someone about to change them, and the tests that hold them. The reasons
behind each shape are in [docs/design.md](docs/design.md); the section
numbers below point there.

## The generator

```
.proto ─► descriptor pool ─► IR    ─► emit    ─► Elm AST    ─► printer      ─► .elm
          protox, or         ir.rs    emit.rs    elm/ast.rs    elm/print.rs
          protoc's bytes     ir/      emit/
```

All of it but the two fronts is the library `crates/elm-connect-gen`.
Its entry point is `generate` in `lib.rs`: a
`prost_reflect::DescriptorPool`, the names of the files to generate and
the `Options` in; the files, sorted by path, and the warnings out, or
every problem found.

**The descriptor pool.** The generator reads protos only through
prost-reflect. The two fronts build the pool differently:

- `crates/protoc-gen-elm-connect` is the protoc plugin. It reads the
  `CodeGeneratorRequest` on stdin and builds the pool from the raw bytes
  of its `proto_file`s, because decoding them into `prost_types` drops
  extension options such as `google.api.http`, which
  `prost_types::MethodOptions` has no field for. Options come as the
  request's parameter; warnings go to stderr.
- `crates/elm-connect` is the CLI (`main.rs` for the arguments, `lib.rs`
  for the work, so tests drive it in-process). It compiles the protos
  itself with protox. `gen` writes the modules; `check` generates in
  memory and compares with the output directory, reporting missing,
  differing and stale modules.

`googleapis.rs` embeds three googleapis files (`google/api/http.proto`,
`annotations.proto`, `field_behavior.proto`, under
`crates/elm-connect-gen/googleapis/`) and serves them to protox after
the user's include paths, so a proto with HTTP rules compiles without a
googleapis checkout. Neither front generates them when they arrive as
imports.

**The IR** (`ir.rs` and `ir/`) is one `Package` per proto package: its
messages, enums and oneofs with every Elm name already decided, and its
services with each method's route. `ir/build.rs` builds it from the pool
and reports what has no Elm form; `naming.rs` holds the naming rules as
pure functions (§3.7), `ir/rename.rs` the `rename` option, `ir/graph.rs`
the strongly connected components behind recursive messages and import
cycles, `ir/comments.rs` and `ir/declaration.rs` what each element's
documentation says. `route.rs` parses `google.api.http` path templates
and resolves each rule's fields against the request and response (§4,
§5.3). `options.rs` parses the options (§6).

**Diagnostics** (`diagnostics.rs`, `diagnostics/spans.rs`): every
`Problem` has a `Code`, a message, a help sentence and sites pointing
into the proto source through `SourceCodeInfo`. The CLI renders them
with the source lines quoted; the plugin, whose request carries no
sources, names the proto elements and their `file:line:column`. Every
code has a row in [docs/diagnostics.md](docs/diagnostics.md).

**Emit** (`emit.rs` and `emit/`) turns one IR package into its Elm
modules: the package module of types and codecs (`message.rs`,
`enumeration.rs`, `oneof.rs`, `field.rs`, `scalar.rs`, `recursion.rs`),
a descriptor module per message and enum with the registry
(`descriptor.rs`, §3.9), and a module of calls per service (`method.rs`,
§4). `docs.rs` writes the doc comments. The emitter decides which
declarations exist and what they say; every name comes from the IR and
every layout from the printer.

**The Elm AST and printer** (`elm/`): `ast.rs` is a typed syntax tree
covering only what generated code needs; `build.rs` has small
constructors so emitter code reads like its output. `print.rs` and
`print/layout.rs` print it, and `markdown.rs` prints doc comments. The
printer's output is held to be elm-format 0.8.8's own layout, a fixed
point of `elm-format`: the corpus's formatted check and
`crates/elm-connect-gen/tests/elm_printer.rs` run `elm-format
--validate` over it.

## The runtime

`src/` is one Elm package with two roots (§5.2):

- `Proto.*` is the data: the proto3 JSON codecs (`Proto.Json`,
  `Proto.Int64`, `Proto.Bytes`, `Proto.Timestamp`, `Proto.Duration`),
  the typed values and descriptor trees (`Proto.Message`, `Proto.Enum`,
  `Proto.Method`, `Proto.Field`, `Proto.EnumValue`), the HTTP bindings
  (`Proto.Http`), `Proto.Registry`, `Proto.Any`, `Proto.WellKnown`, and
  `Proto.Version`, the compatibility sentinel every generated module
  names (§8.2).
- `Rpc.*` is the calling: `Rpc` builds requests, sends them and reads
  answers, beside a module per type it takes or gives (`Rpc.Call`,
  `Rpc.Transport`, `Rpc.Retry`, `Rpc.Trace`, `Rpc.Body`, `Rpc.Request`,
  `Rpc.Response`, `Rpc.Error`, `Rpc.Code`).

Imports point one way: no `Proto` module imports an `Rpc` one, and `Rpc`
reads only two internal modules of the `Proto` side,
`Proto.Internal.Binding` and `Proto.Internal.Any` (§3.1, rule 7).

The `Internal` modules (`src/Rpc/Internal/`, `src/Proto/Internal/`) are
not exposed. They exist for two reasons (§3.1, rule 4): an opaque type
that two public modules must build or match keeps its constructor in one
(`Rpc.Internal.Call`, built by `Rpc` and read by `Rpc.Call`), and
implementation stays out of the public modules so that they read as API:
`Rpc.Internal.Route` maps a call onto a binding, `Wire` builds the
request each transport sends, `Answer` reads an answer into a result or
an error, `Retry` runs the attempts, `Http` adapts elm/http (§5.2). They
are one module per shared type, not one `Rpc.Internal`, because a single
module would form an import cycle.

## The tests

Each layer proves one thing and has a known gap. A path that starts with
`tests/` is one of the runtime's Elm tests.
[conformance/README.md](conformance/README.md) describes them in full.

- **The corpus** (`conformance/cases/`,
  `crates/elm-connect-gen/tests/conformance.rs`): each case's protos
  generate exactly its expected modules or `diagnostics.txt`; every
  expected module compiles against the runtime in `conformance/harness/`
  and passes `elm-format --validate`. Gap: the modules are compiled and
  diffed, never run.
- **The plugin** (`crates/protoc-gen-elm-connect/tests/plugin.rs`): the
  built binary, sent each case as protoc would, gives the same modules,
  and the same problems by code. **The CLI**
  (`crates/elm-connect/tests/`): `gen`, `check` and the rendering of
  compile errors.
- **The IR and printer tests** (`crates/elm-connect-gen/tests/ir/` and
  `elm_printer.rs`): the IR's structure and problems from small
  in-memory protos; the printer against elm-format and `elm make`.
- **The route fixtures** (`conformance/routes/*.json`,
  `crates/elm-connect-gen/tests/routes.rs`): a request under a
  `google.api.http` rule becomes the expected path, query and body,
  checked in Rust against a reference built on prost-reflect and in Elm
  by replaying each fixture through `Rpc.request`
  (`tests/RouteFixturesTest.elm`). Gap: the fixtures are chosen by hand.
- **The route properties** (same test file,
  `tests/RouteProperties.elm`): requests sampled from a fixed seed for
  every binding, replayed the same way. Gap: they are not run against a
  server.
- **The codec round trips** (`conformance/codec/`,
  `crates/elm-connect-gen/tests/codec.rs`, `tests/Codec/`): the
  generated codecs decode prost-reflect's JSON in three forms and write
  back its canonical form, but for the differences the design allows.
  The Elm they run is generated at test time under `tests/Generated/`
  (gitignored); nothing to bless. Gap: prost-reflect cannot write a NaN
  or infinite wrapper, so those are not sampled.
- **The Elm unit and fuzz tests** (`tests/Proto/`, `tests/Rpc/`,
  `tests/RpcTest.elm`, `tests/RpcFuzzTest.elm`): the runtime's own laws,
  with no reference implementation.
- **The live suite** (`conformance/live/`, `just live`): the runtime,
  compiled into a headless program driven from Node, against the example
  server over Connect, and over transcoding under Vanguard, under
  grpc-gateway and under Envoy (`docs/envoy.md`), each with a
  known-divergent file of where that transcoder answers differently (§7,
  "Live verification").
- **The Connect conformance suite** (`conformance/live/conformance.mjs`,
  `conformance/live/src/Live/Conformance.elm`): connectconformance's
  unary JSON cases over HTTP/1.1, through the pure halves and through
  `Rpc.sendTraced`. Gap: what the runtime does not support (streaming,
  the binary codec, HTTP/2) is declared out, and
  `known-failing-send.txt` lists the one case `sendTraced` fails.
- **The protobuf conformance suite** (`conformance/protobuf/`, `just
  protobuf-conformance`, opt-in): protobuf's `conformance_test_runner`
  against the proto3 JSON codecs, through the Elm generated for its
  test messages. Gap: JSON in and out only; the cases it fails are
  classified in `failure_list.txt`.
- **Lockstep** (`crates/elm-connect-gen/tests/lockstep.rs`): the
  workspace's version, `elm.json`'s, the `Proto.Version` sentinel and
  the corpus's header placeholder agree, and `rust-version` is the
  pinned toolchain (§8). **The catalogue** (`catalogue.rs`, beside it):
  every diagnostic code has a row in `docs/diagnostics.md`, and no row
  names a code that is gone.
- **Older compilers** (CI's `elm-compat` job, `just compile-with`, `just
  test-with`): the runtime and the corpus compile with Elm 0.19.0 and
  0.19.1, and the tests pass under 0.19.1 (§8.6).
