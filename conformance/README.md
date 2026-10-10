# Conformance

This directory will hold the conformance corpus: `.proto` fixtures, the
Elm the generator is expected to produce from them, and route fixtures
for `google.api.http` templates (see `docs/design.md` §7). Three checks
will run over it: regenerating each case and diffing against the
expected output, compiling all expected output in `harness/` with
`elm make` against the runtime, and running `elm-format --validate` over
it. Blessing, accepting new generator output as the expected output, is
not yet designed, so for now `harness/` holds only a stub module.
