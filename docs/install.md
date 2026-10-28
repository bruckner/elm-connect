# Installing elm-connect

elm-connect is two pieces that share one version number: a generator,
which turns `.proto` files into Elm modules, and the runtime, an Elm
package those modules import. This page installs both, gets the
googleapis files a proto with `google.api.http` rules imports, and says
how to keep the two versions in step.

## The generator

The generator comes as two binaries with the same options and the same
output: a standalone CLI, and a protoc plugin for protoc and buf. Each
release attaches both, built for six platforms, to its page under the
repository's [Releases](https://github.com/bruckner/elm-connect/releases);
Cargo builds them from source.

- `elm-connect` needs nothing else. It compiles the protos itself, and
  carries `google/api/annotations.proto`, `google/api/http.proto` and
  `google/api/field_behavior.proto`, so a proto importing them compiles
  without a googleapis checkout.
- `protoc-gen-elm-connect` runs under protoc or buf, which must be on
  `PATH`, and finds the plugin on `PATH` by its name. They need the
  googleapis files (below).

`elm-connect --version` and `protoc-gen-elm-connect --version` print
each binary's version.

### Prebuilt binaries

A release has one archive per platform,
`elm-connect-<version>-<target>.tar.gz`, holding both binaries and the
license files, and `SHA256SUMS`, the checksums of every archive:

| Platform | `<target>` |
|---|---|
| Linux, x86-64 | `x86_64-unknown-linux-musl` |
| Linux, arm64 | `aarch64-unknown-linux-musl` |
| macOS, Intel | `x86_64-apple-darwin` |
| macOS, Apple silicon | `aarch64-apple-darwin` |
| Windows, x86-64 | `x86_64-pc-windows-msvc` (a `.zip`) |
| Windows, arm64 | `aarch64-pc-windows-msvc` (a `.zip`) |

