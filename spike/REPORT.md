# Server streaming spike: final report

Branch `spike/streaming`, from `main` 0d3e031. Nothing merged, no PR. Run 1's report is `spike/REPORT-RUN1.md`; the plan it follows is at its top. Date 2026-10-24/25. Written by the run-2 agent; saved by the session that dispatched it (the agent's report-file write was refused by the harness, so this file is its text as returned).

**Gates on f7571f7:**
- `mise exec -- just check`: rc 0 (clippy, fmt, every Rust and Elm test, 2,588 runtime Elm tests, 55 snippet blocks, package verify).
- `mise exec -- just live`: rc 0, run in full. That includes every existing leg, 22 new streaming cases, and the Connect conformance suite (39 passed + 1 known failure, under both sends).
- `node --test runtime/stream.test.mjs`: 22/22.

## 1. Run 1 in a page

- **Question:** can an Elm package plus a small vanilla-JS companion give server streaming over Connect and the transcoders' framings, with an API an application would adopt over a hand-rolled channel bridge?
- **Shape chosen (A): ports, thin JS, Elm owns the policy.**
  - `runtime/stream.js` does the reading: fetch with a `ReadableStream` reader, parsers for the four framings, abort and the stream timer.
  - It takes `open(id, {url, method, headers, body, framing, timeoutMs})` and `cancel(id)`, and emits `headers | message | end | error` events.
  - Elm builds every request (`Rpc.Stream.open`) and decodes every event (`Rpc.Stream.event`).
  - `Rpc.Stream.Session` is a pure state machine kept in the app's model. It reconnects with `Rpc.Retry` backoff, resumes from the latest message, applies an idle timeout and exposes connection state.
  - Because Elm builds the headers at every open, a fresh token is read at every reconnect.
- **Generator:** `streaming=server` turns a server-streaming method into a `StreamCall` built with `Proto.Method.serverStreaming`. `error` and `skip` are unchanged; client and bidi methods still error.
- **Protocol corrections** (in `spike/STREAMING-NOTES.md`): Envoy has no in-band error frame; grpc-gateway's pre-stream error keeps its `{"error"}` wrapper; stream compression uses `Connect-Content-Encoding`, not the unary headers; a Connect body that ends without an EndStreamResponse is a transport failure (`truncated`); non-200 answers still happen over Connect, from whatever sits in front of the handler; Vanguard refuses to transcode a server stream unless the response is `HttpBody`; connect-go sends headers with the first message, so `Opened` does not mean "acknowledged".
- **connect-web verdict:** write our own core. It is 2.1 KB against 32.6 KB min+gz, passes frames through untouched, keeps errors in the wire shape `Rpc.Error` reads, and covers the three transcoder framings connect-web lacks. The port protocol is the seam if an adapter is ever wanted.
- **What JS must own:** reading the body as it arrives, the bytes (envelopes, UTF-8 across chunks), abort, the stream timer, and the framing parsers. Nothing else.

## 2. Framing matrix (run 2)

Every leg runs in the live suite (`conformance/live/cases/stream*.json`): Elm builds each request and decodes each event; the companion streams over Node's `fetch`. The runner tees the response body, so each case's `wire` records what the page's reader saw: status, headers, body text, and how the read ended. The case format is documented in `conformance/README.md`. No leg had to fall back to the run-1 node oracle.

| leg | frames | error before the first message | error after messages | cancel / timeout |
|---|---|---|---|---|
| Connect JSON (notes server, connect-go) | ok | 200 plus an end-stream error (`ConnectEndStream`, `BadRequest` detail) | end-stream error with `ErrorInfo{WATCH_ENDED, index}`, read typed | cancel after 2: no further event, fetch aborted. `Connect-Timeout-Ms` alone: the server's `deadline_exceeded`. `withTimeout`: `deadline_exceeded`, whichever side ends it first |
| grpc-gateway NDJSON (method without a rule) | ok; end of body = `Ended` | 400 plus `{"error": Status}`, unwrapped (`StatusBody`, `BadRequest`) | `{"error":…}` line under 200, `ErrorInfo` | same core; not cased separately |
| Envoy array, `convert_grpc_status` on | ok | 200 plus a bare Status as the body; now read as `StatusBody` (was a protocol error) | **looks like a clean end** | — |
| Envoy array, `convert_grpc_status` off | ok | **looks like an empty stream that ended cleanly** (200, `[]`) | **looks like a clean end** | — |
| Envoy NDJSON | ok | 200 plus a Status line; now read as `StatusBody` (**was delivered as an empty message**) | **looks like a clean end** | — |
| Envoy SSE | ok | 200 plus Status text; now read as `StatusBody` (was a silent clean end) | **looks like a clean end** | — |
| Vanguard | N/A | — | — | It refuses to transcode a server stream without `google.api.HttpBody`, and the server then fails to start. It serves Connect on the method's default path instead (`connectEnvelope`) |

