# Calling

A generated service function applied to a request gives a call,
`Rpc.Call Rpc.Json req res`: data saying which method to call with
what. A client, `Rpc.Client Rpc.Json`, says where and how: a protocol, a
base URL and what every call takes. `Rpc`'s functions take both and send
the call, or give the HTTP request it stands for without sending
anything. This page covers the client, each way of sending, and what
comes back.
The Connect protocol and the other documents the protocols follow are
listed in [specs.md](specs.md).

Until the package is published, its API reference is the documentation
comments in `src/`, starting with `src/Rpc.elm`; `elm make
--docs=docs.json` in a clone writes them as the package site would read
them. To browse them as that site would show them, run
`npx elm-doc-preview` at the root of a clone, where the package's
`elm.json` is, and open `http://localhost:8000`
([elm-doc-preview](https://github.com/dmy/elm-doc-preview) needs Node and
the Elm compiler on `PATH`). From 1.0 the reference is on the package
index, at its package page.

## The runtime's modules

The runtime package has two roots, `Proto` for data and `Rpc` for
calling:

| Module | Holds |
|---|---|
| `Rpc` | building a call and a client, sending over Connect or HTTP transcoding |
| `Rpc.Call` | a call: adjusting it and reading it back |
| `Rpc.Client` | a client: its headers, timeout, credentials and retry policy, read back and checked |
| `Rpc.Protocol`, `Rpc.Retry` | a client's protocol and retry policy |
| `Rpc.Trace` | what happened when a call was sent, for logs |
| `Rpc.Request`, `Rpc.Response`, `Rpc.Body` | a request and an answer as data, in the pure halves and errors |
| `Rpc.Error` | why a call failed: its kind, code, message and details |
| `Rpc.Code` | the codes an RPC fails with |
| `Proto.Json` | the proto3 JSON helpers generated codecs call |
| `Proto.Binary` | the protobuf binary wire format over elm/bytes, for binary codecs |
| `Proto.Timestamp`, `Proto.Duration`, `Proto.Int64`, `Proto.Bytes` | the well-known types' Elm forms, and conversions for 64-bit integers and bytes |
| `Proto.Message`, `Proto.Enum` | a type's typed value (its codecs with its default and descriptor) and its descriptor as data |
| `Proto.Field`, `Proto.EnumValue` | the parts of a descriptor: a field with its unions and its `google.api.field_behavior`, an enum value |
| `Proto.Method` | a method's typed value (request encoder, response decoder, service and method name, idempotency and routes) and its descriptor as data |
| `Proto.Route`, `Proto.Query` | the route a binding sends a call over, and the helpers generated route functions and query encoders call ([transcoding.md](transcoding.md)) |
| `Proto.Http` | a method's `google.api.http` rule as data, in its descriptor or for a method written by hand |
| `Proto.WellKnown` | the well-known types' typed values |
| `Proto.Registry` | descriptors by full name |
| `Proto.Any` | `google.protobuf.Any`: packing, unpacking and describing |
| `Proto.Version` | the releases generated code can name ([install.md](install.md#versions)) |

The `Proto` modules are [descriptors.md](descriptors.md)'s subject.

## The client

```elm src/Rpc.elm excerpt
client : Protocol codec -> String -> Client codec
```

```elm src/Rpc/Client.elm excerpt
withHeaders : List ( String, String ) -> Client codec -> Client codec
withTimeout : Float -> Client codec -> Client codec
withCredentials : Client codec -> Client codec
withRetry : Retry -> Client codec -> Client codec
```

`Rpc.client protocol baseUrl` is a client of the server at `baseUrl`
over a protocol ([Protocols](#protocols)), with no extra headers, no
timeout, no credentials cross-origin and no retries. `Rpc.Client` adds
them:

| Piece | Set by | Meaning |
|---|---|---|
| protocol | `Rpc.client` | the protocol, with its own options (below) |
| base URL | `Rpc.client` | the server, with any routing prefix (`https://api.example.com`, `/api`); a trailing `/` is dropped. It can hold no query or fragment: a call is then not sent, and fails with `NoAnswer (BadUrl url)` |
| headers | `Rpc.Client.withHeaders` | sent with every call, before the call's own; each list given goes after those given before |
| timeout | `Rpc.Client.withTimeout` | milliseconds; over Connect also sent as `Connect-Timeout-Ms`, rounded up to a whole millisecond. A value that is not a positive number means no timeout |
| credentials | `Rpc.Client.withCredentials` | send cookies and other credentials cross-origin (`Http.riskyRequest`) |
| retry policy | `Rpc.Client.withRetry` | whether and when to try a failed call again ([Retries](#retries)) |

`Rpc.Client.protocol`, `baseUrl`, `headers`, `timeout`, `credentials`
and `retry` read them back, and `Rpc.Client.toJson` gives the whole
client as data, for logs and tests. A client's type carries its
protocol's codec, `Rpc.Client Rpc.Json` or `Rpc.Client Rpc.Proto`
([Choosing the codec](#choosing-the-codec)). A client holds its
protocol's functions, so it belongs in code: a top-level value, one
built in `init`, or one a wrapper builds per call from the
application's state ([Wrapping the sending once](#wrapping-the-sending-once)).
Clients built alike are `==`; a client never belongs in a message.

A header name must be an HTTP token, and a value can hold no NUL, CR or
LF and no character above U+00FF, which a browser refuses. A call with
such a header is not sent: it fails with `NoAnswer (InvalidHeader
name)`, and the header is never altered to fit.

### Checking a client

```elm src/Rpc/Client.elm excerpt
problems : Client codec -> List String
```

`Rpc.Client.problems` reports a client's problems, one sentence each,
where the application builds it rather than at the first call: today a
base URL with a query or a fragment, headers a request cannot carry
(named, without their values), and a size limit below 1.

```elm examples/notes/elm/src/Snippets/Configuring.elm#check-client
checked : Rpc.Client codec -> Result String (Rpc.Client codec)
checked client =
    case Rpc.Client.problems client of
        [] ->
            Ok client

        problems ->
            Err (String.join "; " problems)
```

Later releases may find more, so read the result as a list rather than
matching it.

## Protocols

```elm src/Rpc/Protocol.elm excerpt
connect : Protocol Json
connectProto : Protocol Proto
transcode : Protocol Json
withConnectGet : Protocol codec -> Protocol codec
withMaxGetUrl : Int -> Protocol codec -> Protocol codec
```

- `Rpc.Protocol.connect`: the Connect protocol, every call a POST to
  `baseUrl/<package>.<Service>/<Method>` with the request's JSON as its
  body and `Connect-Protocol-Version: 1`.
- `Rpc.Protocol.connectProto`: the Connect protocol over protobuf
  binary ([Choosing the codec](#choosing-the-codec)).
- `Rpc.Protocol.transcode`: HTTP transcoding, by the method's
  `google.api.http` rule: the rule's verb, the path filled from the
  request, the query from the fields outside the path and the body, and
  the body as the rule says. A method without a rule goes over the
  implicit route ([transcoding.md](transcoding.md)).

`Rpc.Protocol.withConnectGet` makes Connect send a call of a method
declared `option idempotency_level = NO_SIDE_EFFECTS;` as a GET with the
request in the query (`connect=v1&encoding=json&message=…`), which
caches can serve. Any other call is POSTed, whatever its
`google.api.http` rule says. The request then appears in URLs, so in
browser history and in server and proxy logs.
`Rpc.Protocol.withMaxGetUrl n` POSTs a call whose GET URL would be
longer than `n` characters (2048 is a common safe value). Only Connect
sends a GET, so both leave `transcode` as it is.

```elm examples/notes/elm/src/Snippets/Configuring.elm#protocols
connectGet : Rpc.Client Rpc.Json
connectGet =
    -- GetNote, ListNotes and Ping, declared NO_SIDE_EFFECTS, become GETs;
    -- a GET whose URL would pass 2048 characters is POSTed instead.
    Rpc.client
        (Rpc.Protocol.connect
            |> Rpc.Protocol.withConnectGet
            |> Rpc.Protocol.withMaxGetUrl 2048
        )
        "https://api.example.com"
```

Protocols built alike are `==`. `Rpc.Protocol.name` gives
`"connect"` or `"transcode"`, and `Rpc.Protocol.codec` `"json"` or
`"proto"`, for logs; `Rpc.Protocol.toJson` gives a protocol with its
options.

### Choosing the codec

```elm src/Rpc.elm excerpt
type alias Json =
type alias Proto =
```

Messages travel as proto3 JSON over `connect` and `transcode`, and as
protobuf binary over `connectProto`: a POST carries the request's
binary as `application/proto`, a GET the query
`connect=v1&base64=1&encoding=proto&message=…` with the binary in
unpadded URL-safe base64, and a successful answer is read as binary,
which must come as `application/proto` or with no content type. Error
answers are JSON whatever the codec, as the protocol sends them, and are
read as they are over `connect`.

The codec is in the types. A protocol is a `Protocol Rpc.Json` or a
`Protocol Rpc.Proto`, the client built on it an `Rpc.Client Rpc.Json`
or an `Rpc.Client Rpc.Proto`, and a call carries the codecs the
generator wrote for its method ([generator.md](generator.md)):

| Generated with | A call's type | Sent by |
|---|---|---|
| `codec=json` (the default) | `Rpc.Call Rpc.Json req res` | a `connect` or `transcode` client |
| `codec=proto` | `Rpc.Call Rpc.Proto req res` | a `connectProto` client |
| `codec=both` | `Rpc.Call codec req res` | any client |

A client sends only calls of its codec, and the compiler says where one
does not, so a call never reaches the network without the codec its
client sends, and never falls back to the other one. `transcode` is
JSON by definition, so binary goes over Connect alone
([transcoding.md](transcoding.md)).

Pick binary for a server that serves only `application/proto`, for
smaller messages (a 1,000-element repeated message takes 55 % fewer
bytes than its JSON, 39 % fewer once both are gzipped), or to read error
details that arrive without their JSON; JSON stays the readable
default, which every transcoder takes and a browser's network panel
shows.

### Size limits

`Rpc.Protocol.withReadMaxBytes n` caps a successful answer's body at
`n` bytes (of UTF-8, or of the binary under the proto codec), on any
protocol, as connect-go's
`WithReadMaxBytes` and connect-node's `readMaxBytes` do. A body over it is
dropped before decoding and the call fails with
`NoAnswer (ResponseTooLarge { limit, size })`, code `ResourceExhausted`;
an error answer is still read for its status. The browser has received
the body by then, so the limit bounds what is decoded and held, not what
is downloaded.

`Rpc.Protocol.withWriteMaxBytes n` caps the request message's JSON, or
its binary under the proto codec, the same way, as connect-go's `WithSendMaxBytes` and connect-node's
`writeMaxBytes` do: a call over it is never sent, and fails with
`NoAnswer (RequestTooLarge { limit, size })`. Neither has a limit by
default, as in connect-node; connect-go reads at most 4 MiB unless told
otherwise, and connect-web, the browser transport, has no such knob.
`Rpc.Client.problems` reports a limit below 1.

## Retries

```elm src/Rpc/Retry.elm excerpt
on : List Code -> Retry
withAttempts : Int -> Retry -> Retry
withBackoff : Float -> Retry -> Retry
withMaxBackoff : Float -> Retry -> Retry
withDeadline : Float -> Retry -> Retry
withoutJitter : Retry -> Retry
allowNonIdempotent : Retry -> Retry
```

`Rpc.Retry.on codes` retries an attempt that fails with an error whose
code is one of `codes`. Its defaults:

- 3 attempts in all, the first included (`withAttempts`);
- a wait before the second attempt of up to 200 ms (`withBackoff`),
  doubling before each one after, never more than 30 seconds
  (`withMaxBackoff`);
- each wait drawn uniformly from zero to its bound, so clients that
  failed together do not retry together (`withoutJitter` waits each
  bound in full);
- only calls of a method declared `NO_SIDE_EFFECTS` or `IDEMPOTENT`
  (`option idempotency_level`);
- no deadline (`withDeadline`).

The call's timeout already applies to each attempt, so without a
deadline the worst case is the attempts times the timeout, plus the
waits. A deadline bounds them all together: no wait begins that would
end past it, and each attempt's timeout, `Connect-Timeout-Ms` included,
is cut to what is left of it.

```elm examples/notes/elm/src/Snippets/Configuring.elm#retry
retrying : Rpc.Client Rpc.Json
retrying =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"
        |> Rpc.Client.withRetry
            (Rpc.Retry.on [ Rpc.Code.Unavailable, Rpc.Code.ResourceExhausted ]
                |> Rpc.Retry.withAttempts 5
                |> Rpc.Retry.withBackoff 500
                |> Rpc.Retry.withMaxBackoff 10000
            )
```

Every error is judged by its code, so a network failure reads as
`Unavailable` and a timeout as `DeadlineExceeded`. A request that timed
out may have reached the server, so `DeadlineExceeded` belongs in the
codes only for calls that are safe to replay, which the default keeps
to. `allowNonIdempotent` retries calls of every method: for codes that
say the server did nothing, such as `Unavailable` from a proxy that
never reached it; a call with side effects that failed after the server
acted is then made again. A call that was never sent (a bad URL, an
invalid header) is never retried.

### What the policy is, and is not

The policy is the kind of retry gRPC configures as a service config's
`retryPolicy` ([gRPC retry guide](https://grpc.io/docs/guides/retry/),
[gRFC A6](https://github.com/grpc/proposal/blob/master/A6-client-retries.md)):
a bounded number of attempts on listed codes, each after an exponential
wait with a cap and jitter, run inside the client. Two things gRPC does
there are not done here: it honours the server's pushback header and
throttles retries when too many of them fail
([`Retry-After` is on the roadmap](roadmap.md#retry-after-and-retryinfo)).
It is not gRPC's *transparent retry*, which re-sends only a request the
server application is known never to have seen; a browser client cannot
know that, and this one does not claim to.

The Connect protocol has no retry semantics, and its clients ship no
policy. Its [error codes](https://connectrpc.com/docs/protocol/#error-codes)
say of `unavailable` that a client should back off and retry idempotent
operations, and leave the rest to the application. The default here is
that advice made concrete: the codes are the application's choice, and
the proto's declared idempotency keeps the policy to calls that are
safe to replay.

### The policy, the application, or both

The policy's attempts are internal to `send`: the application sees one
result, after the last of them, and nothing while they run. That is what
decides which retry a failure should get.

- **The policy**, for a transient failure that a short wait fixes and
  that needs nothing from the application: `Unavailable` from a proxy, a
  dropped connection, `ResourceExhausted` from a rate limit. It belongs
  on calls that are safe to replay, which the default keeps to.
- **The application**, for a failure that needs a change before the call
  can be tried again: a credential to refresh, the network to come back,
  a user to ask. The application also owns any wait the user should see
  or may cancel, since a policy's waits are invisible and `send` with a
  policy takes no tracker ([Cancelling](#cancelling)). An application
  that retries a call on its own sends it with `Rpc.Call.withoutRetry`
  (or sends it with a client that has no policy), unless it means the
  two to stack.
- **Both**, the common shape: the policy covers the blips and the
  application the structural failures. They multiply: every replay the
  application makes is itself retried by the policy, so a queue of ten
  calls replayed under a policy of three attempts may make thirty
  requests. Declared idempotency is what keeps that to calls that can
  stand it.

### Driving the loop yourself

```elm src/Rpc/Retry.elm excerpt
next : Retry -> { tried : Int, code : Code, idempotency : Idempotency, now : Time.Posix, elapsed : Float } -> Maybe Float
```

An application that runs the loop itself, to show that it is waiting,
to let the user cancel or to refresh something between attempts, still
gets the policy's waits, cap, attempt limit, jitter and deadline from
`Rpc.Retry.next`: the wait the runtime's own loop would take, or
`Nothing` to give up. It sends each attempt with `Rpc.Call.withoutRetry`,
or the two loops stack.

```elm examples/notes/elm/src/Snippets/Configuring.elm#driving
type NoteState
    = Loading
    | Waiting Float
    | Loaded Notes.V1.Note
    | Failed Rpc.Error


type alias Retrying =
    { started : Time.Posix, note : NoteState }


type NoteMsg
    = TryAgain Int
    | GotNote Int Time.Posix (Result Rpc.Error Notes.V1.Note)


notePolicy : Rpc.Retry.Retry
notePolicy =
    Rpc.Retry.on [ Rpc.Code.Unavailable ]
        |> Rpc.Retry.withAttempts 5
        |> Rpc.Retry.withDeadline 30000


attemptNote : Int -> Cmd NoteMsg
attemptNote tried =
    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withoutRetry
        |> Rpc.task (Rpc.client Rpc.Protocol.connect "https://api.example.com")
        |> Task.map Ok
        |> Task.onError (\err -> Task.succeed (Err err))
        |> Task.andThen (\result -> Task.map (\now -> GotNote tried now result) Time.now)
        |> Task.perform identity


updateNote : NoteMsg -> Retrying -> ( Retrying, Cmd NoteMsg )
updateNote msg model =
    case msg of
        TryAgain tried ->
            ( { model | note = Loading }, attemptNote tried )

        GotNote _ _ (Ok note) ->
            ( { model | note = Loaded note }, Cmd.none )

        GotNote tried now (Err err) ->
            case
                Rpc.Retry.next notePolicy
                    { tried = tried
                    , code = Rpc.Error.code err
                    , idempotency = Rpc.Call.idempotency (Notes.getNote { name = "notes/42" })
                    , now = now
                    , elapsed = toFloat (Time.posixToMillis now - Time.posixToMillis model.started)
                    }
            of
                Just ms ->
                    ( { model | note = Waiting ms }
                    , Process.sleep ms |> Task.perform (\_ -> TryAgain (tried + 1))
                    )

                Nothing ->
                    ( { model | note = Failed err }, Cmd.none )
```

## Adjusting one call

```elm src/Rpc/Call.elm excerpt
withHeaders : List ( String, String ) -> Call codec req res -> Call codec req res
withTimeout : Float -> Call codec req res -> Call codec req res
withRetry : Retry -> Call codec req res -> Call codec req res
withoutRetry : Call codec req res -> Call codec req res
withTracker : String -> Call codec req res -> Call codec req res
viaBinding : Int -> Call codec req res -> Maybe (Call codec req res)
```

`Rpc.Call` adjusts a call before it is sent: headers after the client's,
a timeout in milliseconds in place of the client's, a retry policy in
place of the client's (`withRetry`) or none (`withoutRetry`), a tracker
for cancelling, and, for transcoding, another of the rule's bindings (`0` is
the rule's own, `1` and up its `additional_bindings`).

```elm examples/notes/elm/src/Snippets/Configuring.elm#per-call
perCall : (Result Rpc.Error Notes.V1.Note -> msg) -> Cmd msg
perCall toMsg =
    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withTimeout 10000
        |> Rpc.Call.withHeaders [ ( "X-Request-Id", "req-7" ) ]
        |> Rpc.Call.withTracker "note-42"
        |> Rpc.send (Rpc.client Rpc.Protocol.connect "https://api.example.com") toMsg


withdraw : Cmd msg
withdraw =
    Rpc.cancel "note-42"
```

`Rpc.Call` also reads a call back: `serviceName`, `methodName`,
`procedure` (the Connect path, `/notes.v1.NotesService/GetNote`),
`idempotency`, `requestMessage`, `requestJson` and `toJson`. The
method's descriptor, with its type names and HTTP rule as data, is not
on the call: name it, `Notes.V1.NotesService.descriptorGetNote`.

## Sending

```elm src/Rpc.elm excerpt
task : Client codec -> Call codec req res -> Task Error res
send : Client codec -> (Result Error res -> msg) -> Call codec req res -> Cmd msg
cancel : String -> Cmd msg
```

`Rpc.task` sends a call as a `Task`, for chaining; `Rpc.send` as a
`Cmd`, giving the result to a message. A call whose URL or headers
cannot be sent is not: it fails with `NoAnswer`, and nothing reaches
elm/http.

### Cancelling

`Rpc.cancel tracker` aborts a call sent with `Rpc.send` and
`Rpc.Call.withTracker` (above). A cancelled call reports nothing, as
elm/http's requests do, so the application records that it withdrew the
call where it cancels, and ignores a result that arrives after: an
answer already queued when the cancel ran is still delivered.

Only `Rpc.send` without a retry policy in effect puts the tracker on its
request; under a client with a policy, a call the user may cancel is
sent with `Rpc.Call.withoutRetry`. A call sent with a retry policy, or
with `Rpc.task`, `Rpc.taskTraced` or `Rpc.sendTraced`, cannot be
cancelled this way.

## Outside the browser

The runtime runs wherever elm/http does. elm/http sends through the
browser's `XMLHttpRequest`, and Node has none, so a headless program (a
`Platform.worker` driven over ports) brings one: the `xhr2` package from
npm, or a copy of [`conformance/live/xhr.mjs`](../conformance/live/xhr.mjs),
which every suite in this repository runs the runtime through. That file
is the subset elm/http uses, over `node:http`: HTTP only, no TLS. Unlike
a browser it forbids no request header, so a program under Node can send
what a browser refuses.

[`conformance/live`](../conformance/live) is the worked example. Its
`src/Live.elm` takes a call over one port, sends it with `Rpc.task`, and
answers over another; `run.mjs` installs the shim on `globalThis` and
drives the compiled program against a running server. A generated
client can be tested against a real server the same way, which elm-test
cannot do: a test there never runs a task. Under Node, as in the browser,
the receive limit applies after the body has arrived; a shim that watched
the bytes could stop sooner, and this one does not.

## Errors

A failed call gives `Rpc.Error`, one type for every protocol, defined
in `Rpc.Error` with its readers:

```elm src/Rpc/Error.elm excerpt
type Error
    = RpcStatus StatusError Response
    | HttpStatus Response
    | BadResponse String Response
    | NoAnswer Reason
```

- `RpcStatus`: the server stated a status: its code (an
  `Rpc.Code.Code`), message, details and where it was read from.
- `HttpStatus`: the server answered with a failure and stated no
  status; the code is inferred from the HTTP status, by the table
  Connect and gRPC share (`Rpc.Code.fromHttpStatus`: 404 is
  `Unimplemented`; 429, 502, 503 and 504 are `Unavailable`).
- `BadResponse`: the server answered with success, but the body did not
  decode as the response, as when the schema drifted between client and
  server, or under the proto codec came as another content type than
  `application/proto`; code `Internal`, the message quoting elm/json's
  problem or naming the content type.
- `NoAnswer`: nothing came back, or nothing was sent: a `Timeout`
  (`DeadlineExceeded`), a `NetworkError` (`Unavailable`, which is also
  how a browser's CORS refusal arrives), a `BadUrl` or an
  `InvalidHeader` (both `Internal`, and never sent), an
  `InvalidPathValue`, a transcoded call's path value its template
  cannot match (`InvalidArgument`, never sent), a request or
  answer over a size limit (`RequestTooLarge`, `ResponseTooLarge`,
  both `ResourceExhausted`).

The first three keep the answer itself, an `Rpc.Response` with its URL,
status, headers and body, for errors in a shape the runtime does not
read and bodies that do not decode.

An `HttpStatus` code is the [Connect protocol's
mapping](https://connectrpc.com/docs/protocol/#http-to-error-code) of an
HTTP status without a status body, and for some statuses it is not the
code a server would have sent in one
([`google/rpc/code.proto`](https://github.com/googleapis/googleapis/blob/master/google/rpc/code.proto)
gives each code's HTTP status):

| HTTP status | `HttpStatus` code | Sent in a status body with |
|---|---|---|
| 401 | `Unauthenticated` | `Unauthenticated` |
| 403 | `PermissionDenied` | `PermissionDenied` |
| 503 | `Unavailable` | `Unavailable` |
| 502 | `Unavailable` | nothing: a proxy's answer |
| 400 | `Internal` | `InvalidArgument`, `FailedPrecondition`, `OutOfRange` |
| 404 | `Unimplemented` | `NotFound` |
| 429 | `Unavailable` | `ResourceExhausted` |
| 504 | `Unavailable` | `DeadlineExceeded` |
| any other | `Unknown` | |

An application whose server does not yet send status bodies tells the
last four apart by the response's `statusCode`, not by the code.

```elm src/Rpc/Error.elm excerpt
code : Error -> Code
message : Error -> String
details : Message a -> Error -> List a
toString : Error -> String
```

Every error has a code and a message. `Rpc.Error.toString` is the two
for logs (`not_found: no such note`). `Rpc.Error.details` gives the
status details of one type ([descriptors.md](descriptors.md#error-details)).

An `Rpc.Error` is what the call's answer was, and none of its
constructors fits a failure the application finds in a good answer,
such as a list missing the item it asked for: `BadResponse` and the
others carry the `Response` they read, and `NoAnswer` a reason nothing
came back. Give such a failure the application's own error type, one
constructor holding an `Rpc.Error` and others for its own failures, and
map into it where the application sends its calls, with `Task.mapError`
on the task (see [Wrapping the sending once](#wrapping-the-sending-once))
and `Task.andThen` failing with its own constructor when the answer
does not serve.

### Where a status comes from

`StatusError.source`, an `Rpc.Error.Source`, says where the status was
read; the runtime tries each in this order, whatever the protocol:

- `ConnectBody`: a Connect error body, `{"code": "not_found", …}`. A
  string `code` that is not one of Connect's names still makes the body
  a Connect body: the error is `RpcStatus` with the code `Unknown`, and
  the message and details as the body gives them.
- `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as
  grpc-gateway and Vanguard send.
- `GrpcHeaders`: the `grpc-status` and `grpc-message` headers, as Envoy's
  transcoder sends an error by default, when the browser exposes them
  ([transcoding.md](transcoding.md#errors-in-headers)).

An answer with none of these is an `HttpStatus` error.

## Tracing

```elm src/Rpc.elm excerpt
taskTraced : Client codec -> Call codec req res -> Task Never ( Trace, Result Error res )
sendTraced : Client codec -> (Trace -> Result Error res -> msg) -> Call codec req res -> Cmd msg
```

A traced send gives an `Rpc.Trace` beside the result: the call's service
and method, the protocol, codec and binding, the request sent, the last
answer's HTTP status, headers and trailers, the error's code, the
duration in milliseconds and the number of attempts.

```elm examples/notes/elm/src/Snippets/Tracing.elm#trace
type Msg
    = GotNote Rpc.Trace.Trace (Result Rpc.Error Notes.V1.Note)


traced : Rpc.Client Rpc.Json -> Cmd Msg
traced client =
    Notes.getNote { name = "notes/42" }
        |> Rpc.sendTraced client GotNote


log : Rpc.Trace.Trace -> String
log trace =
    -- {"service": "notes.v1.NotesService", "method": "GetNote", ...}
    Json.Encode.encode 0 (Rpc.Trace.toJson trace)
```

`Rpc.Trace.toJson` writes every field under keys that stay: `service`,
`method`, `procedure`, `protocol`, `codec`, `binding`, `request` (`method`, `url`, `headers`,
`body`, `timeout`, `withCredentials`, and `bodyBase64` for a binary
body, which `body` then gives as `null`), `httpStatus`, `headers`,
`trailers`, `code` (`"ok"` on success), `duration` and `attempts`. The
request holds what was sent, the client's headers included, so a bearer
token in them is in the JSON too. `Rpc.Trace.toString` is one line that
leaves the request out:

```text
notes.v1.NotesService/GetNote over connect: ok, HTTP 200, 1 attempt, 12 ms
```

## The pure halves

```elm src/Rpc.elm excerpt
request : Client codec -> Call codec req res -> Request
response : Client Json -> Call Json req res -> Http.Response String -> Result Error res
responseBytes : Client Proto -> Call Proto req res -> Http.Response Bytes -> Result Error res
taskFromRequest : Client codec -> Call codec req res -> Request -> Task Error res
```

`Rpc.task` and `Rpc.send` are `Rpc.request` and `Rpc.response` over
elm/http. `Rpc.request` gives the HTTP request a call stands for, as an
`Rpc.Request` record (`method`, `url`, `headers`, `body`, `timeout`,
`withCredentials`), and `Rpc.response` reads an `Http.Response String`
as the call's answer. Both are pure, so a test can check what a call
sends and how it reads an answer without a server
([quickstart.md](quickstart.md#7-test-without-a-server)), and
`Rpc.taskFromRequest` sends a request in place of the call's own and
reads the answer as the call's, with the client's retry policy.

Under the proto codec a successful answer is binary, which text cannot
hold (the browser has replaced what is not UTF-8 by then), so a call
sent by hand over a `Client Rpc.Proto` reads its answer as bytes, with
`Http.expectBytesResponse` and `Rpc.responseBytes`. Over a
`Client Rpc.Json`, `Rpc.response` reads it as text, paired with
`Http.expectStringResponse`: the browser decodes the text natively, and
a program that reads nothing as bytes carries no elm/bytes. The client's
type says which one applies. A request's
body is text (`Rpc.Body.toText`) or bytes (`Rpc.Body.toBytes`), sent as
the type `Rpc.Body.contentType` gives.

A request's `headers` are those the runtime and the client add, not all
that go out: sending a request with a body adds its `Content-Type`
(`application/json`, or `application/proto` under the proto codec), which
elm/http sets from the body, and
the browser adds its own, so a test of `Rpc.request` sees neither.

`Rpc.splitTrailers` splits an answer's headers as a Connect unary answer
carries its metadata, the `trailer-` ones apart, for an application that
reads answers through the halves.

## Wrapping the sending once

A client has no interceptors and no token provider, so an application
sends every call through one function of its own that builds the client
from its state:

```elm examples/notes/elm/src/Api.elm#wrapper
rpc : Shared -> Rpc.Call Rpc.Json req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (client shared) call


client : Shared -> Rpc.Client Rpc.Json
client shared =
    Rpc.client shared.protocol shared.apiUrl
        |> Rpc.Client.withHeaders [ ( "Authorization", "Bearer " ++ shared.token ) ]
```

Since a call is a value, a wrapper can send it again. Refreshing an
expired token and retrying once:

```elm examples/notes/elm/src/Snippets/Refresh.elm#refresh
withRefresh : Task Rpc.Error Shared -> Shared -> Rpc.Call Rpc.Json req res -> Task Rpc.Error res
withRefresh refresh shared call =
    rpc shared call
        |> Task.onError
            (\error ->
                if Rpc.Error.code error == Rpc.Code.Unauthenticated then
                    refresh |> Task.andThen (\fresh -> rpc fresh call)

                else
                    Task.fail error
            )
```

Several calls failing at once would each refresh; an application that
cares keeps the refresh single-flight in its update. For retrying on
codes such as `Unavailable`, the client's retry policy
(`Rpc.Client.withRetry`) needs no wrapper.

## Rewriting a request

Anything a client cannot say is a function between `Rpc.request` and
`Rpc.taskFromRequest`:

```elm examples/notes/elm/src/Snippets/Signed.elm#signed
signed : Rpc.Client codec -> Rpc.Call codec req res -> Task Rpc.Error res
signed client call =
    let
        request =
            Rpc.request client call
    in
    { request | headers = ( "X-Signature", sign request ) :: request.headers }
        |> Rpc.taskFromRequest client call
```

A request's body is sent as its content type, which elm/http adds:
`headers` does not list `Content-Type`.
