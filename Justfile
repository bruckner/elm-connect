# Recipes for working on elm-connect. `just` lists them.

# Elm sources elm-format owns: the runtime package, its tests and the live
# runner. The conformance corpus is checked by its own test (`cargo test
# --test conformance`), which runs `elm-format --validate` over the expected
# output.
elm_dirs := "src tests conformance/live/src"

[private]
default:
    @just --list

# The gate: everything CI runs, in order.
check: fmt-check clippy test elm-check zizmor gitleaks

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

# Audit the GitHub Actions workflows for template injection, unpinned
# or vulnerable actions, leaked credentials and the like. The audits
# that consult GitHub run only when GH_TOKEN is set (CI sets it); without
# one zizmor runs offline and says so.
zizmor:
    zizmor .github/workflows

# Scan the history reachable from HEAD for committed secrets. CI fetches
# the full history so the scan covers every commit a pull request would
# land; locally it covers whatever the clone has.
gitleaks:
    gitleaks git --redact --log-opts=HEAD .

# Compile the runtime package and the conformance corpus with another Elm
# compiler, such as 0.19.0 or 0.19.1, which CI checks (design section 8).
compile-with elm:
    conformance/compile-with.sh {{elm}}

# Rewrite the conformance corpus's expected output (modules and warnings.txt, or
# diagnostics.txt), and the Elm replay of the route fixtures (tests/Routes,
# tests/RouteFixtures.elm), to what the generator produces now. Review the
# diff before committing it.
bless:
    ELM_CONNECT_BLESS=1 cargo test -p elm-connect-gen --test conformance -- --exact golden diagnostics
    ELM_CONNECT_BLESS=1 cargo test -p elm-connect-gen --test routes -- --exact the_elm_replay_is_current

# The live suite (design section 7, conformance/README.md): the runtime,
# compiled into conformance/live's headless program and run from Node,
# against the example server over Connect and over transcoding, then the
# route fixtures against its routes.v1 echo service under Vanguard. Not
# part of `check`: it needs Go and the Buf Schema Registry; CI runs it as
# its own job.
live: live-gen live-build
    node conformance/live/run.mjs --serve target/live/bin/notes-server conformance/live/cases/notes.json
    node conformance/live/run.mjs --serve target/live/bin/notes-server conformance/live/cases/transcode.json
    node conformance/live/routes.mjs --serve target/live/bin/notes-server

# Regenerate the example's Go stubs and Elm client with buf, and fail if
# they differ from what is committed (or staged). The plugins are built into
# target/live/bin: protoc-gen-go and protoc-gen-connect-go at the versions the
# server's go.mod pins, protoc-gen-elm-connect from this workspace.
live-gen:
    mkdir -p target/live/bin
    cd examples/notes/server && go build -o ../../../target/live/bin/ google.golang.org/protobuf/cmd/protoc-gen-go connectrpc.com/connect/v2/cmd/protoc-gen-connect-go
    cargo build -p protoc-gen-elm-connect
    cp target/debug/protoc-gen-elm-connect target/live/bin/
    cd examples/notes && PATH="$PWD/../../target/live/bin:$PATH" buf generate
    git diff --exit-code -- examples/notes/server/gen examples/notes/elm/generated
    @test -z "$(git ls-files --others --exclude-standard -- examples/notes/server/gen examples/notes/elm/generated)" || (echo "generated files not committed:"; git ls-files --others --exclude-standard -- examples/notes/server/gen examples/notes/elm/generated; exit 1)

# Build the example server and the live runner's Elm program. The bare
# `elm make` resolves dependencies first, as in elm-check.
live-build:
    cd examples/notes/server && go vet ./... && go build -o ../../../target/live/bin/notes-server .
    -@cd conformance/live && elm make >/dev/null 2>&1
    cd conformance/live && elm make src/Live.elm --output=build/elm.js

# Remove build output.
clean:
    cargo clean
    rm -rf conformance/harness/elm-stuff conformance/harness/generated elm-stuff
    rm -rf conformance/live/elm-stuff conformance/live/build
