module Live.Call exposing (Entry, Envelope, Outcome, Sending(..), Sent, Transport(..), entry)

{-| What the live runner sends: an envelope read from JSON, and an entry of a
dispatch table, which turns one into a sent call and its result into JSON.

A dispatch table (`Live.Notes.table`) lists one entry per method, each built by
[`entry`](#entry) from the generated call function and the codecs the runner
needs beyond it: the request's decoder, since the envelope holds the request as
proto3 JSON, and the response's encoder, since the result reports it so.

-}

import Dict
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Proto.Any
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Code
import Rpc.Error
import Rpc.Trace
import Task


{-| One call to make: the method, its request as proto3 JSON, the transport,
the config and the binding, if one is chosen, and the milliseconds after which
to cancel it, if it is to be.
-}
type alias Envelope =
    { id : String
    , service : String
    , method : String
    , request : Value
    , transport : Transport
    , config : Rpc.Config
    , binding : Maybe Int
    , sending : Sending
    , tracker : Maybe String
    , cancelAfter : Maybe Int
    }


{-| Which of the runtime's ways of sending a call to use. `Halves` sends
through the pure halves, as an application that needs the whole answer does:
`Rpc.request`, `Http.request` with the answer kept whole, and `Rpc.response`.
`Traced` gives the answer's status, headers and trailers in the trace.
-}
type Sending
    = Traced
    | Plain
    | AsTask
    | Halves


{-| The transport a call goes over, as the envelope names it.
-}
type Transport
    = Connect
    | Transcode


{-| How a dispatch table sends an envelope's call: `Err` with a reason when
the request does not decode, the binding does not exist or the call cannot be
cancelled as asked, or the commands that send it and cancel it.
-}
type alias Entry msg =
    Envelope -> (Outcome -> msg) -> Result String (Sent msg)


{-| A call's commands: `send` sends it and reports the outcome; `cancel`, for
an envelope with `cancelAfter`, cancels it with `Rpc.cancel`, which reports
nothing, and reports `{"canceled": true}` itself, as an application records
that it withdrew a call. The caller reports whichever outcome comes first.
-}
type alias Sent msg =
    { send : Cmd msg, cancel : Maybe (Cmd msg) }


{-| What became of a call, as JSON: the result, the trace when the call was
sent with `Rpc.sendTraced` (`Rpc.Trace.toJson`; `null` otherwise), and the answer's status and
headers when it was sent through the halves and an answer came (`null`
otherwise).
-}
type alias Outcome =
    { id : String, result : Value, trace : Value, response : Value }


{-| The entry for a method, from its generated call function, its request's
decoder and its response's encoder.
-}
entry : (req -> Rpc.Call req res) -> Decoder req -> (res -> Value) -> Entry msg
entry toCall requestDecoder encodeResponse envelope toMsg =
    case Decode.decodeValue requestDecoder envelope.request of
        Err problem ->
            Err ("the request does not decode: " ++ Decode.errorToString problem)

        Ok request ->
            let
                plain =
                    toCall request

                bound =
                    case envelope.binding of
                        Nothing ->
                            Ok plain

                        Just index ->
                            Rpc.Call.viaBinding index plain
                                |> Result.fromMaybe
                                    ("binding "
                                        ++ String.fromInt index
                                        ++ " is not one "
                                        ++ envelope.service
                                        ++ "/"
                                        ++ envelope.method
                                        ++ " has"
                                    )
            in
            bound |> Result.andThen (sendWith envelope encodeResponse toMsg)


{-| The commands for a call. Only a call elm/http sends under a tracker can be
aborted: one sent with `send` without a retry policy, or through the halves
with the tracker on `Http.request`. `sendTraced`, `task` and `send` with a
retry policy ignore the tracker, so a call sent so with `cancelAfter` is
refused rather than reported cancelled while it runs on. A call to be
cancelled without a tracker of its own gets its id as one.
-}
sendWith : Envelope -> (res -> Value) -> (Outcome -> msg) -> Rpc.Call req res -> Result String (Sent msg)
sendWith envelope encodeResponse toMsg c =
    let
        tracker =
            case ( envelope.tracker, envelope.cancelAfter ) of
                ( Just name, _ ) ->
                    Just name

                ( Nothing, Just _ ) ->
                    Just envelope.id

                ( Nothing, Nothing ) ->
                    Nothing

        tracked =
            case tracker of
                Just name ->
                    Rpc.Call.withTracker name c

                Nothing ->
                    c

        report trace result =
            reportWith trace Encode.null result

        reportWith trace answer result =
            toMsg
                { id = envelope.id
                , result = encodeResult encodeResponse result
                , trace = trace
                , response = answer
                }

        cancelling =
            case ( envelope.cancelAfter, tracker ) of
                ( Just _, Just name ) ->
                    Just
                        (Cmd.batch
                            [ Rpc.cancel name
                            , Task.succeed
                                { id = envelope.id
                                , result = Encode.object [ ( "canceled", Encode.bool True ) ]
                                , trace = Encode.null
                                , response = Encode.null
                                }
                                |> Task.perform toMsg
                            ]
                        )