One more Connect case: a path no Connect handler holds gets a 404 with a Status body from Vanguard's REST fallback, read as `StatusBody`.

**The Envoy proof** (Envoy 1.40.0, server ending with FAILED_PRECONDITION after two messages):
- On the wire, over HTTP/1.1 (`curl --raw`, `TE: trailers` sent): status 200, the full array, then a final `0\r\n\r\n` chunk with no trailer fields at all. Over HTTP/2 (h2c): status 200, the same array, then a trailers frame with `grpc-status: 9`, `grpc-message` and `grpc-status-details-bin`.
- `convert_grpc_status` changes nothing after the first message: the on and off listeners are byte-identical, and the NDJSON and SSE listeners also end normally.
- What a page's reader sees: Node 24 `fetch`, and headless Chromium 148 on a same-origin page, both get status 200, the complete array, and a read that reaches `done`. `Response` has no trailer API (`"trailer" in response === false`). A clean end and a failed one cannot be told apart.
- Correction to run 1 (errors before the first message): run 1 said Envoy turns these into an HTTP status. That only holds if the upstream answers "trailers-only". connect-go does not: with h2c `curl` against the notes server, it sends a HEADERS frame (200) and then a separate trailers frame. So Envoy has already committed 200, and then: with `convert_grpc_status` it writes the Status JSON as the body, outside the framing; without it, it closes an empty stream.
- Fix in the core: it now recognises a bare Status in place of the first frame. For NDJSON this is a heuristic: a first line whose only keys are an integer `code`, `message` and `details`, confirmed by the end of the body or overturned by a second line.

## 3. Eliza `Introduce`

**Generation.** `examples/eliza` is now generated with `--streaming server`: `say` stays an `Rpc.Call`; `introduce : IntroduceRequest -> Rpc.Stream.StreamCall IntroduceRequest IntroduceResponse`. `streaming=server` cannot leave `Converse` out: it is bidi, so it is the `services::streaming` error, and `gen` has no way to exclude one method. The example generates from a copy of the proto without it (`spike/eliza-proto`). The diagnostic's help is also stale under `server` ("not supported… pass --streaming skip"), and `gen --help` lists only `error|skip` although `server` is accepted.

**The page.** `src/Main.elm` has a second form: a name field, Introduce (starts a Session), Cancel (stops it), the Session's state, and each sentence appended as it arrives. `index.html` loads `elm.js` and wires the ports to `runtime/stream.js`. It is a module script, so the page has to be served over HTTP, not opened from disk. `docs/trying.md` has the "A stream" section, every fence a tagged excerpt of a committed file.

**Real call, headless Chromium 148, page served on 127.0.0.1:** `connecting` at 60 ms; `open` arrives together with the first sentence at 785 ms; the other sentences at about 1.3 s, 1.8 s and 2.3 s; `closed` at 2.29 s. Cancel after the first sentence: the page stops, and that fetch lasted 628 ms against 2,253 ms for a full stream.

**What the server streams** (curl, three runs): always four sentences about 500 ms apart ("Hi <name>. I'm Eliza.", "Before we begin, <name>, let me tell you something about myself.", one random fact, "How are you feeling today?"; an empty name becomes "Anonymous User"), then an EndStreamResponse of `{}`: no error, no metadata, no HTTP trailers. Response headers: `content-type: application/connect+json`, `connect-accept-encoding: gzip`, and CORS headers that echo the origin and expose the Grpc-* and Connect-* names. The preflight answers 204 and allows POST with `content-type` and `connect-protocol-version`. The headers arrive with the first message, as on the notes server.

**A trap.** `Introduce` declares no `idempotency_level`, so a Session would never reconnect it unless the retry policy uses `allowNonIdempotent`.

## 4. Custom element: verdict

**Built:** `spike/element/connect-stream.js` (63 lines over the same core); `Rpc.Stream.Element.view : { command : Maybe Value, onEvent : Value -> msg } -> Html msg`; an Eliza variant driven in headless Chromium, and one elm-test. The element's `open` property is exactly the value `Rpc.Stream.open` builds for the port; its `stream` event carries exactly the port's event JSON, so `Session.incoming` decodes it unchanged; the command's `id` is the stream's identity; the Session still lives in the model.

