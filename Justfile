# Recipes for working on elm-connect. `just` lists them.

# Elm sources elm-format owns: the runtime package, its tests, the live
# runner and the browser example with its tests. The conformance corpus is checked by its own test (`cargo test
# --test conformance`), which runs `elm-format --validate` over the expected
# output.
elm_dirs := "src tests conformance/live/src examples/notes/elm/src examples/notes/elm/tests"

# Cargo's build directory, which the live suite's binaries share
# (target/live). CARGO_TARGET_DIR moves it, as it does for cargo; never
# point several worktrees at one directory (CONTRIBUTING.md says why).
target := absolute_path(env("CARGO_TARGET_DIR", "target"))

[private]
default:
    @just --list

# The gate: everything CI runs, in order.
check: fmt-check clippy test elm-check snippets zizmor gitleaks deny package

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
# tests. Then run the browser example's tests, which test the README
# excerpts that are more than a call (src/Snippets) against the example's
# generated modules. The conformance harness is compiled by `cargo test`.
# The codec round trips' modules are generated first (codec-gen).
elm-check: codec-gen
    -@elm make --output=/dev/null >/dev/null 2>&1
    elm make --docs=elm-stuff/docs.json
    elm-test-rs
    cd examples/notes/elm && elm-test-rs

# Write the codec round trips' Elm under tests/Generated (gitignored): the
# modules generated from conformance/codec under each option set, the
# samples and the codec table. The codec test writes them on every run, so
# `test` does too; elm-check depends on this so it works on a fresh clone.
codec-gen:
    cargo test -p elm-connect-gen --test codec

# Check that every tagged code block of the README, the guides in docs/ and
# the notes example's walkthrough is an excerpt of the file it names
# (examples/check-snippets.sh). The excerpts compile with the example, which
# `example-notes-build` builds; those in its tests run in `elm-check`.
snippets:
    examples/check-snippets.sh README.md docs/install.md docs/quickstart.md docs/generator.md docs/calling.md docs/descriptors.md docs/transcoding.md docs/compared.md examples/notes/README.md

# Audit the GitHub Actions workflows and the Dependabot configuration for
# template injection, unpinned or vulnerable actions, leaked credentials,
# missing update cooldowns and the like. The audits that consult GitHub
# run only when GH_TOKEN is set (CI runs this recipe once more with it);
# without one zizmor runs offline and says so.
zizmor:
    zizmor .

# Scan the history reachable from HEAD for committed secrets. CI fetches
# the full history so the scan covers every commit a pull request would
# land; locally it covers whatever the clone has.
gitleaks:
    gitleaks git --redact --log-opts=HEAD .

# Check the Rust dependencies against deny.toml: security advisories (from
# the RustSec database, which it fetches), licenses, duplicate and wildcard
# versions, and sources. Any failure, an advisory included, fails the gate.
deny:
    cargo deny check

# Package the three crates as `cargo publish` would, and build each package
# alone, so a file a crate needs but does not ship fails here rather than
# at publish. The integration tests are not shipped (each crate's
# Cargo.toml says why), so the packages are built, not tested. Cargo
# refuses a crate with uncommitted changes: commit, then run the gate.
package:
    cargo package --workspace --locked

# Compile the runtime package and the conformance corpus with another Elm
# compiler, such as 0.19.0 or 0.19.1, which CI checks (design section 8).
compile-with elm:
    conformance/compile-with.sh {{elm}}

# Run the runtime package's and the notes example's Elm tests with another
# Elm compiler, as CI does with 0.19.1 (design section 8).
test-with elm:
    conformance/test-with.sh {{elm}}

# Rewrite the conformance corpus's expected output (modules and warnings.txt, or
# diagnostics.txt), and the Elm replay of the route fixtures and the route
# properties (tests/Routes, tests/RouteFixtures.elm, tests/RouteProperties.elm),
# to what the generator produces now. Review the diff before committing it.
bless:
    ELM_CONNECT_BLESS=1 cargo test -p elm-connect-gen --test conformance -- --exact golden diagnostics
    ELM_CONNECT_BLESS=1 cargo test -p elm-connect-gen --test routes -- --exact the_elm_replay_is_current the_route_properties_are_current

