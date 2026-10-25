module Rpc.Stream exposing
    ( StreamCall, call, withHeaders, withTimeout
    , idempotency, descriptor
    , open, cancel
    , Event(..), event, eventId
    )

{-| Server-streaming calls, read through a port by the JavaScript companion
`runtime/stream.js`: elm/http hands a program a whole body at once, so a body
read as it arrives, and the bytes of Connect's envelopes, have to live outside
Elm. Everything else is here: the request, its headers and timeout, and the
meaning of every frame and error.

The application declares two ports and wires them to the companion:

    port streamOut : Json.Encode.Value -> Cmd msg

    port streamIn : (Json.Decode.Value -> msg) -> Sub msg

    // JavaScript
    import { createStreams } from "./stream.js";
    const streams = createStreams((e) => app.ports.streamIn.send(e));
    app.ports.streamOut.subscribe((command) => streams.run(command));

Then [`open`](#open) gives what to send out, and [`event`](#event) decodes
what comes in. [`Rpc.Stream.Session`](Rpc-Stream-Session) runs a stream that
reconnects and resumes.

@docs StreamCall, call, withHeaders, withTimeout


# Reading

@docs idempotency, descriptor


# Opening and cancelling

@docs open, cancel


# Events

@docs Event, event, eventId

-}

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Proto.Method as Method
import Rpc
import Rpc.Body
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Answer as Answer
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Transport exposing (StreamFraming(..), Transport(..))
import Rpc.Internal.Wire as Wire
import Rpc.Request exposing (Request)
import Rpc.Response exposing (Response)


{-| A server-streaming method applied to its request. Opaque, like
[`Rpc.Call`](Rpc#Call), and holding functions, so compare two by their
request instead.
-}
type StreamCall req res
    = StreamCall (Call req res)


{-| The call generated code gives for a server-streaming method.
-}
call : Method.ServerStreaming req res -> req -> StreamCall req res
call m req =
    StreamCall
        (Call
            { method = Method.streamingMethod m
            , message = req
            , binding = 0
            , headers = []
            , timeout = Nothing
            , tracker = Nothing
            , retry = Rpc.Internal.Call.NoRetry
            }
        )


{-| Headers sent after the config's.
-}
withHeaders : List ( String, String ) -> StreamCall req res -> StreamCall req res
withHeaders extra (StreamCall (Call fields)) =
    StreamCall (Call { fields | headers = fields.headers ++ extra })


{-| A bound in milliseconds on the whole stream, from opening to its end,
sent over Connect as `Connect-Timeout-Ms`. A stream has none unless it is
given one: the config's `timeout` is for unary calls and does not apply.
-}
withTimeout : Float -> StreamCall req res -> StreamCall req res
withTimeout ms (StreamCall (Call fields)) =
    StreamCall (Call { fields | timeout = Just ms })


{-| The method's declared idempotency, which a reconnect policy reads.
-}
idempotency : StreamCall req res -> Method.Idempotency
idempotency (StreamCall (Call fields)) =
    Method.idempotency (Method.toDescriptor fields.method)


{-| The method's descriptor.
-}
descriptor : StreamCall req res -> Method.Descriptor
descriptor (StreamCall (Call fields)) =
    Method.toDescriptor fields.method


{-| The command to send through the application's port that opens the stream
`id`, replacing any stream open under that id: the URL, headers, body,
framing and timeout, built as [`Rpc.request`](Rpc#request) builds a unary
call's but always POSTed over Connect, with the streaming content type. The
request's JSON goes as text and the companion wraps it in Connect's envelope,
since a port carries JSON and not bytes.

A call that cannot be sent (a bad base URL, a header a browser refuses, a path
value its route cannot match, a message over the write limit) is the error
instead, as [`Rpc.send`](Rpc#send) would fail it, nothing sent.

-}
open : Rpc.Config -> { id : String, call : StreamCall req res } -> Result Error Encode.Value
open cfg opening =
    let
        id =
            opening.id

        (StreamCall ((Call fields) as c)) =
            opening.call

        settings =
            { transport = postOnly cfg.transport
            , baseUrl = cfg.baseUrl
            , headers = cfg.headers
            , timeout = Nothing
            , withCredentials = cfg.withCredentials
            }

        framing =
            case cfg.transport of
                Transcode options ->
                    framingName options.streamFraming

                Connect _ ->
                    "connect"

        built =
            if framing == "connect" then
                Wire.request { settings | transport = Connect { get = False, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing } } c

            else
                Wire.request settings c |> plainJson

        contentType =
            if framing == "connect" then
                [ ( "Content-Type", "application/connect+json" ) ]

            else if Rpc.Body.toText built.body == Nothing then
                []

            else
                [ ( "Content-Type", "application/json" ) ]

        headers =
            built.headers ++ contentType

        json =
            Encode.encode 0 (Method.encodeRequest fields.method fields.message)
    in
    if Internal.badBaseUrl cfg.baseUrl then
        Err (Error.NoAnswer (Error.BadUrl built.url))

    else
        case ( Wire.invalidPathValue settings c, Internal.invalidHeader headers ) of
            ( Just path, _ ) ->
                Err (Error.NoAnswer (Error.InvalidPathValue path))

            ( Nothing, Just name ) ->
                Err (Error.NoAnswer (Error.InvalidHeader name))

            ( Nothing, Nothing ) ->
                case Internal.requestTooLarge cfg.transport json of
                    Just reason ->
                        Err (Error.NoAnswer reason)

                    Nothing ->
                        Ok
                            (Encode.object
                                [ ( "id", Encode.string id )
                                , ( "open"
                                  , Encode.object
                                        [ ( "url", Encode.string built.url )
                                        , ( "method", Encode.string built.method )
                                        , ( "headers", Encode.list (\( k, v ) -> Encode.list Encode.string [ k, v ]) headers )
                                        , ( "body"
                                          , case Rpc.Body.toText built.body of
                                                Just text ->
                                                    Encode.string text

                                                Nothing ->
                                                    Encode.null
                                          )
                                        , ( "framing", Encode.string framing )
                                        , ( "timeoutMs"
                                          , case built.timeout of
                                                Just ms ->
                                                    Encode.float ms

                                                Nothing ->
                                                    Encode.null
                                          )
                                        , ( "withCredentials", Encode.bool built.withCredentials )
                                        ]
                                  )
                                ]
                            )


postOnly : Transport -> Transport
postOnly transport =
    case transport of
        Connect options ->
            Connect { options | get = False }

        Transcode _ ->
            transport


{-| A transcoder's implicit route is a plain JSON POST: the Connect headers
the unary implicit route carries mean nothing to it (the companion enforces
the timeout).
-}
plainJson : Request -> Request
plainJson built =
    { built
        | headers =
            List.filter
                (\( name, _ ) -> not (List.member (String.toLower name) [ "connect-protocol-version", "connect-timeout-ms" ]))
                built.headers
    }


framingName : StreamFraming -> String
framingName framing =
    case framing of
        GatewayNdjson ->
            "ndjson"

        EnvoyArray ->
            "array"

        EnvoyNdjson ->
            "ndjson-bare"

        EnvoySse ->
            "sse"

        ConnectEnvelope ->
            "connect"


{-| The command that cancels the stream `id`. Nothing more arrives for it, not
even an end: the application knows it cancelled.
-}
cancel : String -> Encode.Value
cancel id =
    Encode.object [ ( "cancel", Encode.string id ) ]


{-| What happens on a stream:

  - `Opened`: the response's status and headers arrived. Over Connect a stream
    that opens with a status other than 200 never reached a Connect server;
    a `Failed` follows.
  - `Message`: one message, decoded.
  - `Ended`: the stream ended cleanly, with its trailers (Connect's
    end-of-stream metadata; empty over transcoding).
  - `Failed`: it ended with an error. A Connect end-of-stream error is an
    `RpcStatus` whose source is `ConnectEndStream`, its details readable with
    [`Rpc.Error.details`](Rpc-Error#details); a transcoder's error is a
    `StatusBody` status; a lost connection is `NoAnswer NetworkError`, and the
    stream's timeout `NoAnswer Timeout`.

Nothing follows `Ended` or `Failed`.

-}
type Event res
    = Opened { status : Int, headers : Dict String String }
    | Message res
    | Ended { trailers : Dict String (List String) }
    | Failed Error


{-| The stream an incoming event belongs to, the `id` it was opened with.
-}
eventId : Decoder String
eventId =
    Decode.field "id" Decode.string


{-| An incoming event of a stream of this call's method.
-}
event : StreamCall req res -> Decoder (Event res)
event (StreamCall (Call fields)) =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "headers" ->
                        Decode.map2 (\status headers -> Opened { status = status, headers = headers })
                            (Decode.field "status" Decode.int)
                            (Decode.field "headers" (Decode.dict Decode.string))

                    "message" ->
                        Decode.field "json" Decode.string
                            |> Decode.map
                                (\json ->
                                    case Decode.decodeString (Method.responseDecoder fields.method) json of
                                        Ok res ->
                                            Message res

                                        Err problem ->
                                            Failed (Error.BadResponse (Decode.errorToString problem) (answer 200 json))
                                )

                    "end" ->
                        Decode.map4 ended
                            (Decode.field "status" Decode.int)
                            (Decode.field "error" (Decode.nullable Decode.value))
                            (Decode.oneOf [ Decode.field "metadata" (Decode.dict (Decode.list Decode.string)), Decode.succeed Dict.empty ])
                            (Decode.oneOf [ Decode.field "body" Decode.string, Decode.succeed "" ])

                    "error" ->
                        Decode.map2 failure
                            (Decode.field "reason" Decode.string)
                            (Decode.oneOf [ Decode.field "message" Decode.string, Decode.succeed "" ])

                    _ ->
                        Decode.fail ("an event of kind " ++ kind)
            )


ended : Int -> Maybe Decode.Value -> Dict String (List String) -> String -> Event res
ended status error trailers body =
    let
        response =
            answer status body
    in
    case error of
        Nothing ->
            if status == 200 then
                Ended { trailers = trailers }

            else
                Failed (Error.HttpStatus response)

        Just value ->
            case Decode.decodeValue (Decode.oneOf [ Answer.connectBody, Answer.statusBody ]) value of
                Ok read ->
                    Failed
                        (Error.RpcStatus
                            (if read.source == Error.ConnectBody && status == 200 then
                                { read | source = Error.ConnectEndStream }

                             else
                                read
                            )
                            response
                        )

                Err _ ->
                    Failed (Error.HttpStatus response)


failure : String -> String -> Event res
failure reason message =
    case reason of
        "timeout" ->
            Failed (Error.NoAnswer Error.Timeout)

        "network" ->
            Failed (Error.NoAnswer Error.NetworkError)

        "truncated" ->
            Failed (Error.NoAnswer Error.NetworkError)

        _ ->
            Failed (Error.BadResponse (reason ++ ": " ++ message) (answer 200 ""))


{-| The answer an error keeps. The companion does not send the URL or the
headers again with every frame; `Opened` carried them.
-}
answer : Int -> String -> Response
answer status body =
    { url = ""
    , statusCode = status
    , statusText = ""
    , headers = Dict.empty
    , body = Rpc.Body.text body
    }
