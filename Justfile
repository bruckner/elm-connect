# Recipes for working on elm-connect. `just` lists them.

# Elm sources elm-format owns: the harness, and the runtime once it exists.
elm_dirs := "conformance/harness/src" + if path_exists("src") == "true" { " src" } else { "" }

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
# because a real dependency problem resurfaces in the build that follows.
#
# Compile the conformance harness, and run the Elm tests if there are any.
elm-check:
    -@cd conformance/harness && elm make --output=/dev/null >/dev/null 2>&1
    cd conformance/harness && elm make src/*.elm --output=/dev/null
    @if [ -d tests ]; then elm-test-rs; else echo "elm-check: no tests/ yet; skipping elm-test-rs"; fi

# Remove build output.
clean:
    cargo clean
    rm -rf conformance/harness/elm-stuff elm-stuff
