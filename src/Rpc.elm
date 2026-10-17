module Rpc exposing
    ( Call, call
    , Config, config, checkConfig
    , task, send, cancel
    , taskTraced, sendTraced
    , Error(..), Source(..), Response, code, message, errorToString, details
    , Request, request, response, taskFromRequest, splitTrailers
    )

{-| Call RPCs: unary and JSON-encoded, over the
[Connect protocol](https://connectrpc.com/docs/protocol/) as connect-go,
connect-es, connect-python and Envoy's Connect filter serve it, or over HTTP
transcoding, the REST mapping `google.api.http` rules describe, as
grpc-gateway, Envoy's gRPC-JSON transcoder and Vanguard serve it.

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

@docs Error, Source, Response, code, message, errorToString, details


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
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Process
import Proto.Any exposing (Any)
import Proto.Internal.Any
import Proto.Internal.Binding exposing (Binding(..), Body(..), Param(..), Rule, Segment(..))
import Proto.Message exposing (Message)
import Proto.Method as Method exposing (Idempotency(..), Method)
import Rpc.Body as Body exposing (Body)
import Rpc.Call
import Rpc.Code as Code exposing (Code)
import Rpc.Internal.Call
import Rpc.Internal.Http as Internal
import Rpc.Internal.Retry
import Rpc.Internal.Trace
import Rpc.Internal.Transport
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
    `#` is not sent, and fails with `Transport (Http.BadUrl url)`.
    [`checkConfig`](#checkConfig) finds that where the config is built.
  - `headers`: sent with every call, such as `( "Authorization", "Bearer …" )`.
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

Today it finds a `baseUrl` holding a query or a fragment. A call sent with
such a config still fails with `Transport (Http.BadUrl url)`; this finds it
before any call is made. Later releases may find more, so the result is
read as a list rather than matched.

-}
checkConfig : Config -> List String
checkConfig cfg =
    if badBaseUrl cfg then
        [ "baseUrl " ++ cfg.baseUrl ++ " holds a query or a fragment (? or #), after which a call's path cannot go" ]

    else
        []



-- SENDING


{-| Send a call.
-}
task : Config -> Call req res -> Task Error res
task cfg c =
    taskFromRequest cfg c (request cfg c)


{-| Send a call, giving the result to `toMsg`.
-}
send : Config -> Call req res -> (Result Error res -> msg) -> Cmd msg
send cfg ((Rpc.Internal.Call.Call fields) as c) toMsg =
    if cfg.retry == Nothing && not (badBaseUrl cfg) then
        Internal.send (response cfg c) toMsg fields.tracker (request cfg c)

    else
        Task.attempt toMsg (task cfg c)


{-| Cancel a call sent with [`send`](#send) through a tracker
([`Rpc.Call.withTracker`](Rpc-Call#withTracker)), and report it as
[`Canceled`](#Error) to the same `toMsg` the call was sent with.

    Rpc.cancel "note-42" GotNote

elm/http cancels a request by stopping the process that runs it, which aborts
the request and delivers nothing, so the outcome is reported here instead.
Once the request is aborted no result can follow, so the application sees the
call end exactly once, except in one race: when the answer arrived and its
message was queued before this command ran, the application sees the result
and then the cancellation, and a cancellation that follows a result is to be
ignored.

Cancellation with an outcome is for `send` alone, and for a request an
application sends itself from [`request`](#request) with the tracker on its
`Http.request`. A call sent with a [`Retry`](Rpc-Retry#Retry) policy has no tracker,
so it is not aborted: it runs on, and its result follows the cancellation.
The tasks, [`task`](#task) and [`taskTraced`](#taskTraced) under
[`sendTraced`](#sendTraced), ignore the tracker; one run under
`Process.spawn` and stopped with `Process.kill` reports nothing, and has no
trace, since its attempts and duration end with the process.

-}
cancel : String -> (Result Error res -> msg) -> Cmd msg
cancel tracker toMsg =
    Cmd.batch
        [ Http.cancel tracker
        , Task.perform toMsg (Task.succeed (Err Canceled))
        ]



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
                                        let
                                            metadata =
                                                outcome.metadata
                                                    |> Maybe.map (.headers >> splitTrailers)
                                                    |> Maybe.withDefault { headers = Dict.empty, trailers = Dict.empty }
                                        in
                                        ( Rpc.Internal.Trace.Trace
                                            { serviceName = Rpc.Call.serviceName c
                                            , methodName = Rpc.Call.methodName c
                                            , transport = Rpc.Transport.name cfg.transport
                                            , binding =
                                                case route cfg c of
                                                    Bound index _ ->
                                                        Just index

                                                    _ ->
                                                        Nothing
                                            , request = sent
                                            , httpStatus = Maybe.map .statusCode outcome.metadata
                                            , headers = metadata.headers
                                            , trailers = metadata.trailers
                                            , code =
                                                case outcome.result of
                                                    Ok _ ->
                                                        Nothing

                                                    Err error ->
                                                        Just (code error)
                                            , duration = toFloat (Time.posixToMillis end - Time.posixToMillis start)
                                            , attempts = outcome.attempts
                                            }
                                        , outcome.result
                                        )
                                    )
                        )
            )


{-| Send a call, giving what happened and the result to `toMsg`.
-}
sendTraced : Config -> Call req res -> (Trace -> Result Error res -> msg) -> Cmd msg
sendTraced cfg c toMsg =
    Task.perform (\( trace, result ) -> toMsg trace result) (taskTraced cfg c)



-- ERRORS


{-| Why a call failed.

  - `Status`: the server answered with a status, in a Connect error body, a
    `google.rpc.Status` body or the `grpc-status` headers: its code, its
    message, its details, and where it was found ([`Source`](#Source)), with
    the answer itself. Each detail is a message packed in an
    [`Any`](Proto-Any#Any), read with [`details`](#details) or
    [`Proto.Any.unpack`](Proto-Any#unpack). The code is a
    [`Code`](Rpc-Code#Code), which has no `ok`: an answer claiming `ok` while
    failing reads as `Unknown`.
  - `Http`: the server answered, but stated no status; [`code`](#code) infers
    one from the HTTP status.
  - `Transport`: no answer to read: a bad URL, a timeout, a network failure, or
    a successful answer whose body does not decode (`Http.BadBody`).
  - `Canceled`: the application withdrew the call with [`cancel`](#cancel);
    nothing the server said counts.

Most code asks for the [`code`](#code) and [`message`](#message), which every
error has:

    case Rpc.code error of
        Unauthenticated ->
            signInAgain

        _ ->
            showMessage (Rpc.message error)

The [`Response`](#Response) is kept whichever way the server answered, so an
error in a shape the runtime does not read can still be:

    case error of
        Http response ->
            myDecoder response.body

        _ ->
            Err (Rpc.errorToString error)

-}
type Error
    = Status { code : Code, message : String, details : List Any, source : Source } Response
    | Http Response
    | Transport Http.Error
    | Canceled


{-| Where a `Status` error was read from, tried in this order:

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`.
  - `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as grpc-gateway
    and Envoy send; a number outside `1` to `16` is the code `Unknown`, and the
    number as sent is in the response's body.
  - `GrpcHeaders`: the `grpc-status` and `grpc-message` headers, when the
    browser exposes them; the message is percent-decoded, and the status text
    stands in when there is none.

An answer with none of these is an `Http` error.

-}
type Source
    = ConnectBody
    | StatusBody
    | GrpcHeaders


{-| An answer as it arrived, its URL, status, status text, headers and body:
[`Rpc.Response.Response`](Rpc-Response#Response).
-}
type alias Response =
    Rpc.Response.Response


{-| An error's code. A `Status` error has the server's; an `Http` error's is
inferred from its HTTP status by
[`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus); a `Transport`
error's is the one the Connect clients give it: a timeout is
`DeadlineExceeded`, a network failure `Unavailable`, a bad URL or an
undecodable body `Internal`; `Canceled` is `Canceled`.
-}
code : Error -> Code
code error =
    case error of
        Status status _ ->
            status.code

        Http answer ->
            Code.fromHttpStatus answer.statusCode

        Transport Http.Timeout ->
            Code.DeadlineExceeded

        Transport Http.NetworkError ->
            Code.Unavailable

        Transport (Http.BadUrl _) ->
            Code.Internal

        Transport (Http.BadBody _) ->
            Code.Internal

        Transport (Http.BadStatus status) ->
            Code.fromHttpStatus status

        Canceled ->
            Code.Canceled


{-| An error's message: a `Status` error's as the server sent it, which may be
empty; an `Http` error's status text, or `HTTP <status>` when there is none;
a `Transport` error's description (`timeout`, `network error`,
`bad URL: <url>`, `bad response body: <problem>`); `Canceled`'s is empty, so
[`errorToString`](#errorToString) gives `canceled`.

A body that does not decode is quoted in its problem, so the problem can be as
long as the response and hold data the application never shows; the message
keeps its first 300 characters, then `…`. The whole problem stays in the
error, `Transport (Http.BadBody problem)`.

-}
message : Error -> String
message error =
    case error of
        Status status _ ->
            status.message

        Http answer ->
            if String.isEmpty answer.statusText then
                "HTTP " ++ String.fromInt answer.statusCode

            else
                answer.statusText

        Transport Http.Timeout ->
            "timeout"

        Transport Http.NetworkError ->
            "network error"

        Transport (Http.BadUrl url) ->
            "bad URL: " ++ url

        Transport (Http.BadStatus status) ->
            "HTTP " ++ String.fromInt status

        Transport (Http.BadBody problem) ->
            "bad response body: " ++ excerpt problem

        Canceled ->
            ""


{-| The first 300 characters of a text, and `…` when there were more.
-}
excerpt : String -> String
excerpt text =
    if String.length text > 300 then
        String.left 300 text ++ "…"

    else
        text


{-| A one-line description of an error, for logs: its [`code`](#code) and
[`message`](#message), `not_found: no such note`, or the code alone when the
message is empty.
-}
errorToString : Error -> String
errorToString error =
    let
        text =
            message error
    in
    Code.toString (code error)
        ++ (if String.isEmpty text then
                ""

            else
                ": " ++ text
           )


{-| The details of an error that are of this message type, in the order the
server sent them, leaving out any that do not decode. Only a `Status` error
has any.

    case Rpc.details Google.Rpc.messageBadRequest error of
        badRequest :: _ ->
            showViolations badRequest.fieldViolations

        [] ->
            showMessage (Rpc.message error)

-}
details : Message a -> Error -> List a
details proto error =
    case error of
        Status status _ ->
            List.filterMap (Proto.Any.unpack proto >> Maybe.andThen Result.toMaybe) status.details

        _ ->
            []



-- REQUESTS AND RESPONSES


{-| An HTTP request, ready to send: the data form of the record
`Http.request` takes, [`Rpc.Request.Request`](Rpc-Request#Request).
-}
type alias Request =
    Rpc.Request.Request


{-| The request a call sends.

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
variable matching several segments, but `/` too. A call without bindings is
the request Connect would POST.

-}
request : Config -> Call req res -> Request
request cfg c =
    case cfg.transport of
        Rpc.Internal.Transport.Connect options ->
            connectRequest options cfg c

        Rpc.Internal.Transport.Transcode ->
            case route cfg c of
                Bound _ rule ->
                    transcodeRequest rule cfg c

                Implicit ->
                    connectRequest { get = False, maxGetUrl = Nothing } cfg c


{-| How a call is sent: over a binding of its rule (by number), or over the
implicit route of a method without a rule.
-}
type Route
    = Bound Int Rule
    | Implicit


route : Config -> Call req res -> Route
route cfg (Rpc.Internal.Call.Call fields) =
    case cfg.transport of
        Rpc.Internal.Transport.Connect _ ->
            Implicit

        Rpc.Internal.Transport.Transcode ->
            -- A call's binding number is one its descriptor has (`viaBinding`
            -- checks), or 0 for a method without bindings.
            case List.head (List.drop fields.binding (Method.bindings (Method.toDescriptor fields.method))) of
                Just (Binding rule) ->
                    Bound fields.binding rule

                Nothing ->
                    Implicit


connectRequest : { get : Bool, maxGetUrl : Maybe Int } -> Config -> Call req res -> Request
connectRequest options cfg ((Rpc.Internal.Call.Call fields) as c) =
    let
        url =
            trimSlash cfg.baseUrl ++ "/" ++ Rpc.Call.serviceName c ++ "/" ++ Rpc.Call.methodName c

        json =
            Json.Encode.encode 0 (Rpc.Call.requestJson c)

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
    if options.get && Method.idempotency (Method.toDescriptor fields.method) == IdempotencyNoSideEffects && fits then
        { method = "GET"
        , url = getUrl
        , headers = cfg.headers ++ fields.headers ++ timeoutHeader
        , body = Body.none
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }

    else
        { method = "POST"
        , url = url
        , headers = cfg.headers ++ fields.headers ++ ( "Connect-Protocol-Version", "1" ) :: timeoutHeader
        , body = Body.text json
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }


{-| The request over one binding of a method's rule.
-}
transcodeRequest : Rule -> Config -> Call req res -> Request
transcodeRequest rule cfg ((Rpc.Internal.Call.Call fields) as c) =
    let
        json =
            Rpc.Call.requestJson c

        path =
            List.map (pathSegment json) rule.path

        verb =
            Maybe.map ((++) ":") rule.customVerb |> Maybe.withDefault ""

        query =
            case List.concatMap (queryPairs json) rule.query of
                [] ->
                    ""

                pairs ->
                    "?" ++ String.join "&" pairs
    in
    { method = rule.method
    , url = trimSlash cfg.baseUrl ++ "/" ++ String.join "/" path ++ verb ++ query
    , headers = cfg.headers ++ fields.headers
    , body = bindingBody rule json
    , timeout = callTimeout cfg c
    , withCredentials = cfg.withCredentials
    }


pathSegment : Value -> Segment -> String
pathSegment json segment =
    case segment of
        Literal written ->
            written

        Variable fieldPath template zero ->
            let
                keep =
                    if single template then
                        Internal.unreserved

                    else
                        \char -> Internal.unreserved char || char == '/'
            in
            lookup fieldPath json
                |> Maybe.andThen scalarText
                |> Maybe.withDefault zero
                |> Internal.percentEncode keep

        -- Generated bindings never hold a wildcard outside a variable: no
        -- field fills it.
        Wildcard ->
            ""

        DoubleWildcard ->
            ""


single : List Segment -> Bool
single template =
    case template of
        [] ->
            True

        [ Literal _ ] ->
            True

        [ Wildcard ] ->
            True

        _ ->
            False


queryPairs : Value -> Param -> List String
queryPairs json (Param p) =
    let
        values =
            case lookup p.path json of
                Nothing ->
                    []

                Just value ->
                    case Json.Decode.decodeValue (Json.Decode.list Json.Decode.value) value of
                        Ok elements ->
                            List.filterMap scalarText elements

                        Err _ ->
                            -- Generated encoders leave a default out; JSON
                            -- from another encoder may spell it.
                            case scalarText value of
                                Just text ->
                                    if Just text == p.zero then
                                        []

                                    else
                                        [ text ]

                                Nothing ->
                                    []
    in
    List.map
        (\v -> Internal.percentEncode Internal.unreserved p.name ++ "=" ++ Internal.percentEncode Internal.unreserved v)
        values


{-| The value at a JSON path, unless absent or `null`.
-}
lookup : List String -> Value -> Maybe Value
lookup fieldPath json =
    Json.Decode.decodeValue (Json.Decode.at fieldPath (Json.Decode.nullable Json.Decode.value)) json
        |> Result.toMaybe
        |> Maybe.andThen identity


{-| A scalar JSON value as query or path text: a string as it is, a number or
a boolean as JSON writes it. `null`, objects and arrays have none.
-}
scalarText : Value -> Maybe String
scalarText value =
    Json.Decode.decodeValue
        (Json.Decode.oneOf
            [ Json.Decode.map Just Json.Decode.string
            , Json.Decode.map
                (\b ->
                    if b then
                        Just "true"

                    else
                        Just "false"
                )
                Json.Decode.bool
            , Json.Decode.map (\_ -> Just (Json.Encode.encode 0 value)) Json.Decode.float
            , Json.Decode.succeed Nothing
            ]
        )
        value
        |> Result.withDefault Nothing


bindingBody : Rule -> Value -> Body
bindingBody rule json =
    case rule.body of
        NoBody ->
            Body.none

        WholeBody ->
            Body.text (Json.Encode.encode 0 (List.foldl remove json (variables rule.path)))

        BodyField key ->
            lookup [ key ] json
                |> Maybe.withDefault (Json.Encode.object [])
                |> Json.Encode.encode 0
                |> Body.text


variables : List Segment -> List (List String)
variables =
    List.filterMap
        (\segment ->
            case segment of
                Variable fieldPath _ _ ->
                    Just fieldPath

                _ ->
                    Nothing
        )


{-| The JSON without the value at `fieldPath`; unchanged when there is none.
-}
remove : List String -> Value -> Value
remove fieldPath json =
    case fieldPath of
        [] ->
            json

        key :: rest ->
            case Json.Decode.decodeValue (Json.Decode.keyValuePairs Json.Decode.value) json of
                Ok pairs ->
                    pairs
                        |> List.filterMap
                            (\( k, v ) ->
                                if k /= key then
                                    Just ( k, v )

                                else if List.isEmpty rest then
                                    Nothing

                                else
                                    Just ( k, remove rest v )
                            )
                        |> Json.Encode.object

                Err _ ->
                    json


callTimeout : Config -> Call req res -> Maybe Float
callTimeout cfg (Rpc.Internal.Call.Call fields) =
    case usableTimeout fields.timeout of
        Just ms ->
            Just ms

        Nothing ->
            usableTimeout cfg.timeout


{-| A timeout only when it is a positive number of milliseconds. elm/http hands
the value to XHR, whose unsigned conversion turns a negative one into weeks and
NaN or `0` into none, while the header would claim 1 ms or the maximum; read as
no timeout instead, the header and the client agree.
-}
usableTimeout : Maybe Float -> Maybe Float
usableTimeout timeout =
    case timeout of
        Just ms ->
            if ms > 0 && not (isInfinite ms) then
                Just ms

            else
                Nothing

        Nothing ->
            Nothing


badBaseUrl : Config -> Bool
badBaseUrl cfg =
    Internal.badBaseUrl cfg.baseUrl


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

Over Connect, success is status 200. Over transcoding, it is any 2xx, an empty
body reading as `{}`, and the response decoded from the field the binding's
`responseBody` names when it names one. Any other answer is an error, read as
[`Source`](#Source) describes, whatever the transport.

-}
response : Config -> Call req res -> Http.Response String -> Result Error res
response cfg ((Rpc.Internal.Call.Call fields) as c) answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            case ( cfg.transport, route cfg c ) of
                ( Rpc.Internal.Transport.Connect _, _ ) ->
                    if metadata.statusCode == 200 then
                        decodeBody (Method.responseDecoder fields.method) raw

                    else
                        Err (failure metadata raw)

                ( Rpc.Internal.Transport.Transcode, Bound _ rule ) ->
                    decodeBody (responseDecoder rule.responseBody (Method.responseDecoder fields.method)) (orEmptyObject raw)

                ( Rpc.Internal.Transport.Transcode, Implicit ) ->
                    decodeBody (Method.responseDecoder fields.method) (orEmptyObject raw)

        Http.BadStatus_ metadata raw ->
            Err (failure metadata raw)

        Http.BadUrl_ url ->
            Err (Transport (Http.BadUrl url))

        Http.Timeout_ ->
            Err (Transport Http.Timeout)

        Http.NetworkError_ ->
            Err (Transport Http.NetworkError)


orEmptyObject : String -> String
orEmptyObject raw =
    if String.isEmpty (String.trim raw) then
        "{}"

    else
        raw


{-| The response decoder reading the answer as the field `responseBody` names,
when it names one.
-}
responseDecoder : Maybe String -> Decoder res -> Decoder res
responseDecoder responseBody decoder =
    case responseBody of
        Nothing ->
            decoder

        Just key ->
            Json.Decode.value
                |> Json.Decode.andThen
                    (\value ->
                        case Json.Decode.decodeValue decoder (Json.Encode.object [ ( key, value ) ]) of
                            Ok decoded ->
                                Json.Decode.succeed decoded

                            Err error ->
                                Json.Decode.fail (Json.Decode.errorToString error)
                    )


decodeBody : Decoder res -> String -> Result Error res
decodeBody decoder raw =
    Json.Decode.decodeString decoder raw
        |> Result.mapError (Json.Decode.errorToString >> Http.BadBody >> Transport)


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
    , metadata : Maybe Http.Metadata
    , result : Result Error res
    }


{-| Send `sent` until it succeeds or the retry policy says to stop.
-}
attempt : Config -> Call req res -> Request -> Task Never (Outcome res)
attempt cfg c sent =
    let
        once =
            if badBaseUrl cfg then
                Task.succeed ( Nothing, Err (Transport (Http.BadUrl sent.url)) )

            else
                Internal.task (\answer -> Ok ( Internal.metadataOf answer, response cfg c answer )) sent

        loop tried =
            once
                |> Task.andThen
                    (\( metadata, result ) ->
                        case retryDelay cfg c tried result of
                            Just ( policy, bound ) ->
                                Time.now
                                    |> Task.andThen (\now -> Process.sleep (Rpc.Internal.Retry.jitter policy (Time.posixToMillis now) tried bound))
                                    |> Task.andThen (\_ -> loop (tried + 1))

                            Nothing ->
                                Task.succeed { attempts = tried, metadata = metadata, result = result }
                    )
    in
    loop 1


{-| The config's policy and the bound on the wait before trying again, or
`Nothing` to stop.
-}
retryDelay : Config -> Call req res -> Int -> Result Error res -> Maybe ( Retry, Float )
retryDelay cfg c tried result =
    case ( cfg.retry, result ) of
        ( Just policy, Err error ) ->
            Rpc.Internal.Retry.delay policy (Rpc.Call.idempotency c) tried (code error)
                |> Maybe.map (Tuple.pair policy)

        _ ->
            Nothing


{-| The error a failed answer stands for, whatever the transport: its Connect
error body, or its `google.rpc.Status` body, or its `grpc-status` and
`grpc-message` headers, or failing all of those, an `Http` error. The answer is
kept whichever it is.
-}
failure : Http.Metadata -> String -> Error
failure metadata raw =
    let
        answer =
            { url = metadata.url
            , statusCode = metadata.statusCode
            , statusText = metadata.statusText
            , headers = metadata.headers
            , body = raw
            }
    in
    case Json.Decode.decodeString (Json.Decode.oneOf [ connectBody, statusBody ]) raw of
        Ok read ->
            Status read answer

        Err _ ->
            case header "grpc-status" metadata |> Maybe.andThen (String.trim >> String.toInt) of
                Just number ->
                    Status
                        { code = fromGrpc number
                        , message =
                            header "grpc-message" metadata
                                |> Maybe.map (\text -> Internal.percentDecode text |> Maybe.withDefault text)
                                |> Maybe.withDefault (message (Http answer))
                        , details = []
                        , source = GrpcHeaders
                        }
                        answer

                Nothing ->
                    Http answer


{-| A response header by name, whatever its case.
-}
header : String -> Http.Metadata -> Maybe String
header key metadata =
    metadata.headers
        |> Dict.toList
        |> List.filter (\( k, _ ) -> String.toLower k == key)
        |> List.head
        |> Maybe.map Tuple.second


{-| A `Status` error as read, before the answer is attached.
-}
type alias Read =
    { code : Code, message : String, details : List Any, source : Source }


fromGrpc : Int -> Code
fromGrpc number =
    Code.fromInt number |> Maybe.withDefault Code.Unknown


{-| A `google.rpc.Status` body: an integer `code`, an optional `message` and
optional `details`.
-}
statusBody : Decoder Read
statusBody =
    Json.Decode.map3 (\number text found -> { code = fromGrpc number, message = text, details = found, source = StatusBody })
        (Json.Decode.field "code" Json.Decode.int)
        (optional "message" Json.Decode.string "")
        (optional "details" detailList [])


{-| A Connect error body: a `code` the protocol names (an unknown name reads as
`unknown`), an optional `message` and optional `details`.
-}
connectBody : Decoder Read
connectBody =
    Json.Decode.map3 (\name text found -> { code = name, message = text, details = found, source = ConnectBody })
        (Json.Decode.field "code" Json.Decode.string
            |> Json.Decode.map (Code.fromString >> Maybe.withDefault Code.Unknown)
        )
        (optional "message" Json.Decode.string "")
        (optional "details" detailList [])


{-| An error's details, each in either form whichever body it came in: a
`google.rpc.Status` body holds proto3 JSON `Any` objects, a Connect body
`{"type", "value", "debug"}` objects. A detail in neither form is left out
rather than losing the error's code and message with it.
-}
detailList : Decoder (List Any)
detailList =
    Json.Decode.list (Json.Decode.maybe (Json.Decode.oneOf [ Proto.Any.jsonDecoder, connectDetail ]))
        |> Json.Decode.map (List.filterMap identity)


{-| A Connect error detail: the message's full name as `type`, its protobuf
binary as base64 `value`, and optionally its JSON as `debug`, which the `Any`
holds when present. Without it the `Any` holds the binary alone.
-}
connectDetail : Decoder Any
connectDetail =
    Json.Decode.map3
        (\name binary debug ->
            Proto.Internal.Any.Any
                (if String.contains "/" name then
                    name

                 else
                    "type.googleapis.com/" ++ name
                )
                (case debug of
                    Just json ->
                        Proto.Internal.Any.InJson json

                    Nothing ->
                        Proto.Internal.Any.InBinary binary
                )
        )
        (Json.Decode.field "type" Json.Decode.string)
        (optional "value" Json.Decode.string "")
        (optional "debug" (Json.Decode.map Just Json.Decode.value) Nothing)


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]