The Linux binaries are statically linked against musl, so they run on
any distribution. Download the archive and `SHA256SUMS`, check one
against the other, and check that the archive was built from this
repository by its release workflow (with the [GitHub CLI](https://cli.github.com)):

```sh
version=0.1.0
target=aarch64-apple-darwin
base=https://github.com/bruckner/elm-connect/releases/download/$version
curl -fLO "$base/elm-connect-$version-$target.tar.gz"
curl -fLO "$base/SHA256SUMS"
sha256sum --check SHA256SUMS --ignore-missing
gh attestation verify "elm-connect-$version-$target.tar.gz" --repo bruckner/elm-connect
```

`--ignore-missing` skips the archives not downloaded. Where there is no
`sha256sum`, `shasum -a 256 --check --ignore-missing SHA256SUMS` does
the same; a good archive gets `OK`. `gh attestation verify` exits 0
when the archive's attestation checks out and non-zero when it does not.
Outside a terminal, as in a script or CI, a success prints nothing at
all, so read the exit status (`echo $?`).

The archive has no top-level directory: it holds `elm-connect`,
`protoc-gen-elm-connect`, `LICENSE-MIT`, `LICENSE-APACHE` and
`THIRD_PARTY.md` side by side. Unpack it into a directory of its own,
then put both binaries in a directory on `PATH` (`~/.local/bin` here;
add it to `PATH` if it is not there already):

```sh
mkdir elm-connect-$version
tar xzf "elm-connect-$version-$target.tar.gz" -C elm-connect-$version
install -d ~/.local/bin
install elm-connect-$version/elm-connect elm-connect-$version/protoc-gen-elm-connect ~/.local/bin/
elm-connect --version
```

On Windows, check the `.zip` the same way (`sha256sum` is in Git Bash;
in PowerShell, compare `(Get-FileHash <archive>).Hash` with its line in
`SHA256SUMS`), unpack it with `Expand-Archive`, and put
`elm-connect.exe` and `protoc-gen-elm-connect.exe` in a directory on
`PATH`. The binaries are not signed, so macOS refuses to run one a
browser downloaded until `xattr -d com.apple.quarantine <binary>`
clears the mark, and Windows SmartScreen may ask once; `curl`
downloads are not marked.

[SECURITY.md](../SECURITY.md#verifying-a-release) says what a release is
built from and what the two checks prove.

### With Cargo

Cargo builds both binaries from their crates on crates.io, with the
Rust version the crates declare (their `rust-version`) or newer:

```sh
cargo install --locked elm-connect
cargo install --locked protoc-gen-elm-connect
```

Each installs the latest release; `--version 0.1.0` picks one.
`--locked` builds with the dependency versions the release's
`Cargo.lock` pins, which are the ones its CI tests.

An npm package that fetches the right binary is on the
[roadmap](roadmap.md).

## The runtime

The generated modules import the runtime's `Proto.*` and `Rpc.*`
modules. From 1.0.0 the runtime is on the Elm package index:

```sh
elm install bruckner/elm-connect
```

and the runtime's own dependencies come with it. An application then
lists `elm/http` and `elm/json`, which generated code and `Rpc` calls
need, `elm/time` when a proto uses `google.protobuf.Timestamp`, and
`elm/bytes` when it generates with `bytes=bytes`.

The index takes no version below 1.0.0, so before then an application
reads the runtime from a clone of this repository, checked out at the
tag of the release it generates with, as one of its source
directories:

```sh
git clone https://github.com/bruckner/elm-connect
git -C elm-connect checkout 0.1.0
```

Add the clone's `src` to the application's `source-directories`, and
install the four packages the runtime imports (below says why each).
`elm install` takes one package at a time, and asks before changing
`elm.json`:

```sh
elm install elm/http
elm install elm/json
elm install elm/time
elm install elm/bytes
```

A complete `elm.json` for a browser application outside this
repository, with the generated modules in `generated/`:

```json
{
    "type": "application",
    "source-directories": [
        "src",
        "generated",
        "<path to your clone>/src"
    ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": {
            "elm/browser": "1.0.2",
            "elm/bytes": "1.0.8",
            "elm/core": "1.0.5",
            "elm/html": "1.0.1",
            "elm/http": "2.0.0",
            "elm/json": "1.1.4",
            "elm/time": "1.0.0"
        },
        "indirect": {
            "elm/file": "1.0.5",
            "elm/url": "1.0.0",
            "elm/virtual-dom": "1.0.5"
        }
    },
    "test-dependencies": {
        "direct": {
            "elm-explorations/test": "2.2.1"
        },
        "indirect": {
            "elm/random": "1.0.0"
        }
    }
}
```

The test dependencies are what `elm-test-rs init` adds, for tests such
as the [quick start's](quickstart.md#7-test-without-a-server); an
application without tests leaves them empty.

The path to the clone may be relative to the `elm.json` or absolute.
Every package the runtime imports must be a direct dependency, since
Elm compiles a source directory's modules as the application's own:

- `elm/http`: the runtime sends calls with it.
- `elm/json`: the generated codecs and the runtime's JSON helpers.
- `elm/time`: the runtime reads `google.protobuf.Timestamp` as a
  `Time.Posix`, and its retry loop reads the clock, whether or not the
  protos use a `Timestamp`.
- `elm/bytes`: the runtime's `Proto.Bytes` and `Proto.Json` import it,
  whether or not the protos use `bytes`.
- `elm/core`, and `elm/browser` and `elm/html` for a browser
  application, as for any.

Leave one of the four out and the build stops at the first runtime
module that imports it, with `MODULE NOT FOUND` and the import, such as
`import Bytes exposing (Bytes)` in `src/Proto/Bytes.elm`.

The runtime compiles with Elm 0.19.0, 0.19.1 and 0.19.2; set
`elm-version` to the compiler the application uses.

### Building in CI

A clone beside the application resolves on one machine only. An
application whose client CI builds needs the runtime inside its own
repository: copy the release tag's `src/` and `LICENSE` into it, with
the package's `elm.json` beside them if your licence tooling reads
package metadata, and point `source-directories` at the copy. Leave the
copy unchanged, and replace it whole when you move to another release,
together with the generator. A generated module that does not match
the copy's release stops the build at `Proto.Version`
([Versions](#versions)).

The runtime is compiled into the application's bundle, so its licence
notice ships wherever the application publishes its other
dependencies' notices. Put the copy where licence and bill-of-materials
tooling treats it as third-party code: a tool that takes every source
directory inside the client for the application's own would compile it
in without a notice.

Pin the CLI to the same release in the tool manager CI uses; the
release archives hold the two binaries at their top level. Then run
`elm-connect check` in CI with the same arguments as `gen`: `gen` never
deletes a module, so only `check` names one the protos no longer
produce ([generator.md](generator.md#checking-generated-code-elm-connect-check)).

## googleapis

A proto with `google.api.http` rules imports
`google/api/annotations.proto`, which imports `google/api/http.proto`.
The CLI carries both, and `google/api/field_behavior.proto`, and no other
googleapis file: a proto that imports another, such as
`google/api/resource.proto` or `google/api/client.proto`, needs a
googleapis checkout on the CLI's `-I` too. The CLI looks for an import
under each `-I` directory in order, then among protobuf's own
`google/protobuf` files, and only then among the three it carries, so a
copy on the include path wins. protoc and buf need all of them from
googleapis.

### With protoc

Add a googleapis checkout to the include path with `-I`, or copy the two
files into a directory of their own (keeping their `google/api/` paths)
and add that:

```sh
git clone --depth 1 https://github.com/googleapis/googleapis
mkdir -p generated
protoc -I proto -I googleapis --elm-connect_out=generated notes/v1/notes.proto
```

The proto is named by its path under its `-I` directory, here
`proto/notes/v1/notes.proto`, and protoc writes only into an out
directory that exists. Without the googleapis files, protoc stops with
`google/api/annotations.proto: File not found.` The `google/protobuf`
files come with protoc.

### With buf

Depend on the googleapis module of the Buf Schema Registry. A project
with its protos under `proto/` needs a `buf.yaml`:

```yaml
version: v2
modules:
  - path: proto
deps:
  - buf.build/googleapis/googleapis
```

and a `buf.gen.yaml`:

```yaml
version: v2
plugins:
  - local: protoc-gen-elm-connect
    out: generated
```

then:

```sh
buf dep update    # writes buf.lock, pinning the googleapis commit
buf generate
```

buf hands the googleapis files to the plugin as imports, so nothing is
generated from them. The notes example
([`examples/notes/buf.yaml`](../examples/notes/buf.yaml)) vendors the
files it imports instead, so it generates without the network.

[generator.md](generator.md) has the options, and what each binary
generates when asked for the imported files too.

## Versions

The Elm package and the two binaries share one version number and are
released together. Generate with the binary whose version matches the
package the application uses.

The first line of every generated module names the exact version that
wrote it:

```elm examples/notes/elm/generated/Notes/V1.elm excerpt
-- Generated by elm-connect 0.2.0 from notes/v1/notes.proto. Do not edit; regenerate instead.
```

and the module names the release it was generated for, which the
runtime's `Proto.Version` must expose:

```elm examples/notes/elm/generated/Notes/V1.elm excerpt
elmConnectVersion_ : Proto.Version.Generated
elmConnectVersion_ =
    Proto.Version.v0_2
```

So a mismatch is a compile error, not a surprise at run time. Code
generated by release 0.1 against the 0.2 runtime stops with:

```text
-- NAMING ERROR ----------------------------------------- generated/Greet/V1.elm

I cannot find a `Proto.Version.v0_1` variable:

20|     Proto.Version.v0_1
        ^^^^^^^^^^^^^^^^^^
The `Proto.Version` module does not expose a `v0_1` variable. These names seem
close though:

    Proto.Version.v0_2
    Proto.Json.any
    Proto.Json.enum
    Proto.Json.int32

Hint: Read <https://elm-lang.org/0.19.2/imports> to see how `import`
declarations work in Elm.
```

Regenerate with the binary matching the runtime, or use the runtime
version the generated code names (`v0_1` is 0.1.x). From 1.0 on, a
runtime accepts code that an older binary of the same major version
generated, so after upgrading the runtime within a major, regenerating
can wait; before 1.0 a minor release may change the generated code, and
0.2 does, so regenerate with each one. The design
([§8](design.md#8-compatibility-and-versioning)) has the policy.
