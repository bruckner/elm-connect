module Live.Call exposing (Entry, Envelope, Outcome, Sending(..), Transport(..), entry)

{-| What the live runner sends: an envelope read from JSON, and an entry of a
dispatch table, which turns one into a sent call and its result into JSON.

A dispatch table (`Live.Notes.table`) lists one entry per method, each built by
[`entry`](#entry) from the generated call function and the codecs the runner
needs beyond it: the request's decoder, since the envelope holds the request as
proto3 JSON, and the response's encoder, since the result reports it so.

-}

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Proto.Any
import Rpc
import Rpc.Code
import Rpc.ErrorCode
import Task


{-| One call to make: the method, its request as proto3 JSON, the transport,
the config and the binding, if one is chosen.
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
    }


{-| Which of the runtime's ways of sending a call to use.
-}
type Sending
    = Traced
    | Plain
    | AsTask


{-| The transport a call goes over, as the envelope names it.
-}
type Transport
    = Connect
    | Transcode


{-| How a dispatch table sends an envelope's call: `Err` with a reason when
the request does not decode or the binding does not exist, or a command that
reports the outcome.
-}
type alias Entry msg =
    Envelope -> (Outcome -> msg) -> Result String (Cmd msg)


{-| What became of a call, as JSON: the result, and the trace when the call
was sent with `Rpc.sendTraced` (`null` otherwise).
-}
type alias Outcome =
    { id : String, result : Value, trace : Value }


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
                            Rpc.viaBinding index plain
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
            Result.map
                (\c ->
                    let
                        tracked =
                            case envelope.tracker of
                                Just name ->
                                    Rpc.withTracker name c

                                Nothing ->
                                    c

                        report trace result =
                            toMsg
                                { id = envelope.id
                                , result = encodeResult encodeResponse result
                                , trace = trace
                                }
                    in
                    case envelope.sending of
                        Traced ->
                            Rpc.sendTraced envelope.config tracked (\trace -> report (encodeTrace trace))

                        Plain ->
                            Rpc.send envelope.config tracked (report Encode.null)

                        AsTask ->
                            Rpc.task envelope.config tracked |> Task.attempt (report Encode.null)
                )
                bound


encodeResult : (res -> Value) -> Result Rpc.Error res -> Value
encodeResult encodeResponse result =
    case result of
        Ok response ->
            Encode.object [ ( "ok", encodeResponse response ) ]

        Err (Rpc.Rpc rpc) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.ErrorCode.toString rpc.code) )
                        , ( "message", Encode.string rpc.message )
                        , ( "details", Encode.list Proto.Any.encodeJson rpc.details )
                        , ( "source", Encode.string (sourceToString rpc.source) )
                        ]
                  )
                ]

        Err (Rpc.Transport problem) ->
            Encode.object [ ( "transport", Encode.string (httpErrorToString problem) ) ]


sourceToString : Rpc.Source -> String
sourceToString source =
    case source of
        Rpc.ConnectBody ->
            "ConnectBody"

        Rpc.StatusBody number ->
            "StatusBody " ++ String.fromInt number

        Rpc.GrpcHeaders ->
            "GrpcHeaders"

        Rpc.HttpStatus status ->
            "HttpStatus " ++ String.fromInt status


httpErrorToString : Http.Error -> String
httpErrorToString problem =
    case problem of
        Http.BadUrl url ->
            "BadUrl " ++ url

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "NetworkError"

        Http.BadStatus status ->
            "BadStatus " ++ String.fromInt status

        Http.BadBody text ->
            "BadBody " ++ text


encodeTrace : Rpc.Trace -> Value
encodeTrace trace =
    Encode.object
        [ ( "service", Encode.string trace.service )
        , ( "method", Encode.string trace.method )
        , ( "binding", maybe Encode.int trace.binding )
        , ( "httpStatus", maybe Encode.int trace.httpStatus )
        , ( "code", maybe (Rpc.Code.toString >> Encode.string) trace.code )
        , ( "attempts", Encode.int trace.attempts )
        , ( "duration", Encode.float trace.duration )
        , ( "request", encodeRequest trace.request )
        ]


encodeRequest : Rpc.Request -> Value
encodeRequest request =
    Encode.object
        [ ( "method", Encode.string request.method )
        , ( "url", Encode.string request.url )
        , ( "headers", Encode.list (\( k, v ) -> Encode.list Encode.string [ k, v ]) request.headers )
        , ( "body", maybe Encode.string request.body )
        , ( "timeout", maybe Encode.float request.timeout )
        , ( "withCredentials", Encode.bool request.withCredentials )
        ]


maybe : (a -> Value) -> Maybe a -> Value
maybe encode value =
    Maybe.map encode value |> Maybe.withDefault Encode.null