# The live suite (design section 7, conformance/README.md): the runtime,
# compiled into conformance/live's headless program and run from Node,
# against the example server over Connect and over transcoding, then the
# route fixtures against its routes.v1 echo service under Vanguard; then the
# transcoding cases and the route fixtures again under grpc-gateway, which
# the server mounts at /gateway; then under Envoy (live-envoy); then the
# Connect conformance suite. Not part of `check`: it needs Go, and the
# network for Go's modules, npm's packages, Envoy and connectconformance
# (buf generates from vendored protos); CI runs it as its own job. It builds
# the browser example too, so the README's excerpts of it compile.
live: live-gen live-build example-notes-build && live-envoy live-conformance
    node conformance/live/run.mjs --serve {{target}}/live/bin/notes-server conformance/live/cases/notes.json
    node conformance/live/run.mjs --serve {{target}}/live/bin/notes-server conformance/live/cases/transcode.json
    node conformance/live/routes.mjs --serve {{target}}/live/bin/notes-server --known conformance/live/known-divergent-vanguard.json
    node conformance/live/run.mjs --serve {{target}}/live/bin/notes-server --prefix /gateway --transport transcode conformance/live/cases/notes.json conformance/live/cases/transcode.json
    node conformance/live/routes.mjs --serve {{target}}/live/bin/notes-server --prefix /gateway --known conformance/live/known-divergent-gateway.json

# Envoy, the live suite's third transcoder: the release func-e runs (one
# line in conformance/live/envoy/envoy-version, which CI's cache is keyed
# on) and the loopback ports `live-envoy` uses, the example server's and
# Envoy's. Move a port here when another program holds it.
envoy_version := trim(read("conformance/live/envoy/envoy-version"))
envoy_origin_port := "18080"
envoy_port := "18081"
envoy_headers_port := "18082"
envoy_admin_port := "18090"

# The live suite under Envoy's gRPC-JSON transcoder (docs/envoy.md): build
# the example's descriptor set with buf, start the example server and Envoy
# (conformance/live/envoy/envoy.yaml, with the ports above), and run the
# transcoding cases and the route fixtures against the listener that turns
# errors into a google.rpc.Status body, and cases/envoy.json against the one
# that leaves them in grpc-status headers. Both stop however the runs end.
live-envoy: live-build envoy-install
    #!/usr/bin/env bash
    set -euo pipefail
    live="{{target}}/live"
    (cd examples/notes && buf build --as-file-descriptor-set -o "$live/notes.binpb")
    sed -e 's/port_value: 18080/port_value: {{envoy_origin_port}}/' \
        -e 's/port_value: 18081/port_value: {{envoy_port}}/' \
        -e 's/port_value: 18082/port_value: {{envoy_headers_port}}/' \
        -e 's/port_value: 18090/port_value: {{envoy_admin_port}}/' \
        -e "s|proto_descriptor: target/live/notes.binpb|proto_descriptor: $live/notes.binpb|" \
        conformance/live/envoy/envoy.yaml > "$live/envoy.yaml"
    "$live/bin/notes-server" -addr 127.0.0.1:{{envoy_origin_port}} > "$live/envoy-origin.log" 2>&1 &
    server=$!
    ENVOY_VERSION={{envoy_version}} func-e run -c "$live/envoy.yaml" --log-level warn > "$live/envoy.log" 2>&1 &
    envoy=$!
    stop() {
        status=$?
        kill "$envoy" "$server" 2> /dev/null || true
        wait 2> /dev/null || true
        if [ "$status" -ne 0 ]; then tail -n 50 "$live/envoy-origin.log" "$live/envoy.log"; fi
    }
    trap stop EXIT
    # /healthz passes through Envoy to the server, so an answer on each
    # listener means both are up.
    for port in {{envoy_port}} {{envoy_headers_port}}; do
        for attempt in $(seq 150); do
            curl -fs --max-time 2 -o /dev/null "http://127.0.0.1:$port/healthz" && break
            kill -0 "$server" 2> /dev/null || { echo "the example server exited"; exit 1; }
            kill -0 "$envoy" 2> /dev/null || { echo "Envoy exited"; exit 1; }
            [ "$attempt" -lt 150 ] || { echo "Envoy is not answering on $port"; exit 1; }
            sleep 0.2
        done
    done
    node conformance/live/run.mjs --server http://127.0.0.1:{{envoy_port}} --origin http://127.0.0.1:{{envoy_origin_port}} --transport transcode conformance/live/cases/notes.json conformance/live/cases/transcode.json
    node conformance/live/routes.mjs --server http://127.0.0.1:{{envoy_port}} --known conformance/live/known-divergent-envoy.json
    node conformance/live/run.mjs --server http://127.0.0.1:{{envoy_headers_port}} conformance/live/cases/envoy.json

