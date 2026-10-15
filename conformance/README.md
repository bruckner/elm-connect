# Conformance

The conformance corpus pins what the generator emits (`docs/design.md`
§7). Each case is a directory under `cases/`:

```
cases/<case>/
  options.txt            optional: the generator's options, as a protoc
                         plugin parameter on one line (`int64=int`)
  input/                 .proto files; all of them are compiled and generated
  include/               optional: .proto files the input may import, which
                         are compiled but not requested
  expected/
    <Module/Path>.elm    the Elm generated from the input, one file per module
    warnings.txt         beside the modules, when generating warns: the
                         warnings (`streaming=skip`'s skipped methods)
  or
    diagnostics.txt      the problems generating reports instead
```

A case expects either modules or `diagnostics.txt`, never both. Inputs are
compiled with protox, with `input/` and `include/` as the include paths,
and every file under `input/` is requested; nothing under `include/` is.
A requested package is generated whole (design §3.1), so an `include/`
file of a requested package is in its module (`packages_whole` case);
one of any other package is not generated. Without `options.txt` a
case is generated with the default options.

## The checks

`crates/elm-connect-gen/tests/conformance.rs` runs four tests over every
case; `just check` runs them with the other Rust tests.

- **golden**: regenerating each modules case gives exactly its expected
  files, byte for byte, none missing and none extra, and warns exactly
  its `warnings.txt`, rendered as `diagnostics.txt` is, or not at all
  when it has none. A failure shows a unified diff. A unit test in the
  same file exercises the warnings' mismatch and blessing paths.
- **diagnostics**: generating each `diagnostics.txt` case fails, and the
  problems, rendered narrow (80 columns, no colour) with the proto sources
  attached, are exactly `diagnostics.txt`. A unit test in the same file
  also exercises the mismatch and blessing paths on a throwaway case.
- **compiles**: every case's expected modules compile with `elm make` in
  `harness/`, an Elm application whose source directories are the runtime
  package's `../../src` and a scratch `generated/` (gitignored) the test
  copies the modules into. Cases compile one at a time, since two cases may
  define the same module.
- **formatted**: `elm-format --validate` accepts every expected module.

The tests use the pinned compiler, Elm 0.19.2. `compile-with.sh` runs the
compiles check, and builds the runtime package, with another one:

```sh
conformance/compile-with.sh path/to/elm   # or: just compile-with path/to/elm
```

CI runs it with Elm 0.19.0 and 0.19.1 (design §8).

## Blessing

Blessing accepts the generator's current output as the expected output:

```sh
just bless
```

runs the golden and diagnostics tests with `ELM_CONNECT_BLESS=1`, which
rewrites each case's `expected/` (adding, replacing and deleting modules
and `warnings.txt`, or rewriting `diagnostics.txt`) instead of comparing. Read the diff before
committing it: the blessed output is what users will maintain against.

To add a case, create `cases/<name>/input/` with its protos and bless. For
a case that is meant to fail, create an empty `expected/diagnostics.txt`
first, then bless.

## Route fixtures

`routes/` pins what HTTP request a request becomes under a
`google.api.http` rule (design §7). `routes/routes.proto` declares the
request messages and one service whose methods carry the rules (all but
one, which has none); each `routes/*.json` file holds fixtures:

```json
{
  "name": "fields outside the path become query parameters",
  "method": "routes.v1.Routes.GetMessage",
  "binding": 2,
  "rule": { "verb": "GET", "template": "/v1/messages/{message_id}", "body": "" },
  "request": { "messageId": "123456", "revision": "2", "sub": { "subfield": "foo" } },
  "expect": {
    "path": "/v1/messages/123456",
    "query": [["revision", "2"], ["sub.subfield", "foo"]],
    "body": null
  }
}
```

`binding` is `0` for the rule's own and `n` for its `n`th additional
binding; `rule` repeats that binding so the file reads without the proto.
A method without a rule has `"binding": null` and `"rule": null`, and
expects the implicit route: `POST /<package>.<Service>/<Method>` with
the request as its body and `Connect-Protocol-Version: 1`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and
Vanguard serve (`implicit.json`). `request` is proto3 JSON. `path`
(custom verb included) and the query pairs are as sent,
percent-encoded; `headers`, optional and `[]` when absent, are those
the route itself adds; `body` is JSON or `null` for none.
Bodies compare after dropping `null`s and default values, which a writer
may omit or spell out. Nothing in a fixture is specific to this client,
so a server-side implementation can check itself against the same file.

`crates/elm-connect-gen/tests/routes.rs` holds both ends to them:

- the rule each fixture names is the binding the generator reads, and a
  reference implementation over protobuf's own model of the request
  (prost-reflect's proto3 JSON parser and field presence) turns the
  generated route and the request into the expectation;
- the modules generated from `routes.proto` (`tests/Routes/V1.elm` and
  the service's `tests/Routes/V1/Routes.elm`) and the fixtures as Elm
  data (`tests/RouteFixtures.elm`) are pinned in the runtime's tests,
  where `tests/RouteFixturesTest.elm` replays each through `Rpc.request`
  with the Transcode transport, applying the generated function of the
  fixture's method and choosing its binding with `Rpc.viaBinding`; a
  fixture naming a binding the method lacks fails. `just bless` rewrites
  all three.

To add a fixture, add it to a `routes/*.json` file (and a method to
`routes.proto` if no rule fits), check that the reference agrees, and
bless.
