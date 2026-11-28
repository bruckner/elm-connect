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
| `Proto.Json` | the proto3 JSON helpers generated codecs call, and writing a message's JSON yourself ([below](#writing-json-yourself)) |
| `Proto.Json.Encoder` | the encoder's type, which `Proto.Json` names `Proto.Json.Encoder` |
| `Proto.Binary` | the protobuf binary wire format over elm/bytes, for binary codecs |
| `Proto.Unknown` | the fields read from a protobuf binary whose field numbers or types are unrecognized, kept under `unknown_fields=keep` ([generator.md](generator.md#options)) |
| `Proto.Timestamp`, `Proto.Duration`, `Proto.Value`, `Proto.Int64`, `Proto.Bytes` | the well-known types' Elm forms (`Proto.Value` for `Value`, `Struct` and `ListValue`), and conversions for 64-bit integers and bytes |
| `Proto.Message`, `Proto.Enum` | a type's typed value (its codecs with its default and descriptor) and its descriptor as data |
| `Proto.Field`, `Proto.EnumValue` | the parts of a descriptor: a field with its unions and its `google.api.field_behavior`, an enum value |
| `Proto.Method` | a method's typed value (request encoder, response decoder, service and method name, idempotency and routes) and its descriptor as data |
| `Proto.Route`, `Proto.Query` | the route a binding sends a call over, and the helpers generated route functions and query encoders call ([transcoding.md](transcoding.md)) |
| `Proto.Http` | a method's `google.api.http` rule as data, in its descriptor or for a method written by hand |
| `Proto.WellKnown` | the well-known types' typed values |
| `Proto.Descriptors` | descriptors by full name |
| `Proto.Registry` | the table an `Any` is converted through between proto3 JSON and protobuf binary, strict until made lenient |
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
| base URL | `Rpc.client` | the server, with any routing prefix (`https://api.example.com`, `/api`); a trailing `/` is dropped. It can hold no query or fragment: a call is then not sent, and fails as a `BadCall` |
| headers | `Rpc.Client.withHeaders` | sent with every call, before the call's own; each list given goes after those given before |
| timeout | `Rpc.Client.withTimeout` | milliseconds; over Connect also sent as `Connect-Timeout-Ms`, rounded up to a whole millisecond, and over gRPC-Web as `grpc-timeout`. A value that is not a positive number means no timeout |
| credentials | `Rpc.Client.withCredentials` | send cookies and other credentials cross-origin (`Http.riskyRequest`) |
| retry policy | `Rpc.Client.withRetry` | whether and when to try a failed call again ([Retries](#retries)) |

`Rpc.Client.protocol`, `baseUrl`, `headers`, `timeout`, `credentials`
and `retry` read them back, and `Rpc.Client.toJson` gives the whole
client as data, for logs and tests. A client's type carries its
protocol's codec, `Rpc.Client Rpc.Json` or `Rpc.Client Rpc.Binary`
([Choosing the codec](#choosing-the-codec)). A client holds its
protocol's functions, so it belongs in code: a top-level value, one
built in `init`, or one a wrapper builds per call from the
application's state ([Wrapping the sending once](#wrapping-the-sending-once)).
Clients built alike are `==` when their registry is a top-level value, and
clients that differ in anything else compare unequal; two otherwise alike,
each with a registry built where the client is, hold different functions,
and `==` throws on them. A client never belongs in a message.

A header name must be an HTTP token, and a value can hold no NUL, CR or
LF and no character above U+00FF, which a browser refuses. A call with
such a header is not sent: it fails as a `BadCall` naming the
header, and the header is never altered to fit.

### When a client cannot send

Nothing checks a client before its calls: whatever is wrong with one
fails the call, where the error reaches the code that handles every
other. A base URL holding `?` or `#` makes every call fail unsent, its
`Rpc.Error.cause` `BadCall`, and a URL the browser refuses comes back as
a `BadCall` too; so does a call with a header a request cannot carry. `Rpc.request` gives the same error without sending
anything. Whether a base URL reaches the right server only a request can
show.

## Protocols

```elm src/Rpc/Protocol.elm excerpt
connect : Protocol Json
connectBinary : Protocol Binary
transcode : Protocol Json
grpcWeb : Protocol Binary
withConnectGet : Protocol codec -> Protocol codec
withMaxGetUrl : Int -> Protocol codec -> Protocol codec
```

- `Rpc.Protocol.connect`: the Connect protocol, every call a POST to
  `baseUrl/<package>.<Service>/<Method>` with the request's JSON as its
  body and `Connect-Protocol-Version: 1`.
- `Rpc.Protocol.connectBinary`: the Connect protocol over protobuf
  binary ([Choosing the codec](#choosing-the-codec)).
- `Rpc.Protocol.transcode`: HTTP transcoding, by the method's
  `google.api.http` rule: the rule's verb, the path filled from the
  request, the query from the fields outside the path and the body, and
  the body as the rule says. A method without a rule goes over the
  implicit route ([transcoding.md](transcoding.md)).
- `Rpc.Protocol.grpcWeb`: gRPC-Web, for a server or proxy that serves it
  and not Connect (connect-go, Envoy's gRPC-Web filter, grpcwebproxy):
  every call a POST to the same URL as Connect's, in protobuf binary
  ([Choosing the codec](#choosing-the-codec)).

`Rpc.Protocol.withConnectGet` makes Connect send a call of a method
declared `option idempotency_level = NO_SIDE_EFFECTS;` as a GET with the
request in the query (`connect=v1&encoding=json&message=…`), which
caches can serve. Any other call is POSTed, whatever its
`google.api.http` rule says. The request then appears in URLs, so in
browser history and in server and proxy logs.
`Rpc.Protocol.withMaxGetUrl n` POSTs a call whose GET URL would be
longer than `n` characters (2048 is a common safe value). Only Connect
sends a GET, so both leave `transcode` and `grpcWeb` as they are.

```elm examples/notes/elm/src/Snippets/Configuring.elm#protocols
getClient : Rpc.Client Rpc.Json
getClient =
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
`"connect"`, `"transcode"` or `"grpc-web"`, and `Rpc.Protocol.codec` `"json"` or
`"proto"`, for logs; `Rpc.Protocol.toJson` gives a protocol with its
options.

### Choosing the codec

```elm src/Rpc.elm excerpt
type alias Json =
type alias Binary =
```

Messages travel as proto3 JSON over `connect` and `transcode`, and as
protobuf binary over `connectBinary` and `grpcWeb`. Over `connectBinary`, a POST carries the request's
binary as `application/proto`, a GET the query
`connect=v1&base64=1&encoding=proto&message=…` with the binary in
unpadded URL-safe base64, and a successful answer is read as binary,
which must come as `application/proto` or with no content type, as one
over `connect` must come as `application/json` or with none. Error
answers are JSON whatever the codec, as the protocol sends them, and are
read as they are over `connect`.

Over `grpcWeb`, a POST carries the request's binary in one gRPC-Web frame
as `application/grpc-web+proto`, with `X-Grpc-Web: 1` and the timeout
as `grpc-timeout`. A successful answer is the response's frame followed
by a trailers frame holding `grpc-status: 0`; an error is the status in
a trailers frame, or in the headers when the body is empty
(trailers-only), with `grpc-message` percent-decoded and the details
read from `grpc-status-details-bin`. A browser reads those headers on a
cross-origin answer only when the server exposes them
(`Access-Control-Expose-Headers`); trailers in a body need nothing. A
traced call gives a body's trailers as the trace's trailers.

The codec is in the types. A protocol is a `Protocol Rpc.Json` or a
`Protocol Rpc.Binary`, the client built on it an `Rpc.Client Rpc.Json`
or an `Rpc.Client Rpc.Binary`, and a call carries the codecs the
generator's `wire` option wired its method with
([generator.md](generator.md)):

| Generated with | A call's type | Sent by |
|---|---|---|
| `wire=both` (the default) | `Rpc.Call codec req res` | any client |
| `wire=json` | `Rpc.Call Rpc.Json req res` | a `connect` or `transcode` client |
| `wire=proto` | `Rpc.Call Rpc.Binary req res` | a `connectBinary` or `grpcWeb` client |

`both` is the default so that every call goes to every client, whichever
protocol the application picks; `json` and `proto` are an opt-in for an
application that speaks one codec alone, narrowing each call's type and
leaving the other codec's code behind the calls out of its bundle. The
default costs a program that names no typed value the most: a client of
one JSON call is 7.2 KB gzipped (40 %) larger and starts 1.3 ms later
under `both` than under `json`, where the notes example, whose typed
values hold both codecs already, is 76 B larger.

A client sends only calls of its codec, and the compiler says where one
does not, so a call never reaches the network without the codec its
client sends, and never falls back to the other one. `transcode` is
JSON by definition, so binary goes over Connect or gRPC-Web
([transcoding.md](transcoding.md)), and gRPC-Web is binary alone.

Pick binary for a server that serves only `application/proto`, for
smaller messages (a 1,000-element repeated message takes 55 % fewer
bytes than its JSON, 39 % fewer once both are gzipped), or to read error
details that arrive without their JSON; JSON stays the readable
default, which every transcoder takes and a browser's network panel
shows.

### Size limits

`Rpc.Protocol.withReadMaxBytes n` caps a successful answer's body at
`n` bytes (of UTF-8, or of the binary under the binary codec; over
gRPC-Web, of the response message, not its frame), on any protocol, as connect-go's
`WithReadMaxBytes` and connect-node's `readMaxBytes` do. A body over it is
dropped before decoding and the call fails as a `BadResponse` that
keeps the answer's status and headers, code `ResourceExhausted`;
an error answer is still read for its status. The browser has received
the body by then, so the limit bounds what is decoded and held, not what
is downloaded.

`Rpc.Protocol.withWriteMaxBytes n` caps the request message's JSON, or
its binary under the binary codec, the same way, as connect-go's `WithSendMaxBytes` and connect-node's
`writeMaxBytes` do: a call over it is never sent, and fails as a
`BadCall`, code `ResourceExhausted`. Neither has a limit by
default, as in connect-node; connect-go reads at most 4 MiB unless told
otherwise, and connect-web, the browser transport, has no such knob.
A limit below 1 is no limit: it removes one set earlier, as if none had
been set.

### Nesting depth

Reads are limited to 100 levels of nesting, as protobuf's own runtimes
limit them, against one budget. What counts is every message that
*nests*: one that, through its fields, map values and oneof members at
any depth, reaches a message on a cycle of references (a message that
holds itself, directly or through other messages), a
`google.protobuf.Value`, `Struct` or `ListValue`, or an `Any`. A message
on a cycle nests. Read at the top, such a message is level 1, and below
it every level counts:

- each message that nests, whether on the same cycle, on another cycle,
  or on none;
- each `google.protobuf.Any`, the message it holds counting on from it
  (in a JSON read, which converts it through the registry);
- each array and object of a `Value`, `Struct` or `ListValue`, counting
  on from the message that holds it.

So a read of 100 levels succeeds and one of 101 fails, however many
kinds of message the path passes through: a `Tree` holding a `Node`,
both recursive, takes 100 levels between them, not 100 each, and in
`message Doc { Tree root = 1; }`, read as a `Doc`, the `Doc` is level 1
and the outermost `Tree` level 2. A call whose binding has a
`response_body` reads the answer as a response holding that one field
([transcoding.md](transcoding.md)), so when the response nests it is
level 1 and the answer counts from 2.

A message that does not nest is not counted: nothing it holds can nest,
so the schema bounds its depth, and its codecs are what they would be
in a schema with nothing that nests. The generator warns of a chain of
more than 100 messages (`types::deep_nesting`), which most protobuf
runtimes refuse to read: reads here refuse it too when its messages
nest, and read it to its end when they do not. Whether a message nests
depends only on the messages it reaches, never on what holds it, so a
package's generated code is the same whatever else is generated beside
it.

A schema with no recursion pays for this where a message holds a
`Struct`, a `Value`, a `ListValue` or an `Any`: that message, and every
message holding it, nests, so its codecs take the depth. A message on no
cycle has no table of decoders: its decoder at a depth is built as the
value is read. In the notes example, where 4 of the 8 messages nest, the
program grows by 215 bytes optimized, minified and gzipped, and reads
within 1 %; a schema of 50 messages each holding a `Struct` grows
by about 7 bytes gzipped a message, and reading 20 of them in a list
below another message takes about 12 % longer in JSON
([decisions.md](decisions.md#a-union-for-googleprotobufvalue-one-depth-budget)
has the measurements). A program whose messages do not nest compiles to
what it did.

A message inside an `Any` that cannot itself hold an `Any` (a `Value`,
`Struct` or `ListValue`, or a message whose fields reach no `Any`) is
read by its own decoder, which counts from 1 instead. Its levels are
limited to 100 apart from those outside the `Any`, so the deepest such
read is 200 levels: 99 messages, the `Any`, and 100 levels inside it.
An `Any` read from binary holds the message's bytes unread; unpacking
it, or writing it as JSON, reads them with the same count from 1.
The limit bounds the depth of nested `Any`s, not the work of converting
them: each conversion re-reads the payload inside it, so a large payload
held many `Any`s deep takes seconds to minutes even when it is accepted
([descriptors.md](descriptors.md#what-converting-an-any-costs)).

The unit is the same in JSON and binary, so 100 levels read in one read
in the other. Past them a binary read fails with `Proto.Error.TooDeep`
and a JSON read with "Expecting messages nested at most 100 deep"; over
a call the error is a `BadResponse`. For a `Value`, `Struct` or
`ListValue` the error is at the field holding it and does not say where
inside the value the limit was passed. Every read path returns the error
and throws nothing, however deep the input: checked at 100,000 levels of
the three kinds mixed in node, Chromium, Firefox and WebKit. Without a
limit, about 500 levels in Chromium and node, 800 to 1,200 in Firefox
and 3,000 to 5,000 in Safari overflow the JavaScript stack, and an
overflow inside `update` stops the program from running any further
command.

An error the runtime returns holds no JSON nested more than 50 levels
deep: in its place is the string `"(JSON nested more than 50 levels
deep, left out)"`, so `Json.Decode.errorToString` and
`Proto.Error.toString` print a few hundred characters for input
100,000 levels deep.

What is not limited, and can still overflow the stack or print without
end, is the application's own:

| What the application does | Overflows past about (node, Chromium / Firefox / WebKit) |
|---|---|
| `Proto.Json.encode` of a message it built (generated encoder): a recursive message, a `Struct` | 600 to 800, 400 to 600 / 800 to 1,000, 600 to 800 / 3,000 to 5,000, 10,000 to 20,000 levels |
| binary encoding of a value it built (`Proto.Binary.encode`, `Proto.Any.pack`, `Rpc.request` of a binary call) | 480 / 610 / 5,500 levels |
| `Json.Encode.encode` of a `Json.Encode.Value` it built | 5,000 to 6,000 / 3,700 / 40,000 levels |
| `Json.Decode.errorToString` of an error from its own `Json.Decode.decodeString` or `decodeValue` with a generated decoder, which the runtime never sees to scrub | 2,600 to 3,100 / 2,050 / 11,700 input levels |
| `Debug.toString` of a deep value (development builds) | 1,250 / 3,000 / 7,000 levels |

The depths are measured from the runtime's own encoders and elm/json;
a `Proto.Value.Value` the program builds deeper than any it reads, written
through `Proto.Value.toJson` or either codec, overflows too, at depths not
measured. Writing is not limited, as in protobuf's own runtimes: a value
read through the limit writes in both codecs, but one the program builds
can be deeper. Bound the depth where the program builds such values, and
read a failure from its own decoders by following the error to its
`Json.Decode.Failure` rather than printing the whole error. Its own
recursive decoders and functions over deep values are its own to bound
too. An `Any` read from binary holds its message's bytes, unread; when
it is converted to JSON (`Proto.Any.toJson`, or writing a message holding
it as JSON), the conversion counts the `Any`s and the messages around them
as a read does, and an `Any` past the limit fails the write with
`TooDeep`, so what was read from binary writes as JSON or fails, and does
not overflow.

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
end past it, and each attempt's timeout, `Connect-Timeout-Ms` or
`grpc-timeout` included, is cut to what is left of it.

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
acted is then made again. A call that could not be made, or an answer
that could not be used (a `BadCall` or a `BadResponse`,
[Errors](#the-http-exchange)), is never retried, whatever its code:
trying again would fail the same way. So the policy above does not
retry a request over the write limit, though its code is
`ResourceExhausted`.

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
next : Retry -> { tried : Int, error : Error, idempotency : Idempotency, now : Time.Posix, elapsed : Float } -> Maybe Float
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
                    , error = err
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
viaBinding : Int -> Call Json req res -> Maybe (Call Json req res)
```

`Rpc.Call` adjusts a call before it is sent: headers after the client's,
a timeout in milliseconds in place of the client's, a retry policy in
place of the client's (`withRetry`) or none (`withoutRetry`), a tracker
for cancelling, and, for transcoding, another of the rule's bindings (`0` is
the rule's own, `1` and up its `additional_bindings`). Transcoding speaks
JSON, so `viaBinding` takes a JSON call: one generated under `wire=both`
becomes a `Call Rpc.Json` where it is applied. A call is one codec where it
is used: a function that takes a call as its argument cannot both send it
over `Rpc.Binary` and read its JSON. A generated call is free in the codec
at each use, as is one bound in a `let`, so such a function takes the call
twice, or the JSON beside it.

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
`idempotency`, `requestMessage`, `requestJson` and `toJson`, the last
two of a JSON call, since a call generated under `wire=proto` has no
JSON to write. The method's descriptor, with its type names and HTTP rule as data, is not
on the call: name it, `Notes.V1.NotesService.descriptorGetNote`.

## Sending

```elm src/Rpc.elm excerpt
task : Client codec -> Call codec req res -> Task Error res
send : Client codec -> (Result Error res -> msg) -> Call codec req res -> Cmd msg
cancel : String -> Cmd msg
```

`Rpc.task` sends a call as a `Task`, for chaining; `Rpc.send` as a
`Cmd`, giving the result to a message. A call whose URL or headers
cannot be sent is not: it fails as a `BadCall`, and nothing reaches
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

A failed call gives `Rpc.Error`, one type for every protocol, read in
three layers. On top is the RPC: a code, a message and details. Underneath
is the HTTP exchange the RPC went over: elm/http's error, with the answer
kept. Under that is the codec, for a body that did not decode. An
application reads the layer it thinks in: one calling an RPC API reads
codes, one calling a REST API over transcoding may read HTTP statuses.

### The RPC

```elm src/Rpc/Error.elm excerpt
code : Error -> Code
message : Error -> String
details : Error -> List (Result Proto.Error.Error Any)
source : Error -> Maybe Source
```

Every error has a code, an `Rpc.Code.Code`, and a message.
`Rpc.Error.toString` is the two for logs (`not_found: no such note`).

- When the server stated a status, in a Connect error body, a
  `google.rpc.Status` body or gRPC's status headers or trailers, the
  code and message are the server's, and so are the details: each an
  `Any`, or the problem that kept it from being read, which
  `Proto.Any.unpack` reads by type
  ([descriptors.md](descriptors.md#error-details)). `source` says where
  the status was stated ([below](#where-a-status-comes-from)).
- When the server answered with a failure and stated none, as a proxy's
  502 page does, `source` is `Nothing`, the code is inferred from the
  HTTP status (see [A failure that states no
  status](#a-failure-that-states-no-status)), the message is the status
  text, and there are no details.
- Otherwise the client produced the error, and the code is its own, as
  the Connect clients give it: a timeout is `DeadlineExceeded`; a
  network failure `Unavailable`, which is also how a browser's CORS
  refusal arrives; a call that could not be made `Internal`, or
  `InvalidArgument` for a transcoded call's path value its template
  cannot match and for a request value proto3 JSON has no form for, or
  `ResourceExhausted` for a request over its size limit; an answer that could not be used `Internal`, or
  `ResourceExhausted` for one over its size limit, `Unknown` for a
  success that is not the protocol's answer, and `Unimplemented` for a
  unary gRPC-Web answer with status 0 and no message or more than one.

A message holds no value from the request or the answer, beyond the
message a server stated, so every one is safe to log or show: a body
that did not decode is `bad response body`, a bad URL is `bad URL: the
base URL holds a query or a fragment` or `bad URL: the browser could
not read it`, and a header is named without its value.

A request value with no proto3 JSON form is `bad value: a
google.protobuf.Timestamp with no JSON form (the time is outside years 1
to 9999)`, naming the type and what is wrong, never the value or where
it is.

The client's codes and the inferred ones have server meanings too: a
request over the client's write limit is `ResourceExhausted`, as a
server's quota is, and an edge's bare 429 reads as `Unavailable`. Code
that acts on a code the server stated checks that it stated one:

```elm examples/notes/elm/src/Snippets/Reading.elm#server-said
{-| Whether the server asked the caller to slow down: a `ResourceExhausted`
it stated, not the client's for a request over its limit, nor one inferred
from an edge's bare status.
-}
slowDown : Rpc.Error -> Bool
slowDown error =
    Rpc.Error.source error /= Nothing && Rpc.Error.code error == Rpc.Code.ResourceExhausted
```

### The HTTP exchange

```elm src/Rpc/Error.elm excerpt
cause : Error -> Cause
type Cause
    = BadCall
    | NetworkError
    | Timeout
    | BadStatus Response
    | BadResponse Response
httpStatus : Error -> Maybe Int
```

`cause` is what happened underneath, and it is elm/http's error with the
answer kept:

| elm/http | `Rpc.Error.cause` |
|---|---|
| `BadUrl _` | `BadCall` |
| `Timeout` | `Timeout` |
| `NetworkError` | `NetworkError` |
| `BadStatus n` | `BadStatus answer`, with `answer.statusCode == n`, which can be 200 (below) |
| `BadBody _` | `BadResponse answer` |

- `BadCall`: the call could not be made, and nothing was sent: a base
  URL holding `?` or `#`, or one the browser refuses; a header a
  request cannot carry; a transcoded call's path value its template
  cannot match; a request over the write limit; or an `Any` the
  client's registry cannot write as JSON. `Rpc.Error.message` says
  which.
- `NetworkError`, `Timeout`: the request went out and nothing came
  back.
- `BadStatus answer`: the server answered with a failure, a failure
  status or a success whose answer states a failing status (as gRPC-Web's
  trailers do). The answer is an `Rpc.Response` with its URL, status,
  status text, headers and body, for errors in a shape the runtime does
  not read. Over gRPC-Web a failure is stated in the trailers of a 200, so
  a reader that branches on `answer.statusCode` should not assume a
  failing status there; `code` is the reading for it.
- `BadResponse answer`: the server answered with success, always a 2xx,
  and the answer could not be used: its body is not the response
  message, as when the schema drifted between client and server; its
  content type is another of the protocol's than the call reads
  (`application/json` under the binary codec); a gRPC-Web answer's
  framing or trailers are malformed; it is over the read limit, kept
  without its body ([Size limits](#size-limits)); or it is not the
  protocol's answer at all. Over Connect and gRPC-Web, a 200 whose
  content type is none of the protocol's (Connect's
  `application/json`, `application/proto`, `application/connect+json`
  and `application/connect+proto`; any `application/grpc-web…`), such
  as a proxy's HTML page, is not the protocol's answer: a status it
  carries is a `BadStatus`, and with none it is a `BadResponse` whose
  code is `Unknown`. Transcoding reads any success as its answer,
  whatever its content type, since a REST server may label JSON
  `text/plain`; a success with no content type is read as the answer.

`httpStatus` is the status of the answer, if one came. A `BadCall` or a
`BadResponse` is never retried ([Retries](#retries)).

Whether the request reached the server, and whether the error came from
it:

| `cause` | Did the request reach the server? | Did the error come from the server? |
|---|---|---|
| `BadCall` | no | no |
| `NetworkError` | probably not; a CORS refusal arrives so after the server acted | no |
| `Timeout` | unknown | no |
| `BadResponse` | yes | no: the client could not use the answer |
| `BadStatus` | something answered | when `source` is not `Nothing`; otherwise possibly an edge or a proxy |

### The codec

```elm src/Rpc/Error.elm excerpt
protoError : Error -> Maybe Proto.Error.Error
```

For a body that did not decode as the response message, and for a
request that could not be written as JSON, `protoError` is the problem
itself: `BadJson` with elm/json's error, `BadBinary` with the report of
where and why, `UnregisteredType` for an `Any` of a type the client's
registry lacks, or `BadValue` for a request value proto3 JSON has no form
for, with its type and the path to it. It is `Nothing` for every other
error. `Proto.Error.toString` describes it in full; that text can quote
the value that failed, and so hold the answer's or the request's data,
and a `BadValue`'s path holds the keys of the maps it passes through.

For a report that must not carry that data, walk the `Json.Decode.Error`
for its path and its text and leave out the value beside them. This
package's decoders write a failure's text as what was expected and never
what was found, so the walk is safe for every failure they give; it does
not cover a text from a decoder of the application's own that puts a
value in it.

```elm examples/notes/elm/src/Snippets/Report.elm#report
import Json.Decode
import Proto.Error
import Rpc
import Rpc.Error


decodeReport : Rpc.Error -> Maybe String
decodeReport error =
    case Rpc.Error.protoError error of
        Just (Proto.Error.BadJson problem) ->
            Just (located "json" problem)

        Just (Proto.Error.BadValue value) ->
            -- A request value with no JSON form: its path can hold a map's
            -- keys; the message never quotes the value.
            Just ("no JSON form: " ++ value.typeName ++ ", " ++ value.message)

        Just other ->
            -- A binary report, a type URL or a type mismatch: no value.
            Just (Proto.Error.toString other)

        Nothing ->
            Nothing


located : String -> Json.Decode.Error -> String
located path problem =
    case problem of
        Json.Decode.Field name inner ->
            located (path ++ "." ++ name) inner

        Json.Decode.Index index inner ->
            located (path ++ "[" ++ String.fromInt index ++ "]") inner

        Json.Decode.OneOf ways ->
            String.join "; or " (List.map (located path) ways)

        Json.Decode.Failure text _ ->
            path ++ ": " ++ text
```

### Errors of the application's own

An `Rpc.Error` is what the call's answer was, and nothing in it fits a
failure the application finds in a good answer, such as a list missing
the item it asked for. Give such a failure the application's own error
type, one constructor holding an `Rpc.Error` and others for its own
failures, and map into it where the application sends its calls, with
`Task.mapError` on the task (see [Wrapping the sending
once](#wrapping-the-sending-once)) and `Task.andThen` failing with its
own constructor when the answer does not serve. `Rpc.Error`'s builders
(`fromStatus`, `fromCode`, `fromResponse`, `timeout`, `networkError`,
`badCall`, `badAny`, `badValue`, `badResponse`, `badBody`, `withMessage`) make errors
for tests and previews, and for application code: an application that
fails a call itself before sending, such as an auth layer that will not
send without a session, builds `Rpc.Error.badCall Rpc.Code.Unauthenticated
"not signed in"`, which says nothing was sent and is never retried. The
runtime builds its own errors with the same functions, so the two compare
with `==`.

### A failure that states no status

Its code is the [Connect protocol's
mapping](https://connectrpc.com/docs/protocol/#http-to-error-code) of
the HTTP status (`Rpc.Code.fromHttpStatus`), and for some statuses it
is not the code a server would have sent in a status body
([`google/rpc/code.proto`](https://github.com/googleapis/googleapis/blob/master/google/rpc/code.proto)
gives each code's HTTP status):

| HTTP status | Inferred code | Sent in a status body with |
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
last four apart by the HTTP status, not by the code.

### Where a status comes from

`Rpc.Error.source` says where the status was read; the runtime tries
each in this order, whatever the protocol:

- `ConnectBody`: a Connect error body, `{"code": "not_found", …}`. A
  code the protocol does not name, `"ok"` included, and a missing or
  `null` code beside a string `message` take the code
  `Rpc.Code.fromHttpStatus` gives the answer's status, as the protocol
  tells a client to infer one, the message and details kept.
- `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as
  grpc-gateway and Vanguard send.
- `GrpcHeaders`: the `grpc-status` and `grpc-message` headers, as Envoy's
  transcoder sends an error by default, when the browser exposes them
  ([transcoding.md](transcoding.md#errors-in-headers)); and a gRPC-Web
  answer without a body, with its details in `grpc-status-details-bin`.
- `GrpcTrailers`: the `grpc-status`, `grpc-message` and
  `grpc-status-details-bin` trailers that end a gRPC-Web answer's body.

A failure with none of these has no source.

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
request : Client codec -> Call codec req res -> Result Error Request
response : Client Json -> Call Json req res -> Http.Response String -> Result Error res
responseBytes : Client Binary -> Call Binary req res -> Http.Response Bytes -> Result Error res
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

`Rpc.request` gives `Err` with the error sending would fail with, for
every call sending refuses: a base URL holding `?` or `#`, a request
with no proto3 JSON ([Writing JSON yourself](#writing-json-yourself)), a
path value its template cannot match, a header a request cannot carry,
or a request over the write limit. So what it gives `Ok` is exactly what
`Rpc.task` and `Rpc.send` would send, and a refused call has no request
to show: each refusal is a `BadCall` naming what is wrong.

Under the binary codec a successful answer is binary, which text cannot
hold (the browser has replaced what is not UTF-8 by then), so a call
sent by hand over a `Client Rpc.Binary` reads its answer as bytes, with
`Http.expectBytesResponse` and `Rpc.responseBytes`. Over a
`Client Rpc.Json`, `Rpc.response` reads it as text, paired with
`Http.expectStringResponse`: the browser decodes the text natively, and
a program that reads nothing as bytes carries no elm/bytes. The client's
type says which one applies. A request's
body is text (`Rpc.Body.toText`) or bytes (`Rpc.Body.toBytes`), sent as
the type `Rpc.Body.contentType` gives.

A request's `headers` are those the runtime and the client add, not all
that go out: sending a request with a body adds its `Content-Type`
(`application/json`, or `application/proto` under the binary codec, or
`application/grpc-web+proto` over gRPC-Web), which
elm/http sets from the body, and
the browser adds its own, so a test of `Rpc.request` sees neither.

`Rpc.splitTrailers` splits an answer's headers as a Connect unary answer
carries its metadata, the `trailer-` ones apart, for an application that
reads answers through the halves. A gRPC-Web answer's trailers are in
its body: `Rpc.responseBytes` reads the status from them, and only a
traced send gives them as trailers.

## Writing JSON yourself

A call writes its request itself. To write a message's proto3 JSON
outside a call, to store it or send it some other way, run its
generated encoder with `Proto.Json`:

```text
Proto.Json.encodeTotal (Notes.V1.encodeGetNoteRequest request)
--> a Json.Encode.Value

Proto.Json.encode (encodeEvent event)
--> Result Proto.Error.Error Json.Encode.Value, for an event holding a Timestamp

Proto.Json.encodeWith registry (Notes.V1.encodeNote note)
--> the same, an Any in the note converted through registry
```

A generated `encodeNote : Note -> Proto.Json.Encoder x` describes the
JSON and writes nothing until one of the three runs it. Its type says
whether the write can be refused:

- `Proto.Json.Encoder x`, free in `x`: the message holds nothing a write
  can refuse, and `encodeTotal` writes it with no `Result`.
- `Proto.Json.Encoder Proto.Error.Error`: the message holds, at any depth,
  a `Timestamp`, `Duration`, `FieldMask`, `Struct`, `Value`, `ListValue`
  or `Any`. `encode` writes it, or refuses; `encodeWith registry` does
  the same with the registry an `Any` it holds converts through
  ([descriptors.md](descriptors.md#registries)), where `encode` has an
  empty one.

A refusal is `Proto.Error.BadValue { typeName, path, message }` for a
value proto3 JSON has no form for: a `Timestamp` outside years 1 to
9999 or with nanoseconds out of form, a `Duration` that is not valid, a
`FieldMask` path with no lowerCamelCase form, or a number in a
`Value`, `Struct` or `ListValue` that is NaN or infinite. `path` leads
from the message to the value by JSON field names, list indexes and map
keys (`[ "events", "3", "createTime" ]`); `message` says which of these
is wrong (`"the time is outside years 1 to 9999"`), and never quotes the
value or a map key. An `Any` fails as converting it
does, `UnregisteredType` for a type the registry lacks or its message's
`BadBinary`. Protobuf's own JSON writers refuse the same values; the
binary codec writes any of them, since binary has a form for each.

The refusal is in the type so that it cannot be forgotten and cannot
break code that handles it: when a message gains a refusable field, at
any depth, its encoder becomes `Encoder Proto.Error.Error`, code that
writes it with `encode` or `encodeWith` compiles as before, and only an
`encodeTotal` of it stops compiling, at the place the new failure has to
be handled. A `Timestamp` or `Duration` the application builds is
always valid; one read from protobuf binary is held as the peer wrote
it and is refused when it is not valid (a timestamp outside years 1 to
9999 or with nanoseconds outside 0 to 999,999,999; a duration past
protobuf's range, or its nanoseconds of a second or more or of the
other sign than its seconds).

Over a call the same check runs before anything is sent: over a JSON
protocol the request's JSON is written first, and a request with no JSON
is not sent. The call fails as a `BadCall`: `Rpc.Error.badValue`'s
`InvalidArgument` for a value with no JSON form, `Rpc.Error.badAny`'s
`Internal` for an `Any` that cannot be written, the problem in
`Rpc.Error.protoError`. That holds over every binding, the path and the
query included ([transcoding.md](transcoding.md#what-a-call-sends)).
Over protobuf binary the call is sent.

Hand-written values go in as encoders too: `Proto.Json.succeed` makes an
encoder of JSON already written, for a `Proto.Message` or a method built
by hand (`Proto.Method.initJson "notes.v1.Notes" "GetNote"
(Proto.Json.succeed << encodeMine) decoder`).

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
        |> Rpc.Client.withRegistry registry
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
`Rpc.taskFromRequest`. A call `Rpc.request` refuses has no request to
rewrite, so its error is the task's:

```elm examples/notes/elm/src/Snippets/Signed.elm#signed
signed : Rpc.Client codec -> Rpc.Call codec req res -> Task Rpc.Error res
signed client call =
    case Rpc.request client call of
        Ok request ->
            { request | headers = ( "X-Signature", sign request ) :: request.headers }
                |> Rpc.taskFromRequest client call

        Err error ->
            Task.fail error
```

A request's body is sent as its content type, which elm/http adds:
`headers` does not list `Content-Type`.
