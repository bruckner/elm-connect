# Depending on connect-web instead of a hand-written core

Measured 2026-10-24 with `@connectrpc/connect-web` 2.2.0, `@connectrpc/connect`
2.2.0 and `@bufbuild/protobuf` 2.16.0, installed in `spike/connect-web-scratch/`
(not the repository's `package.json`), bundled by esbuild 0.28.2 with
`--bundle --minify --format=esm`, gzipped with `gzip -9`.

## Size

| bundle | minified | min+gz |
|---|---:|---:|
| `runtime/stream.js` (all four framings, client, cancel, timeout) | 4,769 B | **2,127 B** |
| `createConnectTransport` alone | — | 32,213 B |
| the adapter below (same event surface as the core, over connect-web) | 116,897 B | **32,648 B** |
| `createConnectTransport` + `createClient` | 120,721 B | 33,043 B |

The transport alone brings most of `@bufbuild/protobuf`'s runtime (reflection,
binary and JSON codecs, the descriptor model) because it parses and serializes
messages itself; nothing of it is tree-shaken away for a transport that only
streams JSON. For comparison, the notes example's Elm with one unary call is
21 KB min+gz, so connect-web would more than double an Elm application's
JavaScript.

## What it would require of an Elm application

- **No generated protobuf-es schemas are strictly needed.** `transport.stream`
  takes a `DescMethod` whose `input` and `output` are message schemas, and it
  parses each frame with `fromJson(schema, …)`. Handing it
  `google.protobuf.Value`'s schema (`ValueSchema` from
  `@bufbuild/protobuf/wkt`) for both makes any JSON pass through, and a
  `DescMethod` can be written by hand at run time with only `parent.typeName`,
  `name` and `methodKind` read for the URL and headers
  (`connect-web-scratch/adapter.js`, 40 lines). Run against the notes server
  (`connect-web-scratch/try.mjs`), it streams `WatchNotes`' messages and its
  end-stream error. This is undocumented use of the descriptor types: a
  connect-web minor could read more of `DescMethod`.
- **The application's build must bundle npm packages.** An Elm application
  served as `elm make` output plus one script tag would gain a bundler, or an
  ESM CDN import of three packages pinned together.
- **Frames are parsed twice and re-serialized**: JSON text → `Value` message →
  `toJson` → `JSON.stringify` → the port → Elm's decoder. The core passes the
  frame's text straight through.
- **The error arrives in connect-es's shape, not the wire's**: `ConnectError`
  with a numeric `code`, `rawMessage`, and `details` whose `value` is a
  `Uint8Array` with the `debug` JSON dropped. The adapter would have to
  re-encode it to the Connect wire form (code name, base64 `value`) for
  `Rpc.Stream.event`, or Elm would need a second error decoder; the typed
  detail Elm reads today from `debug` would need binary protobuf decoding,
  which the runtime does not have.
- **Transcoders' framings are not there.** connect-web speaks Connect and
  gRPC-Web only; NDJSON, the JSON array and SSE would still need the core's
  parsers.

## What it gives

- gRPC-Web (`createGrpcWebTransport`), which the core does not speak.
- Compression (`gzip` on Connect streams), which the core refuses.
- Interceptors, which `Rpc.Config` deliberately has no place for (design §5.1).
- Envelope parsing proven against the Connect conformance suite. The core's is
  ~60 lines tested at every split point and against connect-go, but has not
  run the conformance suite's streaming cases.

## Verdict

**Hand-written core.** For JSON over Connect and the transcoders it is 2 KB
against 32 KB, passes frames through untouched, keeps the error in the wire
shape `Rpc.Error` already reads, and covers the three transcoder framings that
connect-web lacks. What connect-web adds (gRPC-Web, compression, interceptors)
is either on the roadmap as its own item or contrary to the design's
no-hooks config. A thin connect-web adapter stays possible, since the port
protocol (`open`/`cancel` in, `headers`/`message`/`end`/`error` out) is the
seam: an application that already ships connect-web could swap
`adapter.js` in for `stream.js`, at the cost of the error re-encoding above.
Offering both is not worth the second surface before anyone asks; the
conformance suite's server-streaming cases, run against the core in run 2, are
the better answer to "is the parsing right".
