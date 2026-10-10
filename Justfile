# Recipes for working on elm-connect. `just` lists them.

# Elm sources elm-format owns: the runtime package and its tests. The
# conformance corpus is checked by its own test (`cargo test --test
# conformance`), which runs `elm-format --validate` over the expected output.
elm_dirs := "src tests"

[private]
default:
    @just --list

# The gate: everything CI runs, in order.
check: fmt-check clippy test elm-check

# Format Rust and Elm sources in place.
fmt:
    cargo fmt --all
    elm-format --yes {{elm_dirs}}

# Fail if any Rust or Elm source is not formatted.
fmt-check:
    cargo fmt --all --check
    elm-format --validate {{elm_dirs}}

# Lint every crate and target; warnings are errors.
clippy:
    cargo clippy --workspace --all-targets -- -D warnings

# Run the Rust tests.
test:
    cargo test --workspace

# Elm's first build in a fresh elm-stuff writes d.dat twice: once from a
# background thread after resolving dependencies and again when the build
# finishes. On a slow disk the two collide ("d.dat: withBinaryFile: resource
# busy (file is locked)"). A bare `elm make` first resolves and writes the
# dependencies (in a package it also builds the exposed modules); its exit
# status is ignored because a real problem resurfaces in the build that
# follows. The conformance test does the same for the harness.
#
# Compile the runtime package with its documentation checked (`--docs`
# rejects an exposed value without docs, as publishing would), and run its
# tests. The conformance harness is compiled by `cargo test`.
elm-check:
    -@elm make --output=/dev/null >/dev/null 2>&1
    elm make --docs=elm-stuff/docs.json
    elm-test-rs

# Compile the runtime package and the conformance corpus with another Elm
# compiler, such as 0.19.1, which CI checks (design section 8).
compile-with elm:
    conformance/compile-with.sh {{elm}}

# Rewrite the conformance corpus's expected output (modules, or
# diagnostics.txt) to what the generator produces now. Review the diff
# before committing it.
bless:
    ELM_CONNECT_BLESS=1 cargo test -p elm-connect-gen --test conformance -- --exact golden diagnostics

# Remove build output.
clean:
    cargo clean
    rm -rf conformance/harness/elm-stuff conformance/harness/generated elm-stuff
