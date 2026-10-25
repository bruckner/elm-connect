> The spike plan, verbatim except that the application's own type, RPC and
> name are replaced by bracketed placeholders, which this repository does not name.

# Spike: server streaming (plan draft, 2026-10-24, for discussion)

## What the application taught (explorer report, 2026-10-24)
- The web client streams [the application's message type] over a Phoenix channel (WebSocket, phoenix.js 2.0), not the
  proto's [the application's streaming RPC]. The server implements [the application's streaming RPC] only as native gRPC (h2c :50151, Go CLI
  only). The REST `:stream` route is not served; no NDJSON/SSE/array framing, no Connect streaming
  content types, no gRPC-Web. Elm codegen skipped streaming RPCs on purpose.
- Protocol facts worth keeping: auth in the join payload, re-read per rejoin; join reply carries the
  replay (frames with index > since), then `presence_snapshot`; every frame is a valid resume point
  (transient frames carry the durable high-water mark); replay floor 500, `out_of_range` with
  `replay_floor_message_index`; server heartbeat after 20 s idle; the bridge synthesises `joined
  {gap}` after replay; connection state (online/connecting/offline) drives the offline queue; one
  channel at a time; leave on navigate/logout; `set_focus` rides the socket (presence tied to the
  connection).
- Pain recorded: token captured once at join (fixed with a params function); silent recovery
  (`out_of_range` swallowed in JS); pages that never joined; a bridge envelope mismatch; rejoin
  herds under load; untested rejoin/replay in elm-test.
- What a library must offer to be adoptable: auth evaluated per (re)connect; reconnect with backoff
  and "reconnect now if dead"; a resume cursor re-derived from the latest frame; typed, structured
  end-of-stream errors (not swallowed); an explicit "stream open / replay done" event; connection
  state as events; one stream per key with cancel; idle (heartbeat) timeout; proto3-JSON frames
  into generated types. The app keeps: which page re-reads, presence folding, routing, the write
  queue, token policy, seeding the cursor from REST, telemetry.

