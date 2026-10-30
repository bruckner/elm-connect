module Rpc exposing
    ( Json, Proto
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
([`Rpc.Protocol.connectProto`](Rpc-Protocol#connectProto)).

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
[`Proto`](#Proto): a client sends only calls whose generated code has its
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

@docs Json, Proto


# Calls

@docs Call, call

[`Rpc.Call`](Rpc-Call) adjusts a call and reads it back.


# Clients

@docs Client, client

[`Rpc.Client`](Rpc-Client) sets a client's headers, timeout, credentials and
retry policy, and [`Rpc.Protocol`](Rpc-Protocol) its protocol.


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
import Proto.Method exposing (Method)
import Rpc.Call
import Rpc.Client
import Rpc.Code exposing (Code)
import Rpc.Error
import Rpc.Internal.Answer
import Rpc.Internal.Call
import Rpc.Internal.Client as Client
import Rpc.Internal.Http as Internal
import Rpc.Internal.Plan as Plan exposing (Plan, Reader(..))
import Rpc.Internal.Retry
import Rpc.Internal.Trace
import Rpc.Protocol exposing (Protocol)
import Rpc.Request
import Rpc.Response
import Rpc.Trace exposing (Trace)
import Task exposing (Task)
import Time



-- CODECS


{-| The codec tag of proto3 JSON: [`Rpc.Protocol.Json`](Rpc-Protocol#Json).
A client of [`Rpc.Protocol.connect`](Rpc-Protocol#connect) or
[`transcode`](Rpc-Protocol#transcode) is a `Client Json`, and sends calls of
code generated with `codec=json` (the default) or `codec=both`.
-}
type alias Json =
    Rpc.Protocol.Json


{-| The codec tag of protobuf binary: [`Rpc.Protocol.Proto`](Rpc-Protocol#Proto).
A client of [`Rpc.Protocol.connectProto`](Rpc-Protocol#connectProto) or
[`Rpc.Protocol.grpcWeb`](Rpc-Protocol#grpcWeb) is a `Client Proto`, and sends calls of code generated with `codec=proto` or
`codec=both`.
-}
type alias Proto =
    Rpc.Protocol.Proto



-- CALLS


{-| A method applied to its request, as generated code builds one per method:

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call Rpc.Json GetNoteRequest Note

It is [`Rpc.Call.Call`](Rpc-Call#Call), where a call is adjusted
(`withHeaders`, `withTimeout`, `withRetry`, `withoutRetry`, `withTracker`,
`viaBinding`) and read (`serviceName`, `methodName`, `procedure`, `toJson`,
…).
Code generated with `codec=both` gives calls free in the codec
(`Rpc.Call codec GetNoteRequest Note`), which any client sends.

-}
type alias Call codec req res =
    Rpc.Call.Call codec req res


{-| A call of a method with a request, without any adjustment. Generated code
applies it to each method's [`Method`](Proto-Method#Method):

    getNote =
        Rpc.call
            (Method.json "notes.v1.NotesService"
                "GetNote"
                Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
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
variable's template, or whose request is over the protocol's
[`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes), is not: it fails with
`NoAnswer`, and nothing reaches elm/http.

-}
task : Client codec -> Call codec req res -> Task Error res
task cl c =
    let
        plan =
            Plan.plan cl c
    in
    fromPlan cl c plan (plan.request ())


{-| Send a call, giving the result to `toMsg`.

    Notes.getNote { name = "notes/42" }
        |> Rpc.send client GotNote

The retry policy in effect applies as it does to [`task`](#task). The call's
tracker is put on its request, so [`cancel`](#cancel) can stop it, only when
no policy is in effect.

-}
send : Client codec -> (Result Error res -> msg) -> Call codec req res -> Cmd msg
send ((Client.Client cl) as client_) toMsg ((Rpc.Internal.Call.Call fields) as c) =
    let
        plan =
            Plan.plan client_ c

        sent =
            plan.request ()
    in
    if Rpc.Internal.Call.retryIn cl.retry c == Nothing && Plan.refused cl.baseUrl plan sent == Nothing then
        Internal.send
            (case plan.reader of
                TextReader read ->
                    Http.expectStringResponse toMsg read

                BytesReader read ->
                    Http.expectBytesResponse toMsg (read >> Tuple.second)
            )
            fields.tracker
            sent

    else
        Task.attempt toMsg (fromPlan client_ c plan sent)


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
taskTraced ((Client.Client cl) as client_) c =
    let
        plan =
            Plan.plan client_ c

        sent =
            plan.request ()
    in
    Time.now
        |> Task.andThen
            (\start ->
                attempt client_ c plan sent
                    |> Task.andThen
                        (\outcome ->
                            Time.now
                                |> Task.map
                                    (\end ->
                                        ( Rpc.Internal.Trace.init cl.protocol c plan (firstAttempt client_ c plan sent) outcome (toFloat (Time.posixToMillis end - Time.posixToMillis start))
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


{-| Why a call failed: [`Rpc.Error.Error`](Rpc-Error#Error), where its kinds
are matched and its code, message and details read.
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


{-| The request a call sends over a client. It is built whatever the client
and the call hold, a base URL with a query, a header a request cannot carry
or a path value its template cannot match included; sending it is what
refuses those.
-}
request : Client codec -> Call codec req res -> Request
request cl c =
    (Plan.plan cl c).request ()


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
            Err (Rpc.Internal.Answer.otherFailure answer)


{-| What an answer read as bytes means, for a client speaking protobuf binary.

    Http.request
        { …
        , expect = Http.expectBytesResponse GotNote (Rpc.responseBytes client call)
        , …
        }

-}
responseBytes : Client Proto -> Call Proto req res -> Http.Response Bytes -> Result Error res
responseBytes cl c answer =
    case (Plan.plan cl c).reader of
        BytesReader read ->
            Tuple.second (read answer)

        TextReader _ ->
            -- Not reached: a protocol speaking protobuf binary holds a bytes
            -- wire. Read as the failure it would be, as `response` does.
            Err (Rpc.Internal.Answer.bytesFailure answer)


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
    Internal.splitTrailers


{-| Send a request in place of the one a call would send, and read the answer
as the call's. The retry policy in effect applies, and the call's tracker is
ignored, as with [`task`](#task).
-}
taskFromRequest : Client codec -> Call codec req res -> Request -> Task Error res
taskFromRequest cl c sent =
    fromPlan cl c (Plan.plan cl c) sent


fromPlan : Client codec -> Call codec req res -> Plan res -> Request -> Task Error res
fromPlan cl c plan sent =
    attempt cl c plan sent
        |> Task.mapError never
        |> Task.andThen
            (\outcome ->
                case outcome.result of
                    Ok value ->
                        Task.succeed value

                    Err error ->
                        Task.fail error
            )


{-| Send `sent` until it succeeds or the retry policy says to stop.
-}
attempt : Client codec -> Call codec req res -> Plan res -> Request -> Task Never (Rpc.Internal.Retry.Outcome Error res)
attempt (Client.Client cl) c plan sent =
    case Plan.refused cl.baseUrl plan sent of
        Just error ->
            Task.succeed { attempts = 0, metadata = Nothing, result = Err error }

        Nothing ->
            Rpc.Internal.Retry.run (Rpc.Internal.Call.retryIn cl.retry c)
                (Rpc.Call.idempotency c)
                retryCode
                (\left ->
                    Internal.task
                        (case plan.reader of
                            TextReader read ->
                                Http.stringResolver (\answer -> Ok ( Internal.metadataOf answer, read answer ))

                            BytesReader read ->
                                Http.bytesResolver (read >> Ok)
                        )
                        (Plan.withBudget plan left sent)
                )


{-| The request the first attempt sends: `sent`, its timeout bounded by the
retry policy's deadline when there is one.
-}
firstAttempt : Client codec -> Call codec req res -> Plan res -> Request -> Request
firstAttempt (Client.Client cl) c plan sent =
    Plan.withBudget plan
        (Rpc.Internal.Call.retryIn cl.retry c |> Maybe.andThen (\policy -> Rpc.Internal.Retry.startBudget policy 0))
        sent


{-| The code a failed attempt is retried by, or `Nothing` when trying again
cannot help.
-}
retryCode : Error -> Maybe Code
retryCode error =
    case error of
        Rpc.Error.NoAnswer (Rpc.Error.BadUrl _) ->
            -- Nothing was sent, and nothing would change.
            Nothing

        _ ->
            Just (Rpc.Error.code error)
