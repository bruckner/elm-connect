# Recipes for working on elm-connect. `just` lists them.

# Elm sources elm-format owns: the harness, the runtime package and its tests.
elm_dirs := "conformance/harness/src src tests"

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
# busy (file is locked)"). A bare `elm make` resolves and writes the
# dependencies, then stops for want of input files; its exit status is ignored
# because a real dependency problem resurfaces in the build that follows (in
# a package, the bare `elm make` also builds the exposed modules).
#
# Compile the runtime package with its documentation checked (`--docs`
# rejects an exposed value without docs, as publishing would), compile the
# conformance harness, and run the runtime's tests.
elm-check:
    -@elm make --output=/dev/null >/dev/null 2>&1
    elm make --docs=elm-stuff/docs.json
    -@cd conformance/harness && elm make --output=/dev/null >/dev/null 2>&1
    cd conformance/harness && elm make src/*.elm --output=/dev/null
    elm-test-rs

# Remove build output.
clean:
    cargo clean
    rm -rf conformance/harness/elm-stuff elm-stuff
