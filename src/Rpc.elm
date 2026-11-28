module Rpc exposing
    ( Json, Binary
    , Call, call
    , Client, client
    , task, send, cancel
    , taskTraced, sendTraced
    , Error, Response
    , Request, request, response, responseBytes, taskFromRequest, splitTrailers
    )

{-| Call RPCs: unary, over the
[Connect protocol](https://connectrpc.com/docs/protocol/) as connect-go,
connect-es, connect-python and Envoy's Connect-gRPC bridge serve it, over
HTTP transcoding, the REST mapping `google.api.http` rules describe, as
grpc-gateway, Envoy's gRPC-JSON transcoder and Vanguard serve it, or over
gRPC-Web ([`Rpc.Protocol.grpcWeb`](Rpc-Protocol#grpcWeb)). Messages travel
as proto3 JSON, or over Connect and gRPC-Web as protobuf binary
([`Rpc.Protocol.connectBinary`](Rpc-Protocol#connectBinary)).

    client : Rpc.Client Rpc.Json
    client =
        Rpc.client Rpc.Protocol.connect "https://api.example.com"

    fetch : Cmd Msg
    fetch =
        Notes.V1.NotesService.getNote { name = "notes/42" }
            |> Rpc.send client GotNote

A generated service module has one function per method, which applied to a
request gives a [`Call`](#Call). A [`Client`](#Client) says where and how;
the functions here take both and send the call as a `Task` or a `Cmd`, or
give the HTTP request it stands for and read the answer, without sending
anything.

A call and a client carry their codec in their type, [`Json`](#Json) or
[`Binary`](#Binary): a client sends only calls whose generated code has its
codec, and the compiler says so where one does not. An application usually
wraps the sending once:

    rpc : Rpc.Client codec -> Rpc.Call codec req res -> Task Rpc.Error res
    rpc cl c =
        Rpc.task cl c

A call holds its method's codecs, which are functions, so `==` on two calls
fails at run time, and the debugger cannot import or export a history whose
messages hold one. Compare calls by [`Rpc.Call.toJson`](Rpc-Call#toJson)
instead.


# Codecs

@docs Json, Binary


# Calls

@docs Call, call

[`Rpc.Call`](Rpc-Call) adjusts a call and reads it back.


# Clients

@docs Client, client

[`Rpc.Client`](Rpc-Client) sets a client's headers, timeout, credentials,
retry policy and registry, and [`Rpc.Protocol`](Rpc-Protocol) its protocol.


# Sending

@docs task, send, cancel


# Tracing

A traced send gives an [`Rpc.Trace`](Rpc-Trace) beside the result.

@docs taskTraced, sendTraced


# Errors

@docs Error, Response


# Requests and responses

[`task`](#task) and [`send`](#send) are [`request`](#request) and
[`response`](#response) over elm/http. Both halves are pure, so what a call
sends and how it reads the answer can be checked without a server, and an
application can rewrite a request before sending it with
[`taskFromRequest`](#taskFromRequest).

@docs Request, request, response, responseBytes, taskFromRequest, splitTrailers

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Http
import Proto.Codec
import Proto.Method exposing (Method)
import Rpc.Call
import Rpc.Client
import Rpc.Error
import Rpc.Internal.Call
import Rpc.Internal.Client as Client
import Rpc.Internal.Envelope as Envelope
import Rpc.Internal.Http as Internal
import Rpc.Internal.Plan as Plan exposing (Plan, Reader(..))
import Rpc.Internal.Retry
import Rpc.Internal.Status
import Rpc.Internal.Trace
import Rpc.Protocol exposing (Protocol)
import Rpc.Request
import Rpc.Response
import Rpc.Trace exposing (Trace)
import Task exposing (Task)
import Time



-- CODECS


{-| The codec tag of proto3 JSON: [`Proto.Codec.Json`](Proto-Codec#Json).
A client of [`Rpc.Protocol.connect`](Rpc-Protocol#connect) or
[`transcode`](Rpc-Protocol#transcode) is a `Client Json`, and sends calls of
code generated with `codec=both` (the default) or `codec=json`.
-}
type alias Json =
    Proto.Codec.Json


{-| The codec tag of protobuf binary: [`Proto.Codec.Binary`](Proto-Codec#Binary).
A client of [`Rpc.Protocol.connectBinary`](Rpc-Protocol#connectBinary) or
[`Rpc.Protocol.grpcWeb`](Rpc-Protocol#grpcWeb) is a `Client Binary`, and sends calls of code generated with `codec=binary` or
`codec=both`.
-}
type alias Binary =
    Proto.Codec.Binary



-- CALLS


{-| A method applied to its request, as generated code builds one per method:

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call codec GetNoteRequest Note

It is [`Rpc.Call.Call`](Rpc-Call#Call), where a call is adjusted
(`withHeaders`, `withTimeout`, `withRetry`, `withoutRetry`, `withTracker`,
`viaBinding`) and read (`serviceName`, `methodName`, `procedure`, `toJson`,
…).
Code generated with the default `codec=both` gives calls free in the codec,
as here, which any client sends; `codec=json` gives `Rpc.Call Rpc.Json` calls
and `codec=binary` `Rpc.Call Rpc.Binary` ones.

-}
type alias Call codec req res =
    Rpc.Call.Call codec req res


{-| A call of a method with a request, without any adjustment. Generated code
applies it to each method's [`Method`](Proto-Method#Method):

    getNote =
        Rpc.call
            (Method.initJson "notes.v1.NotesService"
                "GetNote"
                Notes.V1.encodeGetNoteRequest
                (\_ -> Notes.V1.decodeNote)
                |> Method.withIdempotency Method.IdempotencyNoSideEffects
                |> Method.withRoutes [ routeGetNote0 ]
            )

-}
call : Method codec req res -> req -> Call codec req res
call m req =
    Rpc.Internal.Call.Call
        { method = m
        , message = req
        , binding = 0
        , headers = []
        , timeout = Nothing
        , tracker = Nothing
        , retry = Rpc.Internal.Call.InheritRetry
        }



-- CLIENTS


{-| Where and how to send calls: [`Rpc.Client.Client`](Rpc-Client#Client).
-}
type alias Client codec =
    Rpc.Client.Client codec


{-| A client of a server over a protocol: [`Rpc.Client.client`](Rpc-Client#client).

    Rpc.client Rpc.Protocol.connect "https://api.example.com"

-}
client : Protocol codec -> String -> Client codec
client =
    Rpc.Client.client



-- SENDING


{-| Send a call as a `Task`.

With a retry policy in effect, the client's ([`Rpc.Client.withRetry`](Rpc-Client#withRetry))
or the call's own ([`Rpc.Call.withRetry`](Rpc-Call#withRetry)), a failed
attempt is sent again as the policy says, and the task ends with the last
attempt's result. A task ignores the call's tracker, so [`cancel`](#cancel)
cannot stop it.

A call whose URL or headers cannot be sent, whose path value cannot match its
variable's template, whose request is over the protocol's
[`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes), or, over JSON, whose
request has no proto3 JSON (a value with no JSON form, or an `Any` the
client's registry cannot write), is not: it fails with a
[`BadCall`](Rpc-Error#Cause), and nothing reaches elm/http.

-}
task : Client codec -> Call codec req res -> Task Error res
task ((Client.Client cl _ _ _) as client_) c =
    let
        plan =
            Plan.toSend client_ c
    in
    fromPlan client_ c plan (Plan.checked cl.baseUrl plan)


{-| Send a call, giving the result to `toMsg`.

    Notes.getNote { name = "notes/42" }
        |> Rpc.send client GotNote

The retry policy in effect applies as it does to [`task`](#task). The call's
tracker is put on its request, so [`cancel`](#cancel) can stop it, only when
no policy is in effect.

-}
send : Client codec -> (Result Error res -> msg) -> Call codec req res -> Cmd msg
send ((Client.Client cl _ policy _) as client_) toMsg ((Rpc.Internal.Call.Call fields) as c) =
    let
        plan =
            Plan.toSend client_ c

        checked =
            Plan.checked cl.baseUrl plan
    in
    case ( checked, Rpc.Internal.Call.retryIn policy c ) of
        ( Ok sent, Nothing ) ->
            Internal.send
                (case plan.reader of
                    TextReader read ->
                        Http.expectStringResponse toMsg read

                    BytesReader read ->
                        Http.expectBytesResponse toMsg (read >> Tuple.second)
                )
                fields.tracker
                sent

        _ ->
            Task.attempt toMsg (fromPlan client_ c plan checked)


{-| Cancel a call sent with [`send`](#send) through a tracker
([`Rpc.Call.withTracker`](Rpc-Call#withTracker)): `Http.cancel`, which aborts
the request.

A cancelled call reports nothing, as elm/http's requests do. The application
knows it withdrew the call, and records that where it cancels:

    ( { model | note = Withdrawn }, Rpc.cancel "note-42" )

One that wants a message for it batches its own:

    Cmd.batch
        [ Rpc.cancel "note-42"
        , Task.perform identity (Task.succeed (Withdrew "note-42"))
        ]

One race remains: an answer that arrived, its message queued, before the
cancel ran is still delivered, so an application that cancels keeps track of
the calls it withdrew (by the tracker, or a request id of its own) and ignores
a result that comes after.

Only `send` without a [`Retry`](Rpc-Retry#Retry) policy in effect puts the
tracker on its request, as does an application sending a request from
[`request`](#request) itself with the tracker on its `Http.request`. A call
under a client with a policy is sent so with
[`Rpc.Call.withoutRetry`](Rpc-Call#withoutRetry). A call sent with a retry
policy has no tracker and cannot be cancelled: it runs on and reports its
result. The tasks, [`task`](#task) and
[`taskTraced`](#taskTraced) under [`sendTraced`](#sendTraced), ignore the
tracker too; one run under `Process.spawn` and stopped with `Process.kill`
reports nothing, and has no trace, since its attempts and duration end with
the process.

-}
cancel : String -> Cmd msg
cancel =
    Http.cancel



-- TRACING


{-| Send a call as a `Task` that never fails, giving a
[`Trace`](Rpc-Trace#Trace) of what happened beside the result. The retry
policy in effect applies, and the trace counts every attempt and the
milliseconds from before the first to after the last, waits included.
-}
taskTraced : Client codec -> Call codec req res -> Task Never ( Trace, Result Error res )
taskTraced ((Client.Client cl over _ _) as client_) c =
    let
        plan =
            Plan.toSend client_ c

        checked =
            Plan.checked cl.baseUrl plan

        -- The request the trace shows: the one built, refused or not.
        shown =
            case plan.request () of
                Ok sent ->
                    sent

                Err _ ->
                    plan.unwritten ()
    in
    Time.now
        |> Task.andThen
            (\start ->
                attempt client_ c plan checked
                    |> Task.andThen
                        (\outcome ->
                            Time.now
                                |> Task.map
                                    (\end ->
                                        ( Rpc.Internal.Trace.init over c plan (firstAttempt client_ c plan shown) outcome (toFloat (Time.posixToMillis end - Time.posixToMillis start))
                                        , outcome.result
                                        )
                                    )
                        )
            )


{-| Send a call, giving its [`Trace`](Rpc-Trace#Trace) and the result to
`toMsg`: [`taskTraced`](#taskTraced) as a command.
-}
sendTraced : Client codec -> (Trace -> Result Error res -> msg) -> Call codec req res -> Cmd msg
sendTraced cl toMsg c =
    Task.perform (\( trace, result ) -> toMsg trace result) (taskTraced cl c)



-- ERRORS


{-| Why a call failed: [`Rpc.Error.Error`](Rpc-Error#Error), where its code,
message, details, HTTP status and answer are read.
-}
type alias Error =
    Rpc.Error.Error


{-| An answer as it arrived, its URL, status, status text, headers and body:
[`Rpc.Response.Response`](Rpc-Response#Response).
-}
type alias Response =
    Rpc.Response.Response



-- REQUESTS AND RESPONSES


{-| An HTTP request, ready to send: the data form of the record
`Http.request` takes, [`Rpc.Request.Request`](Rpc-Request#Request).
-}
type alias Request =
    Rpc.Request.Request


{-| The request a call sends over a client, or the error sending it would
fail with: what is `Ok` is exactly what [`task`](#task) and [`send`](#send)
would send. A call is refused, as they refuse it, for a base URL holding a
query or a fragment, a path value its template cannot match, a header a
request cannot carry, a request over the protocol's
[`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes), and, over JSON, a
request with no proto3 JSON: a value with no JSON form, or an `Any` the
client's registry cannot write. Each is a [`BadCall`](Rpc-Error#Cause).

    case Rpc.request client (Notes.V1.NotesService.getNote { name = "notes/42" }) of
        Ok sent ->
            sent.url == "https://api.example.com/notes.v1.NotesService/GetNote"

        Err _ ->
            False

-}
request : Client codec -> Call codec req res -> Result Error Request
request ((Client.Client cl _ _ _) as client_) c =
    Plan.checked cl.baseUrl (Plan.toSend client_ c)


{-| What an answer read as text means, for a client speaking JSON: the decoded
response, or the error.
-}
response : Client Json -> Call Json req res -> Http.Response String -> Result Error res
response cl c answer =
    case (Plan.plan cl c).reader of
        TextReader read ->
            read answer

        BytesReader _ ->
            -- Not reached: a protocol speaking JSON holds a text wire. Read
            -- as the failure it would be, so the branch adds no reader.
            Err (Rpc.Internal.Status.otherFailure answer)


{-| What an answer read as bytes means, for a client speaking protobuf binary.

    Http.request
        { …
        , expect = Http.expectBytesResponse GotNote (Rpc.responseBytes client call)
        , …
        }

-}
responseBytes : Client Binary -> Call Binary req res -> Http.Response Bytes -> Result Error res
responseBytes cl c answer =
    case (Plan.plan cl c).reader of
        BytesReader read ->
            Tuple.second (read answer)

        TextReader _ ->
            -- Not reached: a protocol speaking protobuf binary holds a bytes
            -- wire. Read as the failure it would be, as `response` does.
            Err (Rpc.Internal.Status.bytesFailure answer)


{-| Split an answer's response headers as a Connect unary answer carries its
metadata: its trailers are the headers whose names begin with `trailer-`, in
any case, and its headers the rest. Names are lowercased, and trailer names
have the prefix removed:

    splitTrailers
        (Dict.fromList
            [ ( "Content-Type", "application/json" )
            , ( "Trailer-X-Custom-Trailer", "done" )
            ]
        )
        == { headers = Dict.fromList [ ( "content-type", "application/json" ) ]
           , trailers = Dict.fromList [ ( "x-custom-trailer", "done" ) ]
           }

[`Trace`](Rpc-Trace#Trace) splits its answer's headers so; this is for the
`Http.Metadata` of an answer read through [`request`](#request) and
[`response`](#response). elm/http gives a header the server sent more than once
as one value, the values joined with `", "` in the order they came; were two
names to differ only in case, their values are joined the same way, in the
order of the names as given. A header named `trailer-` and nothing more names
no trailer, and stays a header.

The trace applies the rule whatever the protocol. Transcoding servers do not
name headers so: grpc-gateway, for one, sends a gRPC trailer as a header
prefixed `Grpc-Trailer-`, which stays a header.

-}
splitTrailers : Dict String String -> { headers : Dict String String, trailers : Dict String String }
splitTrailers =
    Envelope.splitTrailers


{-| Send a request in place of the one a call would send, and read the answer
as the call's. The retry policy in effect applies, and the call's tracker is
ignored, as with [`task`](#task). The request is usually one
[`request`](#request) gave, rewritten:

    case Rpc.request client call of
        Ok sent ->
            { sent | headers = sent.headers ++ [ ( "x-signature", sign sent ) ] }
                |> Rpc.taskFromRequest client call

        Err error ->
            Task.fail error

It is refused as [`task`](#task) refuses the call: the checks of the call's
own values (its request's JSON, its path values) are of the call, whatever
`sent` carries, and the checks of the request (its URL, its headers, its
size) are of `sent`.

-}
taskFromRequest : Client codec -> Call codec req res -> Request -> Task Error res
taskFromRequest ((Client.Client cl _ _ _) as client_) c sent =
    let
        plan =
            Plan.toSend client_ c
    in
    fromPlan client_
        c
        plan
        (case Plan.refused cl.baseUrl plan sent of
            Just error ->
                Err error

            Nothing ->
                Ok sent
        )


fromPlan : Client codec -> Call codec req res -> Plan res -> Result Error Request -> Task Error res
fromPlan cl c plan checked =
    attempt cl c plan checked
        |> Task.mapError never
        |> Task.andThen
            (\outcome ->
                case outcome.result of
                    Ok value ->
                        Task.succeed value

                    Err error ->
                        Task.fail error
            )


{-| Send a checked request until it succeeds or the retry policy says to
stop; a refused one is not sent.
-}
attempt : Client codec -> Call codec req res -> Plan res -> Result Error Request -> Task Never (Rpc.Internal.Retry.Outcome Error res)
attempt (Client.Client _ _ policy _) c plan checked =
    case checked of
        Err error ->
            Task.succeed { attempts = 0, metadata = Nothing, result = Err error }

        Ok sent ->
            Rpc.Internal.Retry.run (Rpc.Internal.Call.retryIn policy c)
                (Rpc.Call.idempotency c)
                Rpc.Internal.Retry.retryable
                (\left ->
                    Internal.task
                        (case plan.reader of
                            TextReader read ->
                                Http.stringResolver (\answer -> Ok ( Envelope.metadataOf answer, read answer ))

                            BytesReader read ->
                                Http.bytesResolver (read >> Ok)
                        )
                        (Plan.withBudget plan left sent)
                )


{-| The request the first attempt sends: `sent`, its timeout bounded by the
retry policy's deadline when there is one.
-}
firstAttempt : Client codec -> Call codec req res -> Plan res -> Request -> Request
firstAttempt (Client.Client _ _ policy _) c plan sent =
    Plan.withBudget plan
        (Rpc.Internal.Call.retryIn policy c |> Maybe.andThen (\inEffect -> Rpc.Internal.Retry.startBudget inEffect 0))
        sent