| point | ports (A) | element (B) |
|---|---|---|
| wiring | 2 ports, 3 lines of JS, a subscription | one import of the element; the view rebuilds the request from `liveId` and `latest` |
| leave on navigate | the app sends `stop` | free (removing the element cancels it), but see the surprise below |
| reconnect state | the Session | still the Session. An element that reconnected itself would move backoff, policy and token freshness into JS, so not prototyped |
| elm-test | the Session's pure `step` | the same, and `Event.custom "stream"` drives the Session (test passes). Query cannot read a JSON property's value, so the request has to be tested through the function that builds it |
| token exposure | the token travels through the port into JS | a property, not an attribute: `outerHTML` is `<connect-stream></connect-stream>`. But `el.open` holds the latest Authorization value for any script on the page |
| re-render | n/a | the property is set on every render (7 sets but 1 open in one stream, because Elm compares JSON values by reference). Keyed by id, it does not reopen. A new id reopens with the latest token. Needs `Html.Keyed` or a stable position |
| `Browser.application` | n/a | when a page switch discards the page's model too, cancelling on removal is exactly right |
| size | core 2,490 B min+gz | 2,711 B (+221 B) |

**The surprise (measured):** hiding the element mid-stream cancelled the stream, but the Session still said `Open`. Showing it again created a new element with the same id, which opened a fresh stream; the Session took it as the old stream's continuation, so "Hi Ada" appeared twice. The model and the DOM disagree about whether the stream is open. The app still has to stop the Session whenever it stops rendering the element, which gives back the leave-on-navigate advantage.

**Verdict:** keep A as the API. B could be added later without touching the core or Elm, if the element dispatches an end event on disconnect (or mints a new id per connection).

## 5. The Elm API as it stands

```elm
-- Proto.Method
type ServerStreaming req res
serverStreaming : (req -> Value) -> Decoder res -> Descriptor -> ServerStreaming req res
streamingMethod : ServerStreaming req res -> Method req res
-- Rpc.Transport
type StreamFraming
gatewayNdjson (default), envoyArray, envoyNdjson, envoySse : StreamFraming
connectEnvelope : StreamFraming   -- run 2: Connect on the method's default path behind `transcode`
withStreamFraming : StreamFraming -> Transport -> Transport
-- Rpc.Stream
type StreamCall req res
call : ServerStreaming req res -> req -> StreamCall req res
withHeaders : List (String, String) -> StreamCall req res -> StreamCall req res
withTimeout : Float -> StreamCall req res -> StreamCall req res
idempotency, descriptor
open : Rpc.Config -> { id : String, call : StreamCall req res } -> Result Rpc.Error Value
cancel : String -> Value
type Event res = Opened { status : Int, headers : Dict String String } | Message res
               | Ended { trailers : Dict String (List String) } | Failed Rpc.Error
event : StreamCall req res -> Decoder (Event res)
eventId : Decoder String
-- Rpc.Stream.Session
type Session res;  init : String -> Session res
type State = Connecting | Open | Waiting Float | Closed (Maybe Rpc.Error)
state, latest, liveId
type alias Options req res = { config : Rpc.Config, call : Maybe res -> StreamCall req res
    , retry : Rpc.Retry.Retry, idleTimeout : Maybe Float, reconnectOnEnd : Bool }
type alias Ports msg = { out : Value -> Cmd msg, toMsg : Msg -> msg }
start, stop, reconnectNow : Msg;  incoming : Value -> Msg
update : Options req res -> Ports msg -> Msg -> Session res -> ( Session res, Cmd msg, Maybe (Event res) )
Input(..), Effect(..), Timer(..), step   -- the pure machine
-- spike only (spike/element, not in src/): Rpc.Stream.Element.view
```

**Behaviour change in run 2.** Over `transcode`, a stream on a method without an HTTP rule now uses the transport's framing, sent as a plain JSON POST without the Connect headers (the companion keeps the timer). Before, it spoke Connect, which no transcoder serves for streams: Envoy's `auto_mapping` and grpc-gateway's unbound methods answer in their own framing. Without the change, Elm could not reach `WatchNotes` through either. A Connect handler behind a transcoder (Vanguard) uses `connectEnvelope`.

**Usage, ports** (`examples/eliza/src/Main.elm`):
```elm
port streamOut : Json.Encode.Value -> Cmd msg
port streamIn : (Json.Decode.Value -> msg) -> Sub msg
introduction model = { config = config, call = \_ -> ElizaService.introduce { name = model.name }
    , retry = Rpc.Retry.on [], idleTimeout = Just 10000, reconnectOnEnd = False }
-- update:  Introduce -> introducing Session.start ... ; Cancel -> introducing Session.stop model
introducing m model = let ( session, cmd, event ) =
        Session.update (introduction model) { out = streamOut, toMsg = Introducing } m model.session in ...
-- subscriptions: streamIn (Introducing << Session.incoming)
```
```js
const streams = createStreams((e) => app.ports.streamIn.send(e));
app.ports.streamOut.subscribe((c) => streams.run(c));
```

