module Rpc exposing
    ( Call, MethodDescriptor, call
    , withHeaders, withTimeout, withTracker, viaBinding
    , descriptor, service, method, idempotent, requestMessage, requestJson, toJson
    , Config, config, Transport(..), connect, Retry
    , task, send
    , Trace, taskTraced, sendTraced
    , Error(..), Source(..), errorToString
    , Request, request, response, taskFromRequest
    , Binding, binding
    , Segment, literal, variable, wildcard, doubleWildcard
    , Body, noBody, wholeBody, bodyField
    , Param, param
    )

{-| Call RPCs: unary, JSON-encoded, over the
[Connect protocol](https://connectrpc.com/docs/protocol/) as connect-go,
connect-es, connect-python and Envoy's Connect filter serve it.

    Rpc.send (Rpc.config "https://api.example.com")
        (Notes.V1.NotesService.getNote { name = "notes/42" })
        GotNote

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

@docs Call, MethodDescriptor, call


# Adjusting a call

@docs withHeaders, withTimeout, withTracker, viaBinding


# Reading a call

@docs descriptor, service, method, idempotent, requestMessage, requestJson, toJson


# Config

@docs Config, config, Transport, connect, Retry


# Sending

@docs task, send


# Tracing

@docs Trace, taskTraced, sendTraced


# Errors

@docs Error, Source, errorToString


# Requests and responses

[`task`](#task) and [`send`](#send) are [`request`](#request) and
[`response`](#response) over elm/http. Both halves are pure, so what a call
sends and how it reads the answer can be checked without a server, and an
application can rewrite a request before sending it with
[`taskFromRequest`](#taskFromRequest).

@docs Request, request, response, taskFromRequest


# HTTP bindings

A method's `google.api.http` rule, parsed by the generator and written as
data. Generated code builds these; application code only passes them along.

@docs Binding, binding
@docs Segment, literal, variable, wildcard, doubleWildcard
@docs Body, noBody, wholeBody, bodyField
@docs Param, param

-}

import Http
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Process
import Rpc.Code as Code exposing (Code, ErrorCode)
import Rpc.Internal.Http as Internal
import Rpc.Internal.Retry as Retry
import Task exposing (Task)
import Time



-- CALLS


{-| A method applied to its request: everything needed to send it, and the
per-call adjustments made to it. Generated code builds one per method:

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note

-}
type Call req res
    = Call
        { descriptor : MethodDescriptor req res
        , message : req
        , binding : Int
        , headers : List ( String, String )
        , timeout : Maybe Float
        , tracker : Maybe String
        }


{-| What generated code says about a method:

  - `service`: the fully-qualified service name, such as `notes.v1.Notes`.
  - `method`: the method name as declared, such as `GetNote`.
  - `idempotent`: whether the proto declares
    `idempotency_level = NO_SIDE_EFFECTS`, which lets Connect send it as a GET
    and a [`Retry`](#Retry) policy retry it.
  - `encodeJson` and `jsonDecoder`: the proto3 JSON codecs of the request and
    the response.
  - `bindings`: its `google.api.http` rule, the rule's own binding first and
    then its `additional_bindings` in order; `[]` for a method without one.

-}
type alias MethodDescriptor req res =
    { service : String
    , method : String
    , idempotent : Bool
    , encodeJson : req -> Value
    , jsonDecoder : Decoder res
    , bindings : List Binding
    }


{-| A call of a method with a request, without any adjustment.
-}
call : MethodDescriptor req res -> req -> Call req res
call methodDescriptor message =
    Call
        { descriptor = methodDescriptor
        , message = message
        , binding = 0
        , headers = []
        , timeout = Nothing
        , tracker = Nothing
        }



-- ADJUSTING A CALL


{-| Headers to send with this call, after the config's.
-}
withHeaders : List ( String, String ) -> Call req res -> Call req res
withHeaders extra (Call c) =
    Call { c | headers = c.headers ++ extra }


{-| A timeout for this call in milliseconds, in place of the config's.
-}
withTimeout : Float -> Call req res -> Call req res
withTimeout ms (Call c) =
    Call { c | timeout = Just ms }


{-| A tracker for this call, so `Http.cancel` can cancel it. elm/http tracks
commands only, so only [`send`](#send) without a [`Retry`](#Retry) policy uses
it; the other ways of sending ignore it.
-}
withTracker : String -> Call req res -> Call req res
withTracker tracker (Call c) =
    Call { c | tracker = Just tracker }


{-| The call over another of its method's HTTP bindings, for transcoding: `0`
is the rule's own, which a call takes unless told otherwise, and `1` and up
its `additional_bindings` in order. `Nothing` when the method has no binding
of that number; a method without a rule has none, and its call goes over the
implicit route. Connect has no use for bindings and ignores the choice.
-}
viaBinding : Int -> Call req res -> Maybe (Call req res)
viaBinding index (Call c) =
    if index >= 0 && index < List.length c.descriptor.bindings then
        Just (Call { c | binding = index })

    else
        Nothing



-- READING A CALL


{-| The method the call is of.
-}
descriptor : Call req res -> MethodDescriptor req res
descriptor (Call c) =
    c.descriptor


{-| The fully-qualified service name, such as `notes.v1.Notes`.
-}
service : Call req res -> String
service (Call c) =
    c.descriptor.service


{-| The method name as declared, such as `GetNote`.
-}
method : Call req res -> String
method (Call c) =
    c.descriptor.method


{-| Whether the method has no side effects.
-}
idempotent : Call req res -> Bool
idempotent (Call c) =
    c.descriptor.idempotent


{-| The request the call sends.
-}
requestMessage : Call req res -> req
requestMessage (Call c) =
    c.message


{-| The request's proto3 JSON.
-}
requestJson : Call req res -> Value
requestJson (Call c) =
    c.descriptor.encodeJson c.message


{-| The call as JSON, `{"service": …, "method": …, "request": …}`, for logs,
deduplication keys or a queue of calls to send later. Per-call adjustments are
not included.
-}
toJson : Call req res -> Value
toJson (Call c) =
    Json.Encode.object
        [ ( "service", Json.Encode.string c.descriptor.service )
        , ( "method", Json.Encode.string c.descriptor.method )
        , ( "request", c.descriptor.encodeJson c.message )
        ]



-- CONFIG


{-| Where and how to send calls. It is plain data, with no functions in it, so
it can be stored in a model, compared, and built per call from an
application's state with record syntax.

  - `transport`: the protocol, with its own options.
  - `baseUrl`: the server, with any routing prefix (`https://api.example.com`,
    `/api`). A trailing `/` is dropped.
  - `headers`: sent with every call, such as `( "Authorization", "Bearer …" )`.
  - `timeout`: milliseconds. Connect also tells the server, in
    `Connect-Timeout-Ms`.
  - `withCredentials`: send cookies and other credentials cross-origin
    (`Http.riskyRequest`).
  - `retry`: whether and when to try a failed call again.

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
    { transport = connect
    , baseUrl = baseUrl
    , headers = []
    , timeout = Nothing
    , withCredentials = False
    , retry = Nothing
    }


{-| The protocol calls are sent over.

  - `Connect`: the Connect protocol. With `useGet`, an idempotent call is a GET
    with the request in the query, which caches can serve; with `maxGetUrl`, a
    GET whose URL would be longer than that many characters is POSTed instead.

-}
type Transport
    = Connect { useGet : Bool, maxGetUrl : Maybe Int }


{-| Connect with every call POSTed, as connect-es does by default.
-}
connect : Transport
connect =
    Connect { useGet = False, maxGetUrl = Nothing }


{-| When to try a call again: when an attempt fails with an [`Rpc`](#Error)
error whose code is one of `codes`, up to `attempts` tries in all, waiting
`backoff` milliseconds before the second and twice as long before each one
after. With `idempotentOnly`, only idempotent calls are retried. A transport
error is never retried.
-}
type alias Retry =
    { attempts : Int
    , backoff : Float
    , codes : List ErrorCode
    , idempotentOnly : Bool
    }



-- SENDING


{-| Send a call.
-}
task : Config -> Call req res -> Task Error res
task cfg c =
    taskFromRequest cfg c (request cfg c)


{-| Send a call, giving the result to `toMsg`.
-}
send : Config -> Call req res -> (Result Error res -> msg) -> Cmd msg
send cfg ((Call fields) as c) toMsg =
    case cfg.retry of
        Nothing ->
            Internal.send (response cfg c) toMsg fields.tracker (request cfg c)

        Just _ ->
            Task.attempt toMsg (task cfg c)



-- TRACING


{-| What happened when a call was sent, for logs and metrics:

  - `service` and `method`: the call's.
  - `binding`: the HTTP binding used, or `Nothing` when there was none to use.
  - `request`: the request sent.
  - `httpStatus`: the HTTP status of the last answer, `Nothing` when there was
    none (a timeout, a network failure).
  - `code`: how the call ended: `Just Ok` when it succeeded,
    `Just (Failed code)` when it failed with an [`Rpc`](#Error) error, and
    `Nothing` when it failed with a [`Transport`](#Error) error.
  - `duration`: milliseconds from before the first attempt to after the last.
  - `attempts`: how many times it was sent, retries included.

-}
type alias Trace =
    { service : String
    , method : String
    , binding : Maybe Int
    , request : Request
    , httpStatus : Maybe Int
    , code : Maybe Code
    , duration : Float
    , attempts : Int
    }


{-| Send a call, and say what happened along with the result.
-}
taskTraced : Config -> Call req res -> Task Never ( Trace, Result Error res )
taskTraced cfg ((Call fields) as c) =
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
                                        ( { service = fields.descriptor.service
                                          , method = fields.descriptor.method
                                          , binding = Nothing
                                          , request = sent
                                          , httpStatus = outcome.status
                                          , code = outcomeCode outcome.result
                                          , duration = toFloat (Time.posixToMillis end - Time.posixToMillis start)
                                          , attempts = outcome.attempts
                                          }
                                        , outcome.result
                                        )
                                    )
                        )
            )


outcomeCode : Result Error res -> Maybe Code
outcomeCode result =
    case result of
        Ok _ ->
            Just Code.Ok

        Err (Rpc rpc) ->
            Just (Code.Failed rpc.code)

        Err (Transport _) ->
            Nothing


{-| Send a call, giving what happened and the result to `toMsg`.
-}
sendTraced : Config -> Call req res -> (Trace -> Result Error res -> msg) -> Cmd msg
sendTraced cfg c toMsg =
    Task.perform (\( trace, result ) -> toMsg trace result) (taskTraced cfg c)



-- ERRORS


{-| Why a call failed.

  - `Rpc`: the server answered with an error: its code, its message, its
    details as the JSON received (`{"type": …, "value": …}`), and where in the
    answer they were found. The code is an
    [`ErrorCode`](Rpc-Code#ErrorCode), never `Ok`: an answer claiming `ok`
    while failing reads as `Unknown`.
  - `Transport`: no answer to read: a bad URL, a timeout, a network failure, or
    a successful answer whose body does not decode (`Http.BadBody`).

-}
type Error
    = Rpc { code : ErrorCode, message : String, details : List Value, source : Source }
    | Transport Http.Error


{-| Where an `Rpc` error was read from.

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`.
  - `HttpStatus`: none of the above; the code is inferred from this HTTP status
    ([`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus)), the message is the
    status text (`HTTP <status>` when there is none), and there are no
    details.

-}
type Source
    = ConnectBody
    | HttpStatus Int


{-| A one-line description of an error, for logs.
-}
errorToString : Error -> String
errorToString error =
    case error of
        Rpc rpc ->
            Code.toString rpc.code
                ++ (if String.isEmpty rpc.message then
                        ""

                    else
                        ": " ++ rpc.message
                   )

        Transport Http.Timeout ->
            "timeout"

        Transport Http.NetworkError ->
            "network error"

        Transport (Http.BadUrl url) ->
            "bad URL: " ++ url

        Transport (Http.BadStatus status) ->
            "HTTP " ++ String.fromInt status

        Transport (Http.BadBody problem) ->
            "bad response body: " ++ problem



-- REQUESTS AND RESPONSES


{-| An HTTP request, ready to send.

elm/http has no request value of its own: `Http.request` takes a record with
opaque headers and body and an `expect`. `Request` is the data form of that
record without `expect` and `tracker`: headers as pairs, the body as the JSON
string, and `withCredentials` deciding whether the runtime calls
`Http.request` or `Http.riskyRequest`.

A body is sent as `application/json`, and `timeout` is in milliseconds.

-}
type alias Request =
    { method : String
    , url : String
    , headers : List ( String, String )
    , body : Maybe String
    , timeout : Maybe Float
    , withCredentials : Bool
    }


{-| The request a call sends.

Over Connect, a POST goes to `baseUrl/service/method` with the request's JSON
as its body and `Connect-Protocol-Version: 1`. With `useGet`, an idempotent
call is a GET of the same URL with the query
`connect=v1&encoding=json&message=…`, the JSON percent-encoded, unless the URL
would be longer than `maxGetUrl`. A timeout is sent as `Connect-Timeout-Ms`,
rounded up to a whole millisecond. The config's headers come first, then the
call's.

-}
request : Config -> Call req res -> Request
request cfg c =
    case cfg.transport of
        Connect options ->
            connectRequest options cfg c


connectRequest : { useGet : Bool, maxGetUrl : Maybe Int } -> Config -> Call req res -> Request
connectRequest options cfg ((Call fields) as c) =
    let
        url =
            trimSlash cfg.baseUrl ++ "/" ++ fields.descriptor.service ++ "/" ++ fields.descriptor.method

        json =
            Json.Encode.encode 0 (requestJson c)

        timeout =
            callTimeout cfg c

        timeoutHeader =
            case timeout of
                Just ms ->
                    [ ( "Connect-Timeout-Ms", timeoutMs ms ) ]

                Nothing ->
                    []

        getUrl =
            url
                ++ "?connect=v1&encoding=json&message="
                ++ Internal.percentEncode Internal.unreserved json

        fits =
            case options.maxGetUrl of
                Just limit ->
                    String.length getUrl <= limit

                Nothing ->
                    True
    in
    if options.useGet && fields.descriptor.idempotent && fits then
        { method = "GET"
        , url = getUrl
        , headers = cfg.headers ++ fields.headers ++ timeoutHeader
        , body = Nothing
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }

    else
        { method = "POST"
        , url = url
        , headers = cfg.headers ++ fields.headers ++ ( "Connect-Protocol-Version", "1" ) :: timeoutHeader
        , body = Just json
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }


callTimeout : Config -> Call req res -> Maybe Float
callTimeout cfg (Call fields) =
    case fields.timeout of
        Just ms ->
            Just ms

        Nothing ->
            cfg.timeout


trimSlash : String -> String
trimSlash url =
    if String.endsWith "/" url then
        String.dropRight 1 url

    else
        url


{-| A positive whole number of milliseconds, at most ten digits, as the
protocol requires.
-}
timeoutMs : Float -> String
timeoutMs ms =
    String.fromInt (clamp 1 9999999999 (ceiling ms))


{-| What an answer to a call means: the decoded response, or the error.

Over Connect, success is status 200. Any other answer is an error, read as
[`Source`](#Source) describes.

-}
response : Config -> Call req res -> Http.Response String -> Result Error res
response cfg (Call fields) answer =
    case cfg.transport of
        Connect _ ->
            case answer of
                Http.GoodStatus_ metadata raw ->
                    if metadata.statusCode == 200 then
                        decodeBody fields.descriptor.jsonDecoder raw

                    else
                        Err (failure metadata raw)

                Http.BadStatus_ metadata raw ->
                    Err (failure metadata raw)

                Http.BadUrl_ url ->
                    Err (Transport (Http.BadUrl url))

                Http.Timeout_ ->
                    Err (Transport Http.Timeout)

                Http.NetworkError_ ->
                    Err (Transport Http.NetworkError)


decodeBody : Decoder res -> String -> Result Error res
decodeBody decoder raw =
    Json.Decode.decodeString decoder raw
        |> Result.mapError (Json.Decode.errorToString >> Http.BadBody >> Transport)


{-| Send a request in place of the one a call would send, and read the answer as
the call's. The config's retry policy applies.
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


type alias Outcome res =
    { attempts : Int
    , status : Maybe Int
    , result : Result Error res
    }


{-| Send `sent` until it succeeds or the retry policy says to stop.
-}
attempt : Config -> Call req res -> Request -> Task Never (Outcome res)
attempt cfg c sent =
    let
        once =
            Internal.task (\answer -> Ok ( statusOf answer, response cfg c answer )) sent

        loop tried =
            once
                |> Task.andThen
                    (\( status, result ) ->
                        case retryDelay cfg c tried result of
                            Just wait ->
                                Process.sleep wait
                                    |> Task.andThen (\_ -> loop (tried + 1))

                            Nothing ->
                                Task.succeed { attempts = tried, status = status, result = result }
                    )
    in
    loop 1


retryDelay : Config -> Call req res -> Int -> Result Error res -> Maybe Float
retryDelay cfg (Call fields) tried result =
    case ( cfg.retry, result ) of
        ( Just policy, Err (Rpc rpc) ) ->
            Retry.delay policy fields.descriptor.idempotent tried (Just rpc.code)

        _ ->
            Nothing


statusOf : Http.Response String -> Maybe Int
statusOf answer =
    case answer of
        Http.GoodStatus_ metadata _ ->
            Just metadata.statusCode

        Http.BadStatus_ metadata _ ->
            Just metadata.statusCode

        _ ->
            Nothing


{-| The error a failed answer stands for: its Connect error body, or failing
that, its HTTP status.
-}
failure : Http.Metadata -> String -> Error
failure metadata raw =
    case Json.Decode.decodeString connectBody raw of
        Ok rpc ->
            Rpc rpc

        Err _ ->
            Rpc
                { code = Code.fromHttpStatus metadata.statusCode
                , message =
                    if String.isEmpty metadata.statusText then
                        "HTTP " ++ String.fromInt metadata.statusCode

                    else
                        metadata.statusText
                , details = []
                , source = HttpStatus metadata.statusCode
                }


{-| A Connect error body: a `code` the protocol names (an unknown name reads as
`unknown`), an optional `message` and optional `details`.
-}
connectBody : Decoder { code : ErrorCode, message : String, details : List Value, source : Source }
connectBody =
    Json.Decode.map3 (\code message details -> { code = code, message = message, details = details, source = ConnectBody })
        (Json.Decode.field "code" Json.Decode.string
            |> Json.Decode.map (Code.fromString >> Maybe.withDefault Code.Unknown)
        )
        (optional "message" Json.Decode.string "")
        (optional "details" (Json.Decode.list Json.Decode.value) [])


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]



-- HTTP BINDINGS


{-| One binding of a method's `google.api.http` rule.
-}
type Binding
    = Binding
        { method : String
        , path : List Segment
        , customVerb : Maybe String
        , body : Body
        , responseBody : Maybe String
        , query : List Param
        }


{-| A binding, as the generator parses it:

  - `method`: the HTTP method, such as `"GET"`.
  - `path`: the path template's segments.
  - `customVerb`: the text after `:` at the end of the template, if any.
  - `body`: what the request body holds.
  - `responseBody`: the JSON name of the response field the answer holds, if it
    is not the whole response.
  - `query`: the query parameters, every request field outside the path and the
    body.

-}
binding :
    { method : String
    , path : List Segment
    , customVerb : Maybe String
    , body : Body
    , responseBody : Maybe String
    , query : List Param
    }
    -> Binding
binding =
    Binding


{-| One segment of a path template.
-}
type Segment
    = Literal String
    | Wildcard
    | DoubleWildcard
    | Variable (List String) (List Segment)


{-| Literal text, written as it is.
-}
literal : String -> Segment
literal =
    Literal


{-| A request field's value: the field's JSON path (`[ "book", "name" ]`), and
the variable's template (`[ literal "books", wildcard ]` for
`{book.name=books/*}`; `[]` for `{name}`). A variable matching one segment
(`{name}`, `{name=*}`) is percent-encoded with `/` escaped as `%2F`; any other
keeps its `/`s. An absent value is the empty string. The value is not checked
against the template: the server does that.
-}
variable : List String -> List Segment -> Segment
variable =
    Variable


{-| `*`, one path segment, inside a variable's template.
-}
wildcard : Segment
wildcard =
    Wildcard


{-| `**`, any number of path segments, inside a variable's template.
-}
doubleWildcard : Segment
doubleWildcard =
    DoubleWildcard


{-| What a request body holds.
-}
type Body
    = NoBody
    | WholeBody
    | BodyField String


{-| No body: every field outside the path is in the query.
-}
noBody : Body
noBody =
    NoBody


{-| `body: "*"`: the request's JSON without the fields the path holds.
-}
wholeBody : Body
wholeBody =
    WholeBody


{-| `body: "note"`: the JSON of one top-level field, by its JSON name, sent
whole even when the path holds a field inside it. An unset field is sent as
`{}`.
-}
bodyField : String -> Body
bodyField =
    BodyField


{-| One query parameter.
-}
type Param
    = Param { name : String, path : List String, zero : Maybe String }


{-| A query parameter: its name (the dotted proto field path, `sub.subfield`),
the field's JSON path (`[ "sub", "subfield" ]`), and the text of the value at
which it is left out (`Just "0"`, `Just ""`, an enum's zero name), or
`Nothing` to leave it out only when the field is unset. A JSON array is sent
as one parameter per element.
-}
param : String -> List String -> Maybe String -> Param
param name path zero =
    Param { name = name, path = path, zero = zero }