# Install the pinned Envoy with func-e unless it is installed. func-e checks
# the archive against the SHA-256 that Tetrate's index lists, but hashes
# only the bytes its unpacker has read when the tar stream ends, which is
# sometimes all of the archive and sometimes not (the last 20 bytes of
# 1.40.0's), so a right archive fails the check now and then, and the binary
# it unpacked is left in place, unchecked. So when func-e's install fails,
# remove what it left, and fetch, check against the same index's digest and
# unpack the archive here.
[private]
envoy-install:
    #!/usr/bin/env bash
    set -euo pipefail
    export ENVOY_VERSION={{envoy_version}}
    func-e run --version > /dev/null 2>&1 && exit 0
    dir="${FUNC_E_DATA_HOME:-$HOME/.local/share/func-e}/envoy-versions/$ENVOY_VERSION"
    rm -rf "$dir"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/versions.json" "${ENVOY_VERSIONS_URL:-https://archive.tetratelabs.io/envoy/envoy-versions.json}"
    platform="${FUNC_E_PLATFORM:-$(go env GOOS)/$(go env GOARCH)}"
    url="$(node -e 'const v = require(process.argv[1]); console.log(v.versions[process.argv[2]].tarballs[process.argv[3]])' "$tmp/versions.json" "$ENVOY_VERSION" "$platform")"
    sum="$(node -e 'console.log(require(process.argv[1]).sha256sums[process.argv[2]])' "$tmp/versions.json" "${url##*/}")"
    echo "func-e could not install Envoy $ENVOY_VERSION; fetching $url"
    curl -fsSL -o "$tmp/envoy.tar.xz" "$url"
    echo "$sum  $tmp/envoy.tar.xz" | shasum -a 256 -c -
    mkdir -p "$dir"
    tar -xJf "$tmp/envoy.tar.xz" -C "$dir" --strip-components 1
    func-e run --version > /dev/null

# Regenerate the example's Go stubs, grpc-gateway's proxies (two templates;
# buf.gen.gateway.yaml says why) and the Elm client with buf, and fail if
# they differ from what is committed (or staged). The plugins are built into
# the build directory's live/bin: protoc-gen-go, protoc-gen-connect-go, protoc-gen-go-grpc and
# protoc-gen-grpc-gateway at the versions the server's go.mod pins,
# protoc-gen-elm-connect from this workspace.
#
# Then generate the Elm again under `buf generate --include-imports`, into
# the build directory's live/include-imports, and fail unless it is the committed set,
# file for file. This proves the plugin, asked for every import, generates
# no `Google.Api` module from the googleapis files that only carry
# `google.api.http`, and none for `google/protobuf`.
live-gen:
    mkdir -p {{target}}/live/bin
    cd examples/notes/server && go build -o {{target}}/live/bin/ google.golang.org/protobuf/cmd/protoc-gen-go connectrpc.com/connect/v2/cmd/protoc-gen-connect-go google.golang.org/grpc/cmd/protoc-gen-go-grpc github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway
    cargo build -p protoc-gen-elm-connect
    cp {{target}}/debug/protoc-gen-elm-connect {{target}}/live/bin/
    cd examples/notes && PATH="{{target}}/live/bin:$PATH" buf generate
    cd examples/notes && PATH="{{target}}/live/bin:$PATH" buf generate --template buf.gen.gateway.yaml
    cd examples/notes && PATH="{{target}}/live/bin:$PATH" buf generate --template buf.gen.gateway-apart.yaml
    cd examples/notes && PATH="{{target}}/live/bin:$PATH" buf generate --template buf.gen.google-rpc.yaml
    git diff --exit-code -- examples/notes/server/gen examples/notes/elm/generated
    @test -z "$(git ls-files --others --exclude-standard -- examples/notes/server/gen examples/notes/elm/generated)" || (echo "generated files not committed:"; git ls-files --others --exclude-standard -- examples/notes/server/gen examples/notes/elm/generated; exit 1)
    rm -rf {{target}}/live/include-imports
    cd examples/notes && PATH="{{target}}/live/bin:$PATH" buf generate --include-imports --template buf.gen.include-imports.yaml -o {{target}}/live/include-imports
    diff -r {{target}}/live/include-imports/elm/generated examples/notes/elm/generated

# Build the example server and the live runner's Elm program. The bare
# `elm make` resolves dependencies first, as in elm-check.
live-build:
    cd examples/notes/server && go vet ./... && go build -o {{target}}/live/bin/notes-server .
    -@cd conformance/live && elm make >/dev/null 2>&1
    cd conformance/live && elm make src/Live.elm --output=build/elm.js

# The Connect conformance suite (design section 7, conformance/README.md):
# connectconformance, fetched at its pinned release, starts its reference
# server and runs its unary JSON test cases through conformance.mjs, once
# with each call sent through the runtime's pure halves and once with
# Rpc.sendTraced. Each run must pass but for its known-failing cases.
# connectconformance reads only the first --known-failing flag, so the second
# run's list is the two files joined.
live-conformance: live-conformance-gen live-build
    #!/usr/bin/env bash
    set -euo pipefail
    cd conformance/live
    runner="$(./fetch-conformance.sh)"
    "$runner" --mode client --conf conformance.yaml --known-failing @known-failing.txt -- node conformance.mjs --send halves
    cat known-failing.txt known-failing-send.txt > build/known-failing-send.txt
    "$runner" --mode client --conf conformance.yaml --known-failing @build/known-failing-send.txt -- node conformance.mjs --send sendTraced

# Install the live runner's npm packages as package-lock.json pins them, and
# regenerate the conformance suite's Elm and JavaScript with buf from its
# vendored protos (conformance/live/suite/proto), failing if they differ
# from what is committed (or staged). protoc-gen-elm-connect is built as in
# live-gen.
live-conformance-gen:
    cd conformance/live && npm ci --ignore-scripts --no-audit --no-fund
    mkdir -p {{target}}/live/bin
    cargo build -p protoc-gen-elm-connect
    cp {{target}}/debug/protoc-gen-elm-connect {{target}}/live/bin/
    cd conformance/live/suite && PATH="{{target}}/live/bin:$PWD/../node_modules/.bin:$PATH" buf generate
    git diff --exit-code -- conformance/live/suite
    @test -z "$(git ls-files --others --exclude-standard -- conformance/live/suite)" || (echo "generated files not committed:"; git ls-files --others --exclude-standard -- conformance/live/suite; exit 1)

# The Buf Schema Registry modules the vendored protos come from, at the
# commits they were exported from; protos-refresh re-exports them.
googleapis_module := "buf.build/googleapis/googleapis:c17df5b2beca46928cc87d5656bd5343" # gitleaks:allow (a BSR commit)
conformance_module := "buf.build/connectrpc/conformance:d37ba00b58084ea7a4480086db6e4be0" # gitleaks:allow (a BSR commit)

# Re-export the vendored protos from the Buf Schema Registry at the commits
# above, with their license files: the googleapis files the notes example
# imports into examples/notes/third_party/googleapis, and the Connect
# conformance suite's into conformance/live/suite/proto. Each directory's
# README.md stays; update its commit and date by hand when a pin moves,
# then run `just live` to regenerate against them.
protos-refresh:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    buf export {{googleapis_module}} --all -o "$tmp/googleapis" \
        --path google/api/annotations.proto \
        --path google/api/http.proto \
        --path google/rpc/error_details.proto
    buf export {{conformance_module}} --all -o "$tmp/conformance"
    dest=examples/notes/third_party/googleapis
    rm -rf "$dest/google" "$dest/LICENSE"
    cp -R "$tmp/googleapis/google" "$tmp/googleapis/LICENSE" "$dest/"
    dest=conformance/live/suite/proto
    rm -rf "$dest/connectrpc" "$dest/LICENSE"
    cp -R "$tmp/conformance/connectrpc" "$tmp/conformance/LICENSE" "$dest/"

# Build the notes example: the server, and the browser application into
# examples/notes/elm/dist (index.html and elm.js, optimized), and compile the
# README's excerpts in src/Snippets with it. The bare `elm make` resolves
# dependencies first, as in elm-check.
example-notes-build:
    mkdir -p {{target}}/live/bin
    cd examples/notes/server && go build -o {{target}}/live/bin/notes-server .
    -@cd examples/notes/elm && elm make >/dev/null 2>&1
    cd examples/notes/elm && elm make --optimize src/Main.elm --output=dist/elm.js
    cd examples/notes/elm && elm make src/Snippets/*.elm --output=/dev/null
    cp examples/notes/elm/index.html examples/notes/elm/dist/

# Build the notes example and serve it: the page and the API on one origin,
# http://127.0.0.1:8080 unless `addr` says otherwise. Ctrl-C stops it.
example-notes addr="127.0.0.1:8080": example-notes-build
    {{target}}/live/bin/notes-server -addr {{addr}} -static examples/notes/elm/dist

# Remove build output (the cargo build directory and the Elm builds).
clean:
    cargo clean
    rm -rf conformance/harness/elm-stuff conformance/harness/generated elm-stuff tests/Generated
    rm -rf conformance/live/elm-stuff conformance/live/build conformance/live/node_modules
    rm -rf examples/notes/elm/elm-stuff examples/notes/elm/dist