**Usage, element** (`spike/element/src/Main.elm`):
```elm
Session.update opts { out = \_ -> Cmd.none, toMsg = Introducing } m model.session
Html.Keyed.node "div" [] [ ( "stream", Rpc.Stream.Element.view
    { command = Session.liveId model.session |> Maybe.andThen (\id ->
        Rpc.Stream.open opts.config { id = id, call = opts.call (Session.latest model.session) } |> Result.toMaybe)
    , onEvent = Introducing << Session.incoming } ) ]
```

## 6. Sizes

Measured with esbuild 0.28.2 `--minify`, `gzip -9`, Elm 0.19.2 `--optimize`.

| what | min | min+gz |
|---|---:|---:|
| `runtime/stream.js` in run 1 (347 lines) | 4,769 | 2,127 |
| `runtime/stream.js` in run 2 (402 lines, adds the Envoy Status recognition) | 5,620 | **2,490** |
| core plus `<connect-stream>` | 6,146 | 2,711 |
| Eliza page, `Say` only | 70,157 | 23,649 |
| Eliza page, `Say` plus streamed `Introduce` | 77,510 | 26,100 |
| **Eliza page growth, Elm only** (`Rpc.Stream`, Session, page code) | +7,353 | **+2,451** |
| **Eliza page growth including the companion** | +12,973 | **+4,941** |

`Rpc.Stream` is 410 lines of Elm and `Session` is 451.

## 7. Adoption gaps for an application that runs a channel bridge today

- **Auth per reconnect: covered.** The config is read at every open; for the element, the latest property value is used at each open.
- **Resume cursor: covered.** `call : Maybe res -> StreamCall` reads `Session.latest`. Seeding it from REST is the app's job.
- **Replay-done signal: open.** connect-go sends headers with the first message (the demo server does too), so `Opened` only means "first frame". This needs a server message, plus a Session hook (question 7).
- **Connection state: covered.** `Connecting / Open / Waiting ms / Closed (Maybe err)`, and `reconnectNow` for coming back online.
- **One stream per key: covered.** One Session per key, ids `key#generation`, stale events dropped, and reopening an id replaces the stream. Keeping one Session per key is the app's job.
- **Idle timeout: covered.** `idleTimeout` exists; the server has to send a heartbeat message often enough.
- **Structured end-of-stream errors:** covered over Connect and grpc-gateway, with details readable through `Rpc.Error.details`; covered before the first message under Envoy with `convert_grpc_status`; impossible after the first message under Envoy, and before it without `convert_grpc_status`. `reconnectOnEnd` recovers a watch-style stream.
- **Reconnect with backoff: covered, with a catch.** Reconnects are gated on the method's idempotency (question 12).
- **Leave on navigate: the app's job** (`Session.stop`).
- **Presence, focus, write queue, routing, telemetry: the app's job.**

## 8. What a server has to provide

- **Best: a Connect streaming handler**, with errors as an EndStreamResponse carrying details (the `debug` JSON is what Elm reads typed). CORS must allow POST with `content-type`, `connect-protocol-version`, `connect-timeout-ms` (if `withTimeout` is used) and `authorization`. Optionally call `SendHeaders()` at once, if "the stream is open" should be observable before data.
- **Or NDJSON with in-band errors**, as grpc-gateway does: `{"result"}` lines, then a final `{"error": Status}` with details as `Any` JSON.
- **Not Envoy for streams that can fail**, unless the server puts errors in the stream itself (a final message that says "error", e.g. a `oneof`) and `convert_grpc_status` is on.
- **Vanguard** only with `HttpBody` responses; otherwise serve Connect and use `connectEnvelope`.
- **To be adoptable:** a resume-cursor field in the request; a heartbeat message shorter than the idle timeout; a replay-done marker message if the app needs one; `ErrorInfo` (reason and metadata) on terminal errors; `idempotency_level = NO_SIDE_EFFECTS` on watch methods.

## 9. Open design questions, with recommendations

