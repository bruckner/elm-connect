# Installing elm-connect

elm-connect is two pieces that share one version number: a generator,
which turns `.proto` files into Elm modules, and the runtime, an Elm
package those modules import. This page installs both, gets the
googleapis files a proto with `google.api.http` rules imports, and says
how to keep the two versions in step.

## The generator

The generator comes as two binaries with the same options and the same
output: a standalone CLI, and a protoc plugin for protoc and buf. Neither
is released yet, so both install from the repository with Cargo:

```sh
cargo install --locked --git https://github.com/bruckner/elm-connect elm-connect
cargo install --locked --git https://github.com/bruckner/elm-connect protoc-gen-elm-connect
```

`--locked` builds with the dependency versions the repository's
`Cargo.lock` pins, which are the ones its CI tests.

- `elm-connect` needs nothing else. It compiles the protos itself, and
  carries `google/api/annotations.proto`, `google/api/http.proto` and
  `google/api/field_behavior.proto`, so a proto importing them compiles
  without a googleapis checkout.
- `protoc-gen-elm-connect` runs under protoc or buf, which must be on
  `PATH`, and finds the plugin on `PATH` by its name. They need the
  googleapis files (below).

`elm-connect --version` and `protoc-gen-elm-connect --version` print
each binary's version.

Prebuilt binaries and an npm package are planned
([roadmap](roadmap.md)).

## The runtime

The generated modules import the runtime's `Proto.*` and `Rpc.*`
modules. The runtime is not on the Elm package index yet, so an
application reads it from a clone of this repository, as one of its
source directories:

```sh
git clone https://github.com/bruckner/elm-connect
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
        "direct": {},
        "indirect": {}
    }
}
```

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

Once the package is published, `elm install bruckner/elm-connect`
replaces the third source directory, and the runtime's own dependencies
come with it. An application then lists `elm/http` and `elm/json`, which
generated code and `Rpc` calls need, `elm/time` when a proto uses
`google.protobuf.Timestamp`, and `elm/bytes` when it generates with
`bytes=bytes`.

## googleapis

A proto with `google.api.http` rules imports
`google/api/annotations.proto`, which imports `google/api/http.proto`.
The CLI carries both. protoc and buf need them from googleapis.

### With protoc

Add a googleapis checkout to the include path with `-I`, or copy the two
files into a directory of their own (keeping their `google/api/` paths)
and add that:

```sh
git clone --depth 1 https://github.com/googleapis/googleapis
protoc -I proto -I googleapis --elm-connect_out=generated greet/v1/greet.proto
```

Without them, protoc stops with `google/api/annotations.proto: File not
found.` The `google/protobuf` files come with protoc.

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
-- Generated by elm-connect 0.1.0 from notes/v1/notes.proto. Do not edit; regenerate instead.
```

and the module names the release it was generated for, which the
runtime's `Proto.Version` must expose:

```elm examples/notes/elm/generated/Notes/V1.elm excerpt
elmConnectVersion_ : Proto.Version.Generated
elmConnectVersion_ =
    Proto.Version.v0_1
```

So a mismatch is a compile error, not a surprise at run time. Code
generated by release 0.2 against the 0.1 runtime stops with:

```text
-- NAMING ERROR ----------------------------------------- generated/Greet/V1.elm

I cannot find a `Proto.Version.v0_2` variable:

20|     Proto.Version.v0_2
        ^^^^^^^^^^^^^^^^^^
The `Proto.Version` module does not expose a `v0_2` variable. These names seem
close though:

    Proto.Version.v0_1
    Proto.Json.any
    Proto.Json.enum
    Proto.Json.int32

Hint: Read <https://elm-lang.org/0.19.2/imports> to see how `import`
declarations work in Elm.
```

Regenerate with the binary matching the runtime, or use the runtime
version the generated code names (`v0_2` is 0.2.x). A runtime accepts
code that an older binary of the same major version generated, so after
upgrading the runtime within a major, regenerating can wait. The design
([§8](design.md)) has the policy.