## Question
Can an Elm package plus a small vanilla-JS companion give server streaming over Connect (and the
transcoders' framings) with an API an application would adopt over a hand-rolled channel bridge,
and what does the JS have to own that Elm cannot?

## Protocol facts to verify, then implement
- Connect server streaming: POST, `Content-Type: application/connect+json` (or `+proto`),
  `Connect-Protocol-Version: 1`, request body = one enveloped message; response HTTP 200 always,
  body = envelopes (1 flag byte + 4-byte big-endian length + payload); flag 0x02 = EndStreamResponse
  whose JSON `{ "error": {code, message, details}, "metadata": {...} }` carries the error, if any;
  flag 0x01 = compressed (`Connect-Content-Encoding`); `Connect-Timeout-Ms` applies to the whole
  stream. GET is unary-only.
- Transcoders: grpc-gateway NDJSON `{"result":…}` / `{"error":…}`; Envoy array (default), NDJSON
  (`stream_newline_delimited`), SSE (`stream_sse_style_delimited`). gRPC-Web: `application/grpc-web+proto`
  with in-band trailers (flag 0x80), `grpc-web-text` base64 for XHR; out of scope for the spike
  (roadmap "gRPC-Web, unary" is separate).
- Browser: `fetch` + `ReadableStream` reader, `AbortController` for cancel; Safari/Firefox/Chrome all
  stream response bodies; request-body streaming is not needed (one request message).

## Shape to prototype
Two Elm-side integration styles share one JS core (fetch + envelope/NDJSON/SSE/array parser +
abort). Prototype A for real; evaluate B on the same core.
- **A. Ports, thin JS, Elm owns policy.** JS exposes `open(id, {url, method, headers, body, framing})`
  → events `{id, kind: headers|message|end|error, …}`; `cancel(id)`. The package cannot declare
  ports, so it gives the values: `Rpc.Stream.open : Config -> StreamCall req res -> Json.Encode.Value`
  (what the app sends through its port), `Rpc.Stream.event : Decoder (Event res)` with
  `Opened Metadata | Message res | Ended | Failed Rpc.Error`, and `Rpc.Stream.cancel id`. A
  `Rpc.Stream.Session` helper (pure state machine in the app's model) owns reconnect with backoff
  (reusing `Rpc.Retry` + `Rpc.Retry.next`), the resume cursor via an app callback `cursor -> req`,
  idle timeout, and connection state; token is re-read because Elm builds the headers at each open.
- **B. Custom element.** `<connect-stream>` whose properties are the request and whose events are
  the frames; `Rpc.Stream.view : … -> Html msg`; lifecycle = the view (connected/disconnected), so
  leave-on-navigate is free. Evaluate: token in a DOM property (not attribute), reconnect inside the
  element vs in Elm, testability, and whether a view-driven stream surprises.
- Generated side: `StreamCall req res` beside `Call`, from a new `Proto.Method.serverStreaming`;
  `--streaming skip` keeps today's behaviour; the plugin stops refusing server-streaming methods.
- Errors at end of stream map onto `Rpc.Error` (RpcStatus with details), so a structured floor
  (e.g. `google.rpc.ErrorInfo` metadata) is readable with `Rpc.Error.details`.
- The JS ships as a file in the repository (`runtime/stream.js` or similar) that applications copy or
  fetch at the version, documented like the vendored runtime; npm later (roadmap).

## Oracles
1. The repository's notes example Go server (connect-go) gains a server-streaming method
   (`WatchNotes` or similar, emitting N messages then an error on request) → Connect `+json` oracle,
   including EndStreamResponse errors, cancel, timeout.
2. The live suite's Envoy transcoder and grpc-gateway serve the same method → the three framings.
3. `demo.connectrpc.com` Eliza `Introduce` (server streaming) → a public browser demo in
   `examples/eliza` (the trying.md page gains a streaming paragraph).
4. Unit tests: envelope parser (split chunks, multi-message chunks, end-stream with/without error,
   compression flag refused), Session state machine (backoff from `Rpc.Retry`, cursor re-derivation,
   idle timeout, cancel).
Not an oracle yet: the application's [the application's streaming RPC] over HTTP, because its server has no HTTP
streaming binding. A follow-on for the application: a Connect-streaming (or NDJSON) endpoint for
[the application's streaming RPC], presence per stream, and `set_focus` as the unary call; the spike's report lists what
that needs.

## Work
1. Verify the protocol facts against connectrpc.com/docs/protocol and the gRPC-Gateway/Envoy docs;
   write them into a `STREAMING-NOTES.md` with links. 2. JS core + unit tests (node). 3. Elm `Rpc.Stream`
   + `Session`, generator support, notes streaming method, live cases. 4. Eliza `Introduce` demo page.
   5. Evaluate B on the core (a day at most). 6. Report: API, sizes (Elm + JS, min+gz), what JS owns,
   framing matrix results, adoption gap list for the application, open design questions, 1.0 posture.

## Decisions for the operator before dispatch
- A first, B evaluated? Or B first? (My recommendation: A first; B as a thin wrapper if the core holds.)
- Where the JS lives and ships (repo file at the version vs npm now).
- Should the spike add the streaming method to the notes server (Go) and live suite (yes, it is the oracle)?
- The application's server-side follow-on: in scope for a later session of the application's own, not this spike.
- Caps: Opus, worktree `spike-streaming`, branch `spike/streaming`; Rust+Go builds (single slot);
  two agent runs (core+Elm, then oracles+report); disk floor; nothing merged.

## Decisions (operator, 2026-10-24)
- Plan approved. A (ports, thin JS, Elm owns policy) first; B (custom element) evaluated on the same core.
- The JS ships as a versioned file in the repository now; npm later.
- The spike may add the server-streaming method to the notes Go server and the live suite: they are the oracle.
- The application's server-side binding is a later session of its own, not this spike.
- Added: compare whatever JS we write against depending on `@connectrpc/connect-web` (what it would require of an Elm application, what it gives, size, and whether a thin adapter over it beats a hand-written core).
- Runs: 1 = protocol notes, JS core + node tests, connect-web comparison, Elm `Rpc.Stream` + `Session`, generator support, notes server method, Connect oracle. 2 = transcoder framings in the live suite, Eliza `Introduce` demo, custom-element evaluation, final report.

---

# Run 1 report: server streaming spike

Branch `spike/streaming` from `origin/main` 0d3e031; nothing merged, no PR.
`mise exec -- just check` passes on the final commit (rc 0, clippy, fmt, every
Rust and Elm test, snippets, package verify). Timebox about three hours; no
blocker stopped a step.

## 1. Protocol corrections (`spike/STREAMING-NOTES.md`)

Every fact has its source link in the notes. Where the plan was wrong or
incomplete:

1. **Envoy has no in-band error frame (important).** An error before the first
   message is a trailers-only gRPC answer, which Envoy turns into an HTTP status
   plus (with `convert_grpc_status`) a `google.rpc.Status` body. An error after
   the first message is *not* converted (`has_body_`): the 200 body is closed
   normally (the array gets its `]`) and `grpc-status` travels as an HTTP
   trailer, which `fetch` cannot read and HTTP/1 drops. **Over Envoy a browser
   cannot tell a mid-stream error from a clean end.** Source:
   `json_transcoder_filter.cc` (`doTrailers`, `maybeConvertGrpcStatus`).
2. **grpc-gateway's pre-stream error keeps its wrapper.** Before the first
   message the gateway sets the HTTP status from the code and writes
   `{"error": Status}` + delimiter, not the bare `google.rpc.Status` its unary
   errors use (`handleForwardResponseStreamError`). Confirmed live.
3. **Connect-Protocol-Version is optional for streams** in the grammar; sent
   anyway.
4. **Compression headers for streams are `Connect-Content-Encoding` /
   `Connect-Accept-Encoding`**, not the unary ones.
5. **Missing end-stream is a transport failure.** A Connect stream MUST end
   with an EndStreamResponse; connect-web 2.2.0 throws `"missing
   EndStreamResponse"`. The core reports reason `truncated`, Elm reads
   `NoAnswer NetworkError` (code `unavailable`), so a reconnect policy retries
   it.
6. **Non-200 still happens over Connect**, from whatever is in front of the
   handler: the notes server's Vanguard mux answers an unknown streaming path
   with **505** and an empty body. The core reports `end` with the status; Elm
   gives `HttpStatus`.
7. **Vanguard refuses REST transcoding of a server stream** whose response is
   not `google.api.HttpBody` ("stream type server requires a google.api.HttpBody
   response body"), and the notes server then fails to start. So `WatchNotes`
   has no HTTP rule; grpc-gateway (and Envoy's `auto_mapping`) reach it on the
   implicit route. For run 2 this means the Vanguard leg of the framing matrix
   is N/A.
8. connect-go flushes response headers on the first `Send` only, so
   `Opened` arrives with the first message unless the handler calls
   `SendHeaders()`: "stream open" is not observable before data from a stock
   handler (seen in the idle-timeout oracle: no `Opened` before the timeout).

## 2. The JS core (`runtime/stream.js`)

Vanilla ES module, no dependencies, 347 lines with comments; **4,769 B
minified, 2,127 B min+gz** (esbuild 0.28.2, gzip -9).

```js
const streams = createStreams(emit /*, fetchImpl for tests */);
streams.open(id, { url, method, headers, body, framing, timeoutMs, withCredentials });
streams.cancel(id);
streams.run(command);   // a value from Rpc.Stream.open or Rpc.Stream.cancel
// emit receives, each with `id`:
//   { kind: "headers", status, headers }
//   { kind: "message", json }                    frame JSON as text
//   { kind: "end", status, error, metadata, body? }  error: null | the server's object
//   { kind: "error", reason, message }           network | timeout | truncated | protocol | compressed
```

Framings: `connect`, `ndjson` (grpc-gateway, unwraps `result`, `error` ends),
`ndjson-bare` (Envoy `stream_newline_delimited`; added, the brief listed four),
`array` (Envoy default; a string- and nesting-aware scanner), `sse`. A non-200
answer is read whole and its body's error object (Connect, Status, or the
gateway's `{"error": …}`) passed up. Reopening an id replaces the stream; a
cancelled stream emits nothing more, as unary `Rpc.cancel` reports nothing.

Tests: `node --test runtime/stream.test.mjs`, 18 tests, every framing
parsed at **every split point and one byte per chunk**, several frames per
chunk, a UTF-8 sequence split mid-character, CRLF split across chunks in SSE,
compressed flag refused, end-stream missing/cut/followed by data, and the
client against a fake `fetch` (envelope bytes, non-200, cancel, timeout,
replace). Known limit: the array scanner rescans an unfinished element on each
chunk (quadratic for one huge message in many chunks).

## 3. connect-web verdict (`spike/CONNECT-WEB.md`)

**Hand-written core.** connect-web's transport alone is 32.2 KB min+gz (the
same event surface over it: 32.6 KB) against 2.1 KB. It needs no generated
protobuf-es schemas if each method is described at run time with
`google.protobuf.Value` as input and output (`adapter.js`, verified against
`WatchNotes`), but that is undocumented use of `DescMethod`, it parses every
frame twice, it hands the error over as `ConnectError` with numeric code and
binary details (the `debug` JSON Elm reads is dropped), and it has none of the
three transcoder framings. What it adds (gRPC-Web, compression, interceptors)
is a separate roadmap item or against the no-hooks config. The port protocol is
the seam: an adapter can replace `stream.js` later without touching Elm.

## 4. The Elm API as it stands

```elm
-- Proto.Method
type ServerStreaming req res          -- opaque; Rpc.call does not take it
serverStreaming : (req -> Value) -> Decoder res -> Descriptor -> ServerStreaming req res
streamingMethod : ServerStreaming req res -> Method req res   -- for reading its codecs

-- Rpc.Transport
type StreamFraming  -- opaque
gatewayNdjson (default), envoyArray, envoyNdjson, envoySse : StreamFraming
withStreamFraming : StreamFraming -> Transport -> Transport  -- Connect ignores it

-- Rpc.Stream
type StreamCall req res
call : ServerStreaming req res -> req -> StreamCall req res
withHeaders : List (String, String) -> StreamCall req res -> StreamCall req res
withTimeout : Float -> StreamCall req res -> StreamCall req res
idempotency, descriptor
open : Rpc.Config -> { id : String, call : StreamCall req res } -> Result Rpc.Error Value
cancel : String -> Value
type Event res
    = Opened { status : Int, headers : Dict String String }
    | Message res
    | Ended { trailers : Dict String (List String) }
    | Failed Rpc.Error
event : StreamCall req res -> Decoder (Event res)
eventId : Decoder String

-- Rpc.Stream.Session
type Session res                 -- data only: key, generation, attempts, cursor, state
init : String -> Session res
type State = Connecting | Open | Waiting Float | Closed (Maybe Rpc.Error)
state, latest, liveId
type alias Options req res =
    { config : Rpc.Config, call : Maybe res -> StreamCall req res
    , retry : Rpc.Retry.Retry, idleTimeout : Maybe Float, reconnectOnEnd : Bool }
type alias Ports msg = { out : Value -> Cmd msg, toMsg : Msg -> msg }
start, stop, reconnectNow : Msg
incoming : Value -> Msg
update : Options req res -> Ports msg -> Msg -> Session res -> ( Session res, Cmd msg, Maybe (Event res) )
-- the pure machine underneath, for tests and hand-run effects:
step : Options req res -> Input -> Session res -> ( Session res, List (Effect res) )
```

Usage sketch (the oracle's `spike/oracle/src/Oracle.elm` is the running form):

```elm
port streamOut : Value -> Cmd msg
port streamIn : (Value -> msg) -> Sub msg

feedOptions model =
    { config = configFor model.shared          -- token read at every (re)open
    , call = \latest -> watchNotes { after = Maybe.map .index latest |> Maybe.withDefault "0", count = 0, intervalMs = 0, fail = False }
    , retry = Rpc.Retry.on [ Rpc.Code.Unavailable, Rpc.Code.DeadlineExceeded ] |> Rpc.Retry.withAttempts 10
    , idleTimeout = Just 30000
    , reconnectOnEnd = False
    }

update msg model =
    case msg of
        Feed m ->
            let ( feed, cmd, event ) = Session.update (feedOptions model) { out = streamOut, toMsg = Feed } m model.feed
            in ( fold event { model | feed = feed }, cmd )

subscriptions _ = streamIn (Feed << Session.incoming)
```

Decisions taken, with reasons:

- **JS envelopes the body.** A port carries JSON, Elm has no bytes port, and
  base64 through the port would cost more than the five bytes JS writes.
  `open` sends the request's JSON text and the framing name; JS wraps it.
- **`open` returns `Result Rpc.Error Value`** (the brief said `Value`): a bad
  base URL, a header a browser refuses (`fetch` would throw a misleading
  TypeError), an unmatched path value or an oversized message are refused
  before anything is sent, with the same errors `Rpc.send` gives.
- **The config's `timeout` does not bound a stream**; only
  `Rpc.Stream.withTimeout` does (and becomes `Connect-Timeout-Ms` and the JS
  abort). A config shared with unary calls usually holds a few seconds, which
  would kill every long stream. The config's `retry` is ignored too; the
  Session takes its own.
- **Always POST, Connect content type `application/connect+json`**, whatever
  `connectGet` says; over `transcode` the implicit route (no rule) speaks
  Connect, a bound method uses the transport's framing.
- **`Ended` carries the trailers** (the brief had bare `Ended`): Connect's
  end-stream `metadata` is the only place trailers exist for a stream.
- **Error mapping:** a Connect end-stream error → `RpcStatus` with source
  `ConnectEndStream` (the reserved `Source` constructor, now produced) and
  details readable by `Rpc.Error.details`; a gateway/Envoy status →
  `StatusBody`; non-200 without a status → `HttpStatus`; `timeout` →
  `NoAnswer Timeout`; `network` and `truncated` → `NoAnswer NetworkError`;
  `protocol`/`compressed`/undecodable message → `BadResponse`.
- **The Session is pure.** `step` returns data effects (`Send`, `After`,
  `NeedTime`, `Deliver`); `update` turns them into commands (`Process.sleep`,
  `Time.now` for `Rpc.Retry.next`'s jitter). Options hold functions, so they are
  passed to each update, never stored: the model stays comparable. Streams get
  ids `key#generation`; any event for an older generation is dropped, which
  closes the cancel-vs-queued-event race.
- **Reconnect policy is `Rpc.Retry` + `next`**, with the call's idempotency
  gating it as for unary calls (so a watch method should be `NO_SIDE_EFFECTS`;
  `WatchNotes` is). The attempt count resets when a message arrives.

Tests: `tests/Rpc/StreamTest.elm`, 22 tests (open's URL, headers, body,
timeout, POST-only, implicit route, invalid header; each event kind and error
mapping; Session start, cursor, stale-id drop, backoff and resume, give-up,
non-retried code, idle timeout and re-arming, stop).

Size: the oracle program with one unary call added is 24.5 KB min+gz against
21.2 KB for the same unary call alone, so `Rpc.Stream` + `Session` + the
oracle's own code cost about **3.3 KB** min+gz (`elm make --optimize`,
esbuild minify, gzip -9).

## 5. Generator

New value `streaming=server` (`--streaming server`), beside `error` (default)
and `skip`, both unchanged: a server-streaming method becomes
`listen : Line -> Rpc.Stream.StreamCall Line Line` built from
`Proto.Method.serverStreaming`; client and bidirectional methods remain the
`services::streaming` error. `Rpc.Stream` and `Rpc.Stream.Session` joined
`RUNTIME_MODULES`. Corpus case `conformance/cases/services_streaming_server`
blessed. The notes example's three Elm templates pass `streaming=server`
(so every generated header now records it, and `just live-gen`'s
include-imports diff still holds).

## 6. What the JS had to own that Elm could not

- Reading the body as it arrives (`ReadableStream`); elm/http delivers it whole.
- Bytes: the 5-byte envelope out, envelope parsing in, UTF-8 across chunk
  boundaries; ports carry JSON only.
- Abort (`AbortController`) of a live `fetch`, and the stream-level timer.
- The framing parsers (they are byte/char level and must not block Elm).
- Nothing else: headers, auth, URL, retry, resume, idle, error meaning and
  decoding are Elm's.

## 7. Oracle results

`WatchNotes` added to `examples/notes/proto` (count, interval, `after` cursor,
`fail` ending in `FAILED_PRECONDITION` + `ErrorInfo{reason: WATCH_ENDED,
metadata.index}`), implemented in the Go connect-go server, regenerated with
`just live-gen` (passes).

- `spike/oracle/core.mjs`, JS core against the running server, **8/8 pass**:
  N messages then a clean end with `content-type: application/connect+json`;
  end-stream error with its `ErrorInfo` detail (`debug` JSON present); a bad
  request is an end-stream error inside a 200; cancel after two messages
  stops all events; server deadline from `Connect-Timeout-Ms: 120` →
  `deadline_exceeded` end-stream; client `timeoutMs` → `error/timeout`;
  unknown method → non-200 end (505 from Vanguard); grpc-gateway NDJSON on the
  implicit route: `result` lines then `{"error":{"code":9,…}}`.
- `spike/oracle/src/Oracle.elm` + `run.mjs`, **Elm end to end** (Elm builds
  each open, JS streams, Elm decodes), all four scenarios as expected:
  - clean: `opened 200, message 1..3, ended`, state `closed`;
  - fail: `… message 3, failed failed_precondition ConnectEndStream
    WATCH_ENDED` (the reason read as a typed `Google.Rpc.ErrorInfo` through
    `Rpc.Error.details`);
  - resume (`reconnectOnEnd`): three opens with bodies `after` unset, `"2"`,
    `"4"`, messages 1..6 in order, and the `Authorization` header different on
    each open (token re-read per open);
  - idle (100 ms idle, 400 ms interval): three opens, then
    `failed deadline_exceeded`, state `closed: deadline_exceeded`.
- Existing live cases still pass after the proto change: `cases/notes.json`
  over Connect and the transcode cases under `/gateway` (run by hand; the Envoy
  and Connect-conformance legs of `just live` were not run).
- **Live suite harness:** not extended. It drives the Elm `Live` program over an
  XHR shim and expects one result per call. A streaming case would need: a
  `fetch` path in the runner (the core), a stream port pair in `Live.elm`
  dispatching `StreamCall`s by method name like `Live/Notes.elm` does for
  calls, and a case format whose expectation is an event list (`opened`,
  messages, `ended`/`failed` with code and details) plus actions (cancel after
  n, timeout). About a day; natural for run 2 with the framing matrix.

## 8. Left for run 2

- Transcoder framings in the live suite: grpc-gateway NDJSON (implicit route,
  works by hand), Envoy array / NDJSON / SSE (needs `auto_mapping` or a rule
  Envoy accepts while Vanguard is kept off it, plus `print_options` per
  listener), and the Envoy mid-stream-error blind spot written down as a
  known divergence. Vanguard: N/A (refuses non-HttpBody server streams).
- The live-suite streaming case format and harness above; the Connect
  conformance suite's server-streaming JSON cases against the core.
- Eliza `Introduce` demo page (`examples/eliza`, trying.md paragraph).
- Custom-element (`<connect-stream>`) evaluation on the same core.
- Docs: design.md §5 and roadmap, generator docs for `streaming=server`, a
  changelog fragment, and the companion's distribution note (none written in
  run 1; nothing here is meant to merge).

## 9. Open design questions for the operator

1. **Option name and scope:** `streaming=server` errors on client/bidi
   methods. Should a mixed service be able to say "server, skip the rest"
   (`streaming=server,skip`?), or is erroring right until client streaming
   exists?
2. **Default transcode framing:** `gatewayNdjson` was picked arbitrarily; or
   require the application to name one when it opens a stream over
   `transcode`?
3. **Stream timeout:** ignore the config's `timeout` for streams (as now), or
   add a separate stream timeout knob somewhere (it cannot be a `Config` field;
   `Transport`?).
4. **Envoy's invisible mid-stream errors:** accept `reconnectOnEnd` as the
   answer, or document that Envoy streaming needs an in-band error convention
   the server opts into?
5. **`open` returning `Result`** vs. a plain `Value` plus a separate check.
6. **`Ended` vs. `Failed` for a clean end the app did not expect** (watch
   streams): keep `reconnectOnEnd` as a Session flag, or make it a policy on
   `Rpc.Retry` (treat end as code X)?
7. **Opened semantics:** connect-go sends headers with the first message, so
   `Opened` is not "replay done"/"stream acknowledged". An explicit "ready"
   marker would be an application message, not a protocol event; should the
   Session surface a `Ready` hook keyed off a predicate on messages?
8. **Session ids** jump by two per reconnect (`#1, #3, #5`) because a failure
   bumps the generation and so does the reopen; cosmetic, but visible in logs.
9. **Where the companion lives:** `runtime/stream.js` at the version tag, as
   agreed; how the vendored-runtime docs point to it is unwritten.
10. **The connect-web seam:** keep the port protocol stable enough that an
   adapter is a drop-in, or explicitly not promise it?
