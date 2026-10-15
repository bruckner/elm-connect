module Live.Call exposing (Entry, Envelope, Outcome, Sending(..), Transport(..), entry)

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
the request does not decode or the binding does not exist, or a command that
reports the outcome.
-}
type alias Entry msg =
    Envelope -> (Outcome -> msg) -> Result String (Cmd msg)


{-| What became of a call, as JSON: the result, the trace when the call was
sent with `Rpc.sendTraced` (`null` otherwise), and the answer's status and
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
                            reportWith trace Encode.null result

                        reportWith trace answer result =
                            toMsg
                                { id = envelope.id
                                , result = encodeResult encodeResponse result
                                , trace = trace
                                , response = answer
                                }
                    in
                    case envelope.sending of
                        Traced ->
                            Rpc.sendTraced envelope.config tracked (\trace -> report (encodeTrace trace))

                        Plain ->
                            Rpc.send envelope.config tracked (report Encode.null)

                        AsTask ->
                            Rpc.task envelope.config tracked |> Task.attempt (report Encode.null)

                        Halves ->
                            sendHalves envelope.config tracked envelope.tracker (\( answer, result ) -> reportWith Encode.null answer result)
                )
                bound


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
            case sent.body of
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

        Err (Rpc.Status status answer) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.ErrorCode.toString status.code) )
                        , ( "message", Encode.string status.message )
                        , ( "details", Encode.list Proto.Any.encodeJson status.details )
                        , ( "source", Encode.string (sourceToString status.source) )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err ((Rpc.Http answer) as error) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.ErrorCode.toString (Rpc.code error)) )
                        , ( "message", Encode.string (Rpc.message error) )
                        , ( "details", Encode.list Proto.Any.encodeJson [] )
                        , ( "source", Encode.string "HttpStatus" )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err (Rpc.Transport problem) ->
            Encode.object [ ( "transport", Encode.string (httpErrorToString problem) ) ]


{-| The answer an error was read from: its status and body. The headers are
left out; the trace carries what a case wants of them.
-}
encodeResponse_ : Rpc.Response -> Value
encodeResponse_ answer =
    Encode.object
        [ ( "statusCode", Encode.int answer.statusCode )
        , ( "statusText", Encode.string answer.statusText )
        , ( "body", Encode.string answer.body )
        ]


sourceToString : Rpc.Source -> String
sourceToString source =
    case source of
        Rpc.ConnectBody ->
            "ConnectBody"

        Rpc.StatusBody ->
            "StatusBody"

        Rpc.GrpcHeaders ->
            "GrpcHeaders"


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
        , ( "headers", Encode.dict identity Encode.string trace.headers )
        , ( "trailers", Encode.dict identity Encode.string trace.trailers )
        , ( "code", Encode.string (Rpc.Code.toString trace.code) )
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
