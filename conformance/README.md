# Conformance

The conformance corpus pins what the generator emits (`docs/design.md`
§7). Each case is a directory under `cases/`:

```
cases/<case>/
  input/                 .proto files; all of them are compiled and generated
  expected/
    <Module/Path>.elm    the Elm generated from the input, one file per module
  or
    diagnostics.txt      the problems generating reports instead
```

A case expects either modules or `diagnostics.txt`, never both. Inputs are
compiled with protox, with `input/` as the only include path, and every
input file is in the generate set.

## The checks

`crates/elm-connect-gen/tests/conformance.rs` runs four tests over every
case; `just check` runs them with the other Rust tests.

- **golden**: regenerating each modules case gives exactly its expected
  files, byte for byte, none missing and none extra. A failure shows a
  unified diff.
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

## Blessing

Blessing accepts the generator's current output as the expected output:

```sh
just bless
```

runs the golden and diagnostics tests with `ELM_CONNECT_BLESS=1`, which
rewrites each case's `expected/` (adding, replacing and deleting modules,
or rewriting `diagnostics.txt`) instead of comparing. Read the diff before
committing it: the blessed output is what users will maintain against.

To add a case, create `cases/<name>/input/` with its protos and bless. For
a case that is meant to fail, create an empty `expected/diagnostics.txt`
first, then bless.

Route fixtures for `google.api.http` templates (design §7) come with the
route generator.