Run 1's ten (the provisional answers stayed in force; where they bit is noted):
1. **Scope of `streaming=server`: it bit.** Eliza mixes a server stream with a bidi one, so it needs a trimmed proto. Recommend `server` warns and skips client/bidi methods (or a second option value), and that the stale diagnostic and `--help` are fixed either way.
2. **Default transcode framing: did not bite.** Keep `gatewayNdjson`.
3. **Stream timeout: did not bite.** Keep the config's timeout out of streams.
4. **Envoy's invisible errors: proven, and worse before the first message than run 1 thought.** Document Envoy streaming as: errors are not delivered after the first message; turn on `convert_grpc_status`; use `reconnectOnEnd` or an in-band end message.
5. **`open` returning `Result`: did not bite.** In the element style the view drops the error with `Result.toMaybe`, harmless because the Session already closed with it. Keep.
6. **`reconnectOnEnd` as a Session flag:** keep.
7. **What `Opened` means:** confirmed on the public demo server too. Add an optional `ready : res -> Bool` hook to the Session later.
8. **Session ids jumping by two:** cosmetic and internal; bump the generation once per reconnect.
9. **Where the companion lives:** a version comment at the top of `stream.js` and a "copy this file at the tag" paragraph in `install.md`; npm later.
10. **The connect-web seam:** the element shows two front ends already consume the event JSON. Promise the port protocol as documented, versioned JSON.

New in run 2:
11. **Methods without a rule under `transcode`** (decided in the spike): use the transport's framing, plus `connectEnvelope`. Keep this, and decide it before streams ship.
12. **Idempotency gates stream reconnects.** Most protos declare no idempotency, and Eliza's `Introduce` does not, so a Session silently never reconnects it. Keep the gate, since a server stream can have side effects, but document it loudly in the Session docs and in the generated docs of every streaming method whose idempotency is unknown.
13. **The NDJSON Status heuristic.** A message type whose JSON is exactly `{code: int, message?, details?}`, sent as the only line, would be read as an error. Keep the heuristic (the alternative is silently wrong data) and document it.
14. **The element style:** do not ship it with the first streaming release; it can be added later (section 4).
15. **A non-200 with grpc-status headers and no body** ends as `HttpStatus`, not `GrpcHeaders`, because the core's `end` event carries no headers. No leg showed this, but the unary runtime reads those headers; the stream path should too.
16. **Generated docs for streaming methods** say "Transcode: no HTTP rule, follows the Connect path", which is now wrong. They should say the method's default path, in the transport's stream framing.

## 10. 1.0 posture

**Can land in a minor after 1.0 (additive):** the streaming types and functions (`ServerStreaming`, `Rpc.Stream`, `Session`); the framings, `withStreamFraming` and `connectEnvelope`; the companion file, a later `Rpc.Stream.Element`, a `ready` hook, gRPC-Web. Streaming errors reuse existing constructors (`RpcStatus` with the already-reserved `ConnectEndStream`, `StatusBody`, `HttpStatus`, `NoAnswer Timeout`/`NetworkError`, `BadResponse`), so no exhaustive `case` in an application breaks.

**Decide or reserve before 1.0:**
- **The `--streaming` option values.** After 1.0, `skip` must keep meaning "skip every streaming method", or generated output would change under an unchanged option. Reserve the new value names now (`server`, and possibly one that skips client/bidi) and document what `skip` will mean.
- **Keep `Rpc.Error.Reason` and `Source` free of new streaming constructors**, or reserve them now, since adding a constructor breaks exhaustive matches. The spike needed none.
- **The shape of generated streaming methods**, if 1.0 promises generated modules are stable across minors.

## 11. Run 1 code found wrong while using it

1. Over `transcode`, a stream on a method without a rule spoke Connect, which no transcoder serves for streams. Fixed (section 5).
2. The core misread Envoy's pre-stream Status body: a protocol error for the array framing, a silent clean end for SSE, and an **empty message** for NDJSON. Fixed, with node tests at every split point.
3. Run 1's protocol note on Envoy errors before the first message is wrong for a connect-go upstream. Corrected here; `STREAMING-NOTES.md` is left as run 1 wrote it.
4. The `services::streaming` diagnostic text is stale under `streaming=server`, and `gen --help` lists only `error|skip`.
5. Generated docs for streaming methods describe the transcode path wrongly (question 16).
6. The header of `runtime/stream.test.mjs` says `node --test runtime/`, which fails on Node 24. `node --test runtime/stream.test.mjs` works.
7. Not a bug but a trap: Session reconnects are gated on idempotency (question 12).

## 12. Run 2 commits (all pushed)

- 16fd21d Stream the implicit route in the transport framing
- 5aa009b Add streaming cases to the live suite (the harness, 22 cases, two new Envoy listeners, a pre-stream refusal in `WatchNotes`, the conformance README)
- 7570c6a Stream Eliza's Introduce in the example page
- f7571f7 Prototype a connect-stream custom element