                _ ->
                    Nothing

        uncancellable send =
            case envelope.cancelAfter of
                Just _ ->
                    Err ("a call sent with " ++ send ++ " cannot be cancelled: it ignores the tracker")

                Nothing ->
                    Ok Nothing
    in
    case envelope.sending of
        Traced ->
            uncancellable "sendTraced"
                |> Result.map (Sent (Rpc.sendTraced envelope.config (\trace -> report (Rpc.Trace.toJson trace)) tracked))

        Plain ->
            case envelope.config.retry of
                Just _ ->
                    uncancellable "send and a retry policy"
                        |> Result.map (Sent (Rpc.send envelope.config (report Encode.null) tracked))

                Nothing ->
                    Ok (Sent (Rpc.send envelope.config (report Encode.null) tracked) cancelling)

        AsTask ->
            uncancellable "task"
                |> Result.map (Sent (Rpc.task envelope.config tracked |> Task.attempt (report Encode.null)))

        Halves ->
            Ok
                (Sent (sendHalves envelope.config tracked tracker (\( answer, result ) -> reportWith Encode.null answer result))
                    cancelling
                )


{-| Send a call as `Rpc.request` describes it, with elm/http directly, and read
the answer with `Rpc.response`, keeping the answer's status and headers.
-}
sendHalves : Rpc.Config -> Rpc.Call req res -> Maybe String -> (( Value, Result Rpc.Error res ) -> msg) -> Cmd msg
sendHalves config c tracker toMsg =
    let
        sent =
            Rpc.request config c

        perform =
            if sent.withCredentials then
                Http.riskyRequest

            else
                Http.request

        read answer =
            Ok ( encodeAnswer answer, Rpc.response config c answer )
    in
    perform
        { method = sent.method
        , headers = List.map (\( name, value ) -> Http.header name value) sent.headers
        , url = sent.url
        , body =
            case Rpc.Body.toText sent.body of
                Just json ->
                    Http.stringBody "application/json" json

                Nothing ->
                    Http.emptyBody
        , expect =
            Http.expectStringResponse
                (\outcome ->
                    case outcome of
                        Ok pair ->
                            toMsg pair

                        Err impossible ->
                            never impossible
                )
                read
        , timeout = sent.timeout
        , tracker = tracker
        }


encodeAnswer : Http.Response String -> Value
encodeAnswer answer =
    let
        withMetadata metadata =
            Encode.object
                [ ( "status", Encode.int metadata.statusCode )
                , ( "headers", Encode.list (\( k, v ) -> Encode.list Encode.string [ k, v ]) (Dict.toList metadata.headers) )
                ]
    in
    case answer of
        Http.GoodStatus_ metadata _ ->
            withMetadata metadata

        Http.BadStatus_ metadata _ ->
            withMetadata metadata

        _ ->
            Encode.null


encodeResult : (res -> Value) -> Result Rpc.Error res -> Value
encodeResult encodeResponse result =
    case result of
        Ok response ->
            Encode.object [ ( "ok", encodeResponse response ) ]

        Err (Rpc.Error.RpcStatus status answer) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.Code.toString status.code) )
                        , ( "message", Encode.string status.message )
                        , ( "details", Encode.list Proto.Any.encodeJson status.details )
                        , ( "source", Encode.string (sourceToString status.source) )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err ((Rpc.Error.HttpStatus answer) as error) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.Code.toString (Rpc.Error.code error)) )
                        , ( "message", Encode.string (Rpc.Error.message error) )
                        , ( "details", Encode.list Proto.Any.encodeJson [] )
                        , ( "source", Encode.string "HttpStatus" )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err (Rpc.Error.BadResponse problem answer) ->
            Encode.object
                [ ( "badResponse"
                  , Encode.object
                        [ ( "problem", Encode.string problem )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err (Rpc.Error.NoAnswer reason) ->
            Encode.object [ ( "noAnswer", Encode.string (reasonToString reason) ) ]


{-| The answer an error was read from: its status and body. The headers are
left out; the trace carries what a case wants of them.
-}
encodeResponse_ : Rpc.Response -> Value
encodeResponse_ answer =
    Encode.object
        [ ( "statusCode", Encode.int answer.statusCode )
        , ( "statusText", Encode.string answer.statusText )
        , ( "body", Encode.string (Maybe.withDefault "" (Rpc.Body.toText answer.body)) )
        ]


sourceToString : Rpc.Error.Source -> String
sourceToString source =
    case source of
        Rpc.Error.ConnectBody ->
            "ConnectBody"

        Rpc.Error.StatusBody ->
            "StatusBody"

        Rpc.Error.GrpcHeaders ->
            "GrpcHeaders"


reasonToString : Rpc.Error.Reason -> String
reasonToString reason =
    case reason of
        Rpc.Error.Timeout ->
            "Timeout"

        Rpc.Error.NetworkError ->
            "NetworkError"

        Rpc.Error.BadUrl url ->
            "BadUrl " ++ url

        Rpc.Error.InvalidHeader name ->
            "InvalidHeader " ++ name
