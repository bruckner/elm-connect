module Rpc exposing
    ( Call, call
    , Config, config, checkConfig
    , task, send, cancel
    , taskTraced, sendTraced
    , Error, Response
    , Request, request, response, taskFromRequest, splitTrailers
    )

{-| Call RPCs: unary and JSON-encoded, over the
[Connect protocol](https://connectrpc.com/docs/protocol/) as connect-go,
connect-es, connect-python and Envoy's Connect filter serve it, or over HTTP
transcoding, the REST mapping `google.api.http` rules describe, as
grpc-gateway, Envoy's gRPC-JSON transcoder and Vanguard serve it.

    Notes.V1.NotesService.getNote { name = "notes/42" }
        |> Rpc.send (Rpc.config "https://api.example.com") GotNote

A generated service module has one function per method, which applied to a
request gives a [`Call`](#Call): data saying what to call with what. A
[`Config`](#Config), also data, says where and how; the functions here take
both and send the call as a `Task` or a `Cmd`, or give the HTTP request it
stands for and read the answer, without sending anything.

An application usually wraps the sending once, deriving the config from its
own state:

    rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
    rpc shared call =
        Rpc.task (configFor shared) call


# Calls

@docs Call, call

[`Rpc.Call`](Rpc-Call) adjusts a call and reads it back.


# Config

@docs Config, config, checkConfig


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

@docs Request, request, response, taskFromRequest, splitTrailers

-}

import Dict exposing (Dict)
import Http
import Json.Encode
import Proto.Method exposing (Method)
import Rpc.Call
import Rpc.Code exposing (Code)
import Rpc.Error
import Rpc.Internal.Answer
import Rpc.Internal.Call
import Rpc.Internal.Http as Internal
import Rpc.Internal.Retry
import Rpc.Internal.Trace
import Rpc.Internal.Wire
import Rpc.Request
import Rpc.Response
import Rpc.Retry exposing (Retry)
import Rpc.Trace exposing (Trace)
import Rpc.Transport exposing (Transport)
import Task exposing (Task)
import Time



-- CALLS


{-| A method applied to its request, as generated code builds one per method:

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note

It is [`Rpc.Call.Call`](Rpc-Call#Call), where a call is adjusted
(`withHeaders`, `withTimeout`, `withTracker`, `viaBinding`) and read
(`serviceName`, `methodName`, `descriptor`, `toJson`, …).

-}
type alias Call req res =
    Rpc.Call.Call req res


{-| A call of a method with a request, without any adjustment. Generated code
applies it to each method's [`Method`](Proto-Method#Method):

    getNote =
        Rpc.call
            (Method.method Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                descriptorGetNote
            )

-}
call : Method req res -> req -> Call req res
call m req =
    Rpc.Internal.Call.Call
        { method = m
        , message = req
        , binding = 0
        , headers = []
        , timeout = Nothing
        , tracker = Nothing
        }



-- CONFIG


{-| Where and how to send calls. It is plain data, with no functions in it, so
it can be stored in a model, compared, and built per call from an
application's state with record syntax:

    { config | transport = Rpc.Transport.transcode, timeout = Just 5000 }

  - `transport`: the protocol, with its own options
    ([`Rpc.Transport`](Rpc-Transport)).
  - `baseUrl`: the server, with any routing prefix (`https://api.example.com`,
    `/api`). A trailing `/` is dropped. A call's path is appended to it, so it
    can hold no query or fragment: a call sent with a `baseUrl` holding `?` or
    `#` is not sent, and fails with `NoAnswer (BadUrl url)`.
    [`checkConfig`](#checkConfig) finds that where the config is built.
  - `headers`: sent with every call, such as `( "Authorization", "Bearer …" )`.
    A name must be an HTTP token (letters, digits and `` !#$%&'*+-.^_`|~ ``),
    and a value, but for spaces and tabs at either end, can hold no NUL, CR
    or LF and no character above U+00FF, which a browser refuses. A call
    with such a header is not sent, and fails with
    `NoAnswer (InvalidHeader name)`; the header is never altered to fit.
  - `timeout`: milliseconds. Connect also tells the server, in
    `Connect-Timeout-Ms`. A timeout that is not a positive number (`0`, a
    negative number, NaN or infinity) means no timeout, as `Nothing` does.
  - `withCredentials`: send cookies and other credentials cross-origin
    (`Http.riskyRequest`).
  - `retry`: whether and when to try a failed call again
    ([`Rpc.Retry`](Rpc-Retry)).

-}
type alias Config =
    { transport : Transport
    , baseUrl : String
    , headers : List ( String, String )
    , timeout : Maybe Float
    , withCredentials : Bool
    , retry : Maybe Retry
    }


{-| The config for a server: Connect, every call POSTed, no extra headers, no
timeout, no credentials cross-origin and no retries.
-}
config : String -> Config
config baseUrl =
    { transport = Rpc.Transport.connect
    , baseUrl = baseUrl
    , headers = []
    , timeout = Nothing
    , withCredentials = False
    , retry = Nothing
    }


{-| What is wrong with a config, one sentence each, or `[]` when nothing is:
the problems sending would otherwise find one call at a time. Run it where the
application builds its config, at start-up or when its settings change, and
report what it finds there:

    case Rpc.checkConfig cfg of
        [] ->
            Ok cfg

        problems ->
            Err (String.join "; " problems)

Today it finds a `baseUrl` holding a query or a fragment, and headers a
request cannot carry, each by its name (a value is left out, since it may be
a credential). A call sent with such a config still fails with
`NoAnswer (BadUrl url)` or `NoAnswer (InvalidHeader name)`; this finds it
before any call is made. Later releases may find more, so the result is read
as a list rather than matched.

-}
checkConfig : Config -> List String
checkConfig cfg =
    (if badBaseUrl cfg then
        [ "baseUrl " ++ cfg.baseUrl ++ " holds a query or a fragment (? or #), after which a call's path cannot go" ]

     else
        []
    )
        ++ List.filterMap
            (\( name, value ) ->
                if not (Internal.validHeaderName name) then
                    Just ("header " ++ quote name ++ " has a name that is not an HTTP token")

                else if not (Internal.validHeaderValue value) then
                    Just ("header " ++ quote name ++ " has a value a request cannot carry (NUL, CR, LF or a character above U+00FF)")

                else
                    Nothing
            )
            cfg.headers


quote : String -> String
quote text =
    Json.Encode.encode 0 (Json.Encode.string text)



-- SENDING


{-| Send a call.

    Notes.getNote { name = "notes/42" }
        |> Rpc.task config

A call whose URL or headers cannot be sent (see [`Config`](#Config)) is not:
it fails with `NoAnswer`, and nothing reaches elm/http.

-}
task : Config -> Call req res -> Task Error res
task cfg c =
    taskFromRequest cfg c (request cfg c)


{-| Send a call, giving the result to `toMsg`. The message comes before the
call, as in `Task.attempt` and `Http.expectJson`, so a call pipes into it as
into [`task`](#task):

    Notes.getNote { name = "notes/42" }
        |> Rpc.send config GotNote

-}
send : Config -> (Result Error res -> msg) -> Call req res -> Cmd msg
send cfg toMsg ((Rpc.Internal.Call.Call fields) as c) =
    let
        sent =
            request cfg c
    in
    if cfg.retry == Nothing && unsendable cfg sent == Nothing then
        Internal.send (response cfg c) toMsg fields.tracker sent

    else
        Task.attempt toMsg (taskFromRequest cfg c sent)


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

Only `send` without a [`Retry`](Rpc-Retry#Retry) policy puts the tracker on
its request, as does an application sending a request from
[`request`](#request) itself with the tracker on its `Http.request`. A call
sent with a retry policy has no tracker and cannot be cancelled: it runs on
and reports its result. The tasks, [`task`](#task) and
[`taskTraced`](#taskTraced) under [`sendTraced`](#sendTraced), ignore the
tracker too; one run under `Process.spawn` and stopped with `Process.kill`
reports nothing, and has no trace, since its attempts and duration end with
the process.

-}
cancel : String -> Cmd msg
cancel =
    Http.cancel



-- TRACING


{-| Send a call, and say what happened along with the result.
-}
taskTraced : Config -> Call req res -> Task Never ( Trace, Result Error res )
taskTraced cfg c =
    let
        sent =
            request cfg c
    in
    Time.now
        |> Task.andThen
            (\start ->
                attempt cfg c sent
                    |> Task.andThen
                        (\outcome ->
                            Time.now
                                |> Task.map
                                    (\end ->
                                        ( Rpc.Internal.Trace.init cfg.transport c sent outcome (toFloat (Time.posixToMillis end - Time.posixToMillis start))
                                        , outcome.result
                                        )
                                    )
                        )
            )


{-| Send a call, giving what happened and the result to `toMsg`.

    Notes.getNote { name = "notes/42" }
        |> Rpc.sendTraced config GotNote

-}
sendTraced : Config -> (Trace -> Result Error res -> msg) -> Call req res -> Cmd msg
sendTraced cfg toMsg c =
    Task.perform (\( trace, result ) -> toMsg trace result) (taskTraced cfg c)



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


{-| The request a call sends. It is built whatever the config holds, a `baseUrl`
with a query or a header a request cannot carry included; sending it is what
refuses those.

Over Connect, a POST goes to `baseUrl/service/method` with the request's JSON
as its body and `Connect-Protocol-Version: 1`. With
[`connectGet`](Rpc-Transport#connectGet), a call of an
`IdempotencyNoSideEffects` method is a GET of the same URL with the query
`connect=v1&encoding=json&message=…`, the JSON percent-encoded, unless the URL
would be longer than [`withMaxGetUrl`](Rpc-Transport#withMaxGetUrl) allows. A timeout is sent as `Connect-Timeout-Ms`,
rounded up to a whole millisecond. The config's headers come first, then the
call's.

Over transcoding, the request is the binding's method, the path filled from the
request, the query from the fields outside the path and the body, and the body
as the binding says, with the config's headers, then the call's. Values are
written as proto3 JSON writes them, unquoted: enums by name, 64-bit integers in
decimal, timestamps in RFC 3339. Query names and values are percent-encoded, as
are path values: every byte but RFC 3986's unreserved characters, and in a
variable matching several segments, but `/` too. A binding's literal segments
and custom verb are written as they are, but for a character a path segment
cannot hold, which is percent-encoded (a `%` followed by two hex digits is
kept as an escape); generated bindings hold none. A call without bindings is
the request Connect would POST.

-}
request : Config -> Call req res -> Request
request =
    Rpc.Internal.Wire.request


badBaseUrl : Config -> Bool
badBaseUrl cfg =
    Internal.badBaseUrl cfg.baseUrl


{-| What an answer to a call means: the decoded response, or the error.

Over Connect, success is status 200. Over transcoding, it is any 2xx, an empty
body reading as `{}`, and the response decoded from the field the binding's
`responseBody` names when it names one. Any other answer is an error, read as
[`Source`](Rpc-Error#Source) describes, whatever the transport.

-}
response : Config -> Call req res -> Http.Response String -> Result Error res
response cfg =
    Rpc.Internal.Answer.toResult cfg.transport


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

The trace applies the rule whatever the transport. Transcoding servers do not
name headers so: grpc-gateway, for one, sends a gRPC trailer as a header
prefixed `Grpc-Trailer-`, which stays a header.

-}
splitTrailers : Dict String String -> { headers : Dict String String, trailers : Dict String String }
splitTrailers =
    Internal.splitTrailers


{-| Send a request in place of the one a call would send, and read the answer as
the call's. The config's retry policy applies. A request whose URL or headers
cannot be sent is not, as with [`task`](#task).
-}
taskFromRequest : Config -> Call req res -> Request -> Task Error res
taskFromRequest cfg c sent =
    attempt cfg c sent
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
attempt : Config -> Call req res -> Request -> Task Never (Rpc.Internal.Retry.Outcome Error res)
attempt cfg c sent =
    case unsendable cfg sent of
        Just error ->
            Task.succeed { attempts = 0, metadata = Nothing, result = Err error }

        Nothing ->
            Internal.task (\answer -> Ok ( Internal.metadataOf answer, response cfg c answer )) sent
                |> Rpc.Internal.Retry.run cfg.retry (Rpc.Call.idempotency c) retryCode


{-| Why a request must not reach elm/http: a `baseUrl` holding a query or a
fragment, or a header a browser refuses, on which XHR's `setRequestHeader`
throws outside elm/http's handler and stops the program for good.
-}
unsendable : Config -> Request -> Maybe Error
unsendable cfg sent =
    if badBaseUrl cfg then
        Just (Rpc.Error.NoAnswer (Rpc.Error.BadUrl sent.url))

    else
        Internal.invalidHeader sent.headers
            |> Maybe.map (Rpc.Error.NoAnswer << Rpc.Error.InvalidHeader)


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
