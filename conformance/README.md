# Conformance

The conformance corpus pins what the generator emits (`docs/design.md`
§7). Each case is a directory under `cases/`:

```
cases/<case>/
  options.txt            optional: the generator's options, as a protoc
                         plugin parameter on one line (`int64=int`)
  input/                 .proto files; all of them are compiled and generated
  include/               optional: .proto files the input may import, which
                         are compiled but not requested
  expected/
    <Module/Path>.elm    the Elm generated from the input, one file per module
    warnings.txt         beside the modules, when generating warns: the
                         warnings (`streaming=skip`'s skipped methods)
  or
    diagnostics.txt      the problems generating reports instead
```

A case expects either modules or `diagnostics.txt`, never both. Inputs are
compiled with protox, with `input/` and `include/` as the include paths,
and every file under `input/` is requested; nothing under `include/` is.
A requested package is generated whole (design §3.1), so an `include/`
file of a requested package is in its module (`packages_whole` case);
one of any other package is not generated. Without `options.txt` a
case is generated with the default options.

## The checks

`crates/elm-connect-gen/tests/conformance.rs` runs four tests over every
case; `just check` runs them with the other Rust tests.

- **golden**: regenerating each modules case gives exactly its expected
  files, byte for byte, none missing and none extra, and warns exactly
  its `warnings.txt`, rendered as `diagnostics.txt` is, or not at all
  when it has none. A failure shows a unified diff. A unit test in the
  same file exercises the warnings' mismatch and blessing paths.
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

The tests use the pinned compiler, Elm 0.19.2. `compile-with.sh` runs the
compiles check, and builds the runtime package, with another one:

```sh
conformance/compile-with.sh path/to/elm   # or: just compile-with path/to/elm
```

CI runs it with Elm 0.19.0 and 0.19.1 (design §8).

## Blessing

Blessing accepts the generator's current output as the expected output:

```sh
just bless
```

runs the golden and diagnostics tests with `ELM_CONNECT_BLESS=1`, which
rewrites each case's `expected/` (adding, replacing and deleting modules
and `warnings.txt`, or rewriting `diagnostics.txt`) instead of comparing. Read the diff before
committing it: the blessed output is what users will maintain against.

To add a case, create `cases/<name>/input/` with its protos and bless. For
a case that is meant to fail, create an empty `expected/diagnostics.txt`
first, then bless.

## Route fixtures

`routes/` pins what HTTP request a request becomes under a
`google.api.http` rule (design §7). `routes/routes.proto` declares the
request messages and one service whose methods carry the rules (all but
one, which has none); each `routes/*.json` file holds fixtures:

```json
{
  "name": "fields outside the path become query parameters",
  "method": "routes.v1.Routes.GetMessage",
  "binding": 2,
  "rule": { "verb": "GET", "template": "/v1/messages/{message_id}", "body": "" },
  "request": { "messageId": "123456", "revision": "2", "sub": { "subfield": "foo" } },
  "expect": {
    "path": "/v1/messages/123456",
    "query": [["revision", "2"], ["sub.subfield", "foo"]],
    "body": null
  }
}
```

`binding` is `0` for the rule's own and `n` for its `n`th additional
binding; `rule` repeats that binding so the file reads without the proto.
A method without a rule has `"binding": null` and `"rule": null`, and
expects the implicit route: `POST /<package>.<Service>/<Method>` with
the request as its body and `Connect-Protocol-Version: 1`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and
Vanguard serve (`implicit.json`; the live suite below runs it against
Vanguard). `request` is proto3 JSON. `path`
(custom verb included) and the query pairs are as sent,
percent-encoded; `headers`, optional and `[]` when absent, are those
the route itself adds; `body` is JSON or `null` for none.
Bodies compare after dropping `null`s and default values, which a writer
may omit or spell out. Nothing in a fixture is specific to this client,
so a server-side implementation can check itself against the same file.

`crates/elm-connect-gen/tests/routes.rs` holds both ends to them:

- the rule each fixture names is the binding the generator reads, and a
  reference implementation over protobuf's own model of the request
  (prost-reflect's proto3 JSON parser and field presence) turns the
  generated route and the request into the expectation;
- the modules generated from `routes.proto` (`tests/Routes/V1.elm` and
  the service's `tests/Routes/V1/Routes.elm`) and the fixtures as Elm
  data (`tests/RouteFixtures.elm`) are pinned in the runtime's tests,
  where `tests/RouteFixturesTest.elm` replays each through `Rpc.request`
  with the Transcode transport, applying the generated function of the
  fixture's method and choosing its binding with `Rpc.viaBinding`; a
  fixture naming a binding the method lacks fails. `just bless` rewrites
  all three.

To add a fixture, add it to a `routes/*.json` file (and a method to
`routes.proto` if no rule fits), check that the reference agrees, and
bless. `just live` then runs it against Vanguard ("The route fixtures,
live", below); a change to `routes.proto` is regenerated by `just
live-gen`.

## Live verification

The corpus and the fixtures pin what is generated and what request a
call becomes; `live/` runs the runtime against a server (design §7,
live verification):

```
live/
  elm.json            an application: the runtime's ../../src, the example's
                      generated Elm (examples/notes/elm/generated), src/
  src/Live.elm        a headless Platform.worker: envelopes in on the
                      `requests` port, results out on `results`
  src/Live/Call.elm   the envelope, and `entry`, which makes a dispatch
                      table's entry from a generated call function and codecs
  src/Live/Notes.elm  the dispatch table of notes.v1.NotesService
  src/Live/Conformance.elm
                      the dispatch table of the Connect conformance suite's
                      ConformanceService (its unary methods)
  src/Live/Routes.elm the dispatch table of routes.v1.Routes (routes/)
  xhr.mjs             an XMLHttpRequest over node:http, the subset elm/http
                      uses, reporting each exchange
  run.mjs             loads build/elm.js; a module (`createRunner`,
                      `runCases`, `mismatches`, `serve`) and a command
  cases/notes.json    the smoke suite
  conformance.mjs     the client under test for the Connect conformance suite
  conformance.yaml    the features the suite tests (what the runtime supports)
  known-failing.txt   the suite's test cases the runtime fails, with reasons
  known-failing-send.txt
                      those it fails too when sent with Rpc.sendTraced
  fetch-conformance.sh
                      fetches connectconformance at its pinned release
  suite/              buf.gen.yaml, and the Elm (elm/) and JavaScript (js/)
                      generated from the suite's protos
  package.json        @bufbuild/protobuf and protoc-gen-es, pinned with
                      package-lock.json
  build/              the compiled program and connectconformance (gitignored)
  cases/transcode.json  error bodies over REST, as sent and as read
  routes.mjs          the route fixtures, live (below)
  known-divergent.json  where Vanguard and the fixtures part
  build/              the compiled program (gitignored)
```

```sh
just live                                     # regenerate, build, start the server, run
node conformance/live/run.mjs --server http://127.0.0.1:8080 conformance/live/cases/notes.json
node conformance/live/run.mjs --serve target/live/bin/notes-server --print conformance/live/cases/notes.json
```

`just live` regenerates the example with buf and fails if the output
differs from what is committed, builds the server and `Live.elm`
(unoptimized), starts the server on a free port and runs the suite.
`--print` prints each result instead of checking it.

An **envelope**, what the runner sends:

```json
{
  "id": "a name for the call",
  "service": "notes.v1.NotesService",
  "method": "GetNote",
  "request": { "name": "notes/welcome" },
  "transport": "connect",
  "config": {
    "baseUrl": "http://127.0.0.1:8080",
    "headers": [["x-echo", "hi"]],
    "timeout": 500,
    "withCredentials": false,
    "useGet": false,
    "maxGetUrl": null,
    "retry": { "attempts": 2, "backoff": 10, "codes": ["unavailable"], "idempotentOnly": false }
  },
  "binding": null,
  "send": "sendTraced",
  "tracker": null,
  "cancelAfterMs": null
}
```

`request` is proto3 JSON (`{}` when absent); `transport` is `connect` or
`transcode`; everything in `config` but `baseUrl` is optional, as are
`binding` (applied with `Rpc.viaBinding`), `send` (`sendTraced`, the
default, `send`, `task` or `halves`), `tracker` (`Rpc.withTracker`) and
`cancelAfterMs`. `halves` sends through the pure halves, as an application
that needs the answer's headers does: `Rpc.request`, `Http.request` with the
answer kept whole, and `Rpc.response`.

With `cancelAfterMs` the runner cancels the call that many milliseconds
after sending it with `Rpc.cancel`, under the envelope's tracker or, without
one, its `id`, and reports whichever outcome comes first, the result or
`{"canceled": true}`; a later one is dropped, so a call is reported once.
Only `send` without a retry policy and `halves` put the tracker on the
request; `sendTraced`, `task` and `send` with a retry policy ignore it, so an
envelope sending one of those with `cancelAfterMs` is refused (`{"runner":
…}`) rather than reported `Canceled` while the call runs on.

A **result**, what comes back:

```json
{
  "id": "a name for the call",
  "result": { "ok": { "name": "notes/welcome" } },
  "trace": {
    "service": "notes.v1.NotesService", "method": "GetNote", "binding": null,
    "httpStatus": 200, "code": "ok", "attempts": 1, "duration": 4,
    "request": { "method": "POST", "url": "…", "headers": [["Connect-Protocol-Version", "1"]],
                 "body": "{\"name\":\"notes/welcome\"}", "timeout": null, "withCredentials": false }
  },
  "progress": { "sending": 1, "receiving": 1 },
  "wire": [{ "method": "POST", "url": "…", "requestHeaders": [], "body": "…", "timeout": 0,
             "withCredentials": false, "status": 200, "responseHeaders": {},
             "responseBody": "{…}", "outcome": "load" }]
}
```

`result` is one of `{"ok": <response as proto3 JSON>}`, `{"error":
{"code", "message", "details", "source", "response"}}` (the code as
Connect names it, each detail as `Proto.Any.encodeJson` writes it, the
source as `ConnectBody`, `StatusBody`, `GrpcHeaders` or `HttpStatus`
for a code inferred from the status, and `response` the answer the
error was read from: `statusCode`, `statusText` and `body`),
`{"transport": "Timeout"}` (or `NetworkError`, `BadUrl <url>`,
`BadStatus <n>`, `BadBody <problem>`), `{"canceled": true}` for a call
withdrawn with `Rpc.cancel`, and `{"runner": <why>}` for an
envelope the runner could not send: one that does not decode, an unknown
method or a binding the method lacks. `trace` is the `Rpc.Trace`, and
`null` unless sent with `sendTraced`; `response` is the answer's
`{"status", "headers": [[name, value], …]}` as elm/http gives it, and
`null` unless sent with `halves` and answered; `progress` counts a tracker's
events and is present only with one. `wire` is added by `run.mjs`: each
HTTP exchange made during the call, as `xhr.mjs` saw it (`outcome` is
`load`, `error`, `timeout` or `abort`, or `pending` for one still open). Calls run one at a time, so every
exchange belongs to its call.

A **case file** is a JSON array of cases, run in order:

```json
{
  "name": "connect GetNote",
  "note": "optional prose",
  "call": { "service": "…", "method": "…", "request": {}, "transport": "connect", "config": {} },
  "expect": { "result": { "ok": { "name": "notes/welcome" } }, "trace": { "attempts": 1 } },
  "skip": "optional: why the case is not run"
}
```

`call` is an envelope without `id` (the case's name) whose `baseUrl`
defaults to the server's, `{server}` standing for it in one given.
`expect` is matched against the result: an object matches when each of
its keys does, other keys ignored; an array element by element, with
the same length; anything else by equality. `{"$match": "<regex>"}`
matches a string the expression finds, `{"$json": …}` a string whose
JSON parse matches, `{"$contains": […]}` an array with a match for each
element, and `{"$absent": true}` a key that is missing or `null`.

To add a service, add its proto to the example (or a new one beside
it), a dispatch table `src/Live/<Service>.elm` listing `entry` per
method, and the table to `tables` in `Live.elm`.

## The Connect conformance suite

`just live-conformance` (part of `just live`) runs the official
[Connect conformance suite](https://github.com/connectrpc/conformance)
against the runtime (design §7, live verification), at v1.0.6:

```sh
just live-conformance
# by hand, from conformance/live once `just live-conformance-gen live-build` has run:
"$(./fetch-conformance.sh)" --mode client --conf conformance.yaml \
  --known-failing @known-failing.txt -- node conformance.mjs --send halves
```

`fetch-conformance.sh` downloads `connectconformance` from the suite's
GitHub release, checks it against the SHA-256 pinned per platform, and
keeps it in `build/`. In client mode it starts its own reference server
(connect-go) and launches `node conformance.mjs`, writing
`ClientCompatRequest` messages to its stdin and reading a
`ClientCompatResponse` for each from its stdout, protobuf binary, each
prefixed by its length as a 4-byte big-endian integer.
`conformance.mjs` decodes each request with the JavaScript protoc-gen-es
generates from the suite's protos (`suite/js/`, through
`@bufbuild/protobuf`), unpacks its one request message from its `Any` to
proto3 JSON, and makes it an envelope for the runner: `host` and `port` as
the `baseUrl`, `request_headers` as `headers`, `timeout_ms` as `timeout`,
`use_get_http_method` as `useGet`, and `cancel.after_close_send_ms` as
`cancelAfterMs` (a unary call's request is sent whole, so the count starts
when the call is sent). The other cancel timings, `before_close_send` and
`after_num_responses`, are for streams, which `conformance.yaml` declares
unsupported; a request with one is refused. The runner calls the method through
`Live.Conformance`, whose calls come from the Elm protoc-gen-elm-connect
generates from the same protos (`suite/elm/`, `streaming=skip`), and the
result is translated back: the response's payload, or the error's code,
message and details (a detail that came as JSON is read back from its
`"@type"` form; one that came as protobuf binary only, `{"type",
"value"}`, is forwarded as the `Any`'s bytes as they came), the answer's
headers, and as trailers those prefixed `trailer-`, which is how Connect
sends a unary call's trailers. A transport failure is reported as an
error: `Timeout` as `deadline_exceeded`, `NetworkError` as `unavailable`,
anything else as `unknown`; `{"canceled": true}` as `canceled`. What is reported is only what the runtime gives
an application; the runner's `wire` log is never read.

`--send` picks how calls are sent: `halves` (the default) through the pure
halves, which is the only way an application gets an answer's headers, or
`sendTraced`, `send` or `task`, which give none. `just live-conformance`
runs both `halves` and `sendTraced`.

`conformance.yaml` declares what is tested (the suite's `Features`):
HTTP/1.1, the Connect protocol, the JSON codec, no compression, unary
calls, Connect GET, and no TLS, HTTP/2, trailers or receive limit; that is
40 test cases. `known-failing.txt` lists the test cases the runtime fails
however a call is sent (none: all 40 pass through the halves), and
`known-failing-send.txt` those it fails too through `sendTraced` (34
pass), each with the reason and the ways of sending it holds for; the runner requires a listed
case to fail, so the lists cannot go stale. One test case pattern per line
(`*` one name component, `**` any number), `#` starting a comment.
`connectconformance` reads only the first `--known-failing` flag it is
given, so the `sendTraced` run joins the two files in `build/`.

`suite/buf.gen.yaml` generates both from
`buf.build/connectrpc/conformance` at the commit its v1.0.6 label names;
`just live-conformance-gen` installs the npm packages with `npm ci`,
regenerates, and fails if the output differs from what is committed.
### The route fixtures, live

The example server serves `routes/routes.proto` too
(`examples/notes/routes` links to `routes/`, so buf generates it with
the example), each method
echoing the request Vanguard decoded: the request itself when the
response is of its type, otherwise the request as proto3 JSON in
`Message.text` or `Resource.display_name`. `routes.mjs` sends every
fixture through the runner (`transport` `transcode`, the fixture's
`binding`, its request) and checks:

- the request: verb, the path and the query pairs exactly as sent
  (percent-encoded, in order), the body as the fixtures' own checks
  compare it (`null`s and defaults dropped; an empty message dropped
  this way is printed as a `note`), and a fixture's `headers`;
- the answer: HTTP 200, and the echo equal to the fixture's request
  once both are normalized as proto3 JSON (fields without presence at
  their default left out, fields with presence kept when set, `null`
  unset, 64-bit integers as strings, enums by name, bytes, durations
  and timestamps in one form); a `HEAD` answer has no body, so there
  the runtime's `ok` must be `{}`;
- the runtime's `ok`, normalized, equal to the echo.

```sh
node conformance/live/routes.mjs --serve target/live/bin/notes-server
node conformance/live/routes.mjs --server http://127.0.0.1:8080
```

Vanguard will not serve two routes for one verb and path, so the
server serves a binding it refuses on another transcoder under
`/layer/<n>` (`GET /routes/layers` lists where each binding is), and
its fixture runs with that prefix on `baseUrl`. `known-divergent.json`
lists those bindings under `servedApart`, which must equal the
server's, and under `fixtures` each fixture whose live call disagrees:
the request (`url`), Vanguard's answer, a `reading` of who is right,
and `vanguard`, matched against the result as a case's `expect` is.
A listed fixture passes while that answer holds, and fails once it
agrees, until its entry is removed.
