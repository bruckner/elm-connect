module Rpc.Trace exposing
    ( Trace
    , serviceName, methodName, procedure, protocol, codec, binding, request
    , httpStatus, headers, trailers, code, duration, attempts
    , toJson, toString
    )

{-| What happened when a call was sent, for logs and metrics: what
[`Rpc.taskTraced`](Rpc#taskTraced) and [`Rpc.sendTraced`](Rpc#sendTraced) give
beside the result.

    GotNote trace result ->
        ( model, log (Rpc.Trace.toString trace) )

@docs Trace


# The call

@docs serviceName, methodName, procedure, protocol, codec, binding, request


# The outcome

@docs httpStatus, headers, trailers, code, duration, attempts


# Logging

@docs toJson, toString

-}

import Dict exposing (Dict)
import Json.Encode as Encode exposing (Value)
import Rpc.Body as Body
import Rpc.Code as Code exposing (Code)
import Rpc.Internal.Trace as Internal
import Rpc.Request exposing (Request)


{-| A trace. It is opaque: a traced send gives you one, and the functions
below read it. The package site and compiler errors may show it as
`Rpc.Internal.Trace.Trace`, its name inside the package; that module is not
exposed.
-}
type alias Trace =
    Internal.Trace


{-| The call's fully-qualified service name, such as `notes.v1.NotesService`,
as [`Rpc.Call.serviceName`](Rpc-Call#serviceName) gives it.
-}
serviceName : Trace -> String
serviceName (Internal.Trace t) =
    t.serviceName


{-| The call's method name as declared, such as `GetNote`, as
[`Rpc.Call.methodName`](Rpc-Call#methodName) gives it.
-}
methodName : Trace -> String
methodName (Internal.Trace t) =
    t.methodName


{-| The call's Connect procedure path, such as
`/notes.v1.NotesService/GetNote`, as
[`Rpc.Call.procedure`](Rpc-Call#procedure) gives it.
-}
procedure : Trace -> String
procedure (Internal.Trace t) =
    "/" ++ t.serviceName ++ "/" ++ t.methodName


{-| The name of the protocol the call went over, as
[`Rpc.Protocol.name`](Rpc-Protocol#name) gives it: `"connect"` or
`"transcode"`.
-}
protocol : Trace -> String
protocol (Internal.Trace t) =
    t.protocol


{-| The codec its messages travelled in, as
[`Rpc.Protocol.codec`](Rpc-Protocol#codec) gives it: `"json"` or `"proto"`.
-}
codec : Trace -> String
codec (Internal.Trace t) =
    t.codec


{-| The HTTP binding the call went over (as
[`Rpc.Call.viaBinding`](Rpc-Call#viaBinding) numbers them), or `Nothing` when
there was none to use: over Connect, or the implicit route of a method without
a rule.
-}
binding : Trace -> Maybe Int
binding (Internal.Trace t) =
    t.binding


{-| The request sent. Under a retry policy with a deadline
([`Rpc.Retry.withDeadline`](Rpc-Retry#withDeadline)) it is the first
attempt's, its timeout bounded by the deadline; a later attempt's is bounded
by what is left of it.
-}
request : Trace -> Request
request (Internal.Trace t) =
    t.request


{-| The HTTP status of the last answer, or `Nothing` when there was none (a
timeout, a network failure).
-}
httpStatus : Trace -> Maybe Int
httpStatus (Internal.Trace t) =
    t.httpStatus


{-| The last answer's response headers, without its trailers, split by
[`Rpc.splitTrailers`](Rpc#splitTrailers): names lowercased, and a header the
server sent more than once with its values joined by `", "` in the order they
came, which is how elm/http (and the browser before it) gives them. Empty when
there was no answer.
-}
headers : Trace -> Dict String String
headers (Internal.Trace t) =
    t.headers


{-| The last answer's trailers: the headers named `trailer-<name>`, as a
Connect unary answer carries them, by [`Rpc.splitTrailers`](Rpc#splitTrailers).
The rule applies whatever the protocol. Empty when there was no answer.
-}
trailers : Trace -> Dict String String
trailers (Internal.Trace t) =
    t.trailers


{-| The code of the error the call ended with, [`Rpc.Error.code`](Rpc-Error#code) of
it, so a timeout is `Just DeadlineExceeded`; `Nothing` when it succeeded.
-}
code : Trace -> Maybe Code
code (Internal.Trace t) =
    t.code


{-| Milliseconds from before the first attempt to after the last, by
`Time.now`, the waits between retries included.
-}
duration : Trace -> Float
duration (Internal.Trace t) =
    t.duration


{-| How many times the call was sent, retries included: `0` when it was not
sent at all, for a bad `baseUrl`, a header a request cannot carry or a
request over the protocol's
[`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes).
-}
attempts : Trace -> Int
attempts (Internal.Trace t) =
    t.attempts


{-| Every field of the trace as JSON, under these keys, which stay:

    {
        "service": "notes.v1.NotesService",
        "method": "GetNote",
        "procedure": "/notes.v1.NotesService/GetNote",
        "protocol": "connect",
        "codec": "json",
        "binding": null,
        "request": {
            "method": "POST",
            "url": "https://api.example.com/notes.v1.NotesService/GetNote",
            "headers": [["Connect-Protocol-Version", "1"]],
            "body": "{\"name\":\"notes/42\"}",
            "timeout": null,
            "withCredentials": false
        },
        "httpStatus": 200,
        "headers": {"content-type": "application/json"},
        "trailers": {},
        "code": "ok",
        "duration": 12,
        "attempts": 1
    }

`service`, `method` and `procedure` are the keys
[`Rpc.Call.toJson`](Rpc-Call#toJson) gives a call. The request's headers are pairs, in order, since a name may repeat; the
answer's are an object. `code` is the outcome as Connect spells it
(`"not_found"`), `"ok"` on success; `duration` and the request's `timeout`
are in milliseconds; `binding`, `httpStatus`, the body and the timeout are
`null` when absent. A request body of protobuf binary
(a client speaking [`Rpc.Proto`](Rpc#Proto)) is `null` as `body` and is
given as base64 under one more key, `bodyBase64`.

The request holds what was sent, the client's headers included, so a bearer
token in them is in the JSON too; [`toString`](#toString) leaves the request
out.

-}
toJson : Trace -> Value
toJson (Internal.Trace t) =
    Encode.object
        [ ( "service", Encode.string t.serviceName )
        , ( "method", Encode.string t.methodName )
        , ( "procedure", Encode.string (procedure (Internal.Trace t)) )
        , ( "protocol", Encode.string t.protocol )
        , ( "codec", Encode.string t.codec )
        , ( "binding", maybe Encode.int t.binding )
        , ( "request"
          , Encode.object
                ([ ( "method", Encode.string t.request.method )
                 , ( "url", Encode.string t.request.url )
                 , ( "headers", Encode.list (\( k, v ) -> Encode.list Encode.string [ k, v ]) t.request.headers )
                 , ( "body", maybe Encode.string (Body.toText t.request.body) )
                 , ( "timeout", maybe Encode.float t.request.timeout )
                 , ( "withCredentials", Encode.bool t.request.withCredentials )
                 ]
                    ++ (case t.requestBase64 of
                            Just base64 ->
                                [ ( "bodyBase64", Encode.string base64 ) ]

                            Nothing ->
                                []
                       )
                )
          )
        , ( "httpStatus", maybe Encode.int t.httpStatus )
        , ( "headers", Encode.dict identity Encode.string t.headers )
        , ( "trailers", Encode.dict identity Encode.string t.trailers )
        , ( "code", Encode.string (Maybe.map Code.toString t.code |> Maybe.withDefault "ok") )
        , ( "duration", Encode.float t.duration )
        , ( "attempts", Encode.int t.attempts )
        ]


maybe : (a -> Value) -> Maybe a -> Value
maybe encode value =
    Maybe.map encode value |> Maybe.withDefault Encode.null


{-| One line for a log: the method, the protocol, how the call ended, the
last answer's HTTP status, the attempts and the duration in whole
milliseconds.

    notes.v1.NotesService/GetNote over connect: ok, HTTP 200, 1 attempt, 12 ms
    notes.v1.NotesService/ListNotes over transcode (binding 1): unavailable, no answer, 3 attempts, 610 ms

It leaves out the request, whose URL and body hold the request message and
whose headers may hold credentials.

-}
toString : Trace -> String
toString (Internal.Trace t) =
    t.serviceName
        ++ "/"
        ++ t.methodName
        ++ " over "
        ++ t.protocol
        ++ (case t.binding of
                Just index ->
                    " (binding " ++ String.fromInt index ++ ")"

                Nothing ->
                    ""
           )
        ++ ": "
        ++ (Maybe.map Code.toString t.code |> Maybe.withDefault "ok")
        ++ ", "
        ++ (case t.httpStatus of
                Just status ->
                    "HTTP " ++ String.fromInt status

                Nothing ->
                    "no answer"
           )
        ++ ", "
        ++ String.fromInt t.attempts
        ++ (if t.attempts == 1 then
                " attempt, "

            else
                " attempts, "
           )
        ++ String.fromInt (round t.duration)
        ++ " ms"
