module Rpc.Internal.Answer exposing (binaryReader, toResult, toResultBytes)

{-| Reading an answer to a call: the decoded response, or the `Rpc.Error` it
stands for, from a Connect error body, a `google.rpc.Status` body or gRPC
status headers, whatever the transport. Not exposed; it is what
`Rpc.response` stands for, kept out of `Rpc` so that the public module reads
as API.
-}

import Bytes exposing (Bytes)
import Dict
import Http
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Internal.Any
import Proto.Internal.Method
import Proto.Json
import Proto.Method as Method
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Route exposing (Route(..), route)
import Rpc.Internal.Transport as Transport exposing (Transport(..))
import Rpc.Response exposing (Response)


{-| What an answer to a call over a transport means: the decoded response, or
the error.
-}
toResult : Transport -> Call req res -> Http.Response String -> Result Error res
toResult transport ((Call fields) as c) answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            case ( transport, route transport c ) of
                ( Transcode _, Bound _ rule ) ->
                    within transport raw (\_ -> decodeBody (responseDecoder rule.responseBody (Method.responseDecoder fields.method)) metadata raw (orEmptyObject raw))

                ( Transcode _, Implicit ) ->
                    within transport raw (\_ -> decodeBody (Method.responseDecoder fields.method) metadata raw (orEmptyObject raw))

                _ ->
                    if metadata.statusCode /= 200 then
                        Err (failure metadata raw)

                    else
                        case Proto.Internal.Method.binaryUnder (Transport.proto transport) fields.method of
                            Just _ ->
                                Err (Error.BadResponse "a protobuf binary answer is read as bytes (Rpc.responseBytes)" (answerOf metadata raw))

                            Nothing ->
                                within transport raw (\_ -> decodeBody (Method.responseDecoder fields.method) metadata raw raw)

        Http.BadStatus_ metadata raw ->
            Err (failure metadata raw)

        Http.BadUrl_ url ->
            Err (Error.NoAnswer (Error.BadUrl url))

        Http.Timeout_ ->
            Err (Error.NoAnswer Error.Timeout)

        Http.NetworkError_ ->
            Err (Error.NoAnswer Error.NetworkError)


{-| What an answer read as bytes means. Over Connect's proto codec a
successful answer is the response's protobuf binary, and every other answer
is JSON, read as `toResult` reads it; under any other codec the bytes are the
answer's text.
-}
toResultBytes : Transport -> Call req res -> Http.Response Bytes -> Result Error res
toResultBytes transport c answer =
    case binaryReader transport c of
        Just read ->
            Tuple.second (read answer)

        Nothing ->
            toResult transport c (asText answer)


{-| How a call's answer is read as bytes, when the call is sent so (over
Connect's proto codec or gRPC-Web, by a method with binary codecs): its
metadata, gRPC-Web's body trailers among them, and what it means.
-}
binaryReader : Transport -> Call req res -> Maybe (Http.Response Bytes -> ( Maybe Http.Metadata, Result Error res ))
binaryReader transport ((Call fields) as c) =
    Proto.Internal.Method.binaryUnder (Transport.proto transport) fields.method
        |> Maybe.map
            (\binary ->
                case transport of
                    GrpcWeb _ ->
                        \answer -> ( binary.grpcWebMetadata answer, binary.readGrpcWeb (Transport.readMaxBytes transport) (toResult transport c) answer )

                    _ ->
                        \answer -> ( Internal.metadataOf answer, binary.read (Transport.readMaxBytes transport) (toResult transport c) answer )
            )


asText : Http.Response Bytes -> Http.Response String
asText answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            Http.GoodStatus_ metadata (Internal.bytesText raw)

        Http.BadStatus_ metadata raw ->
            Http.BadStatus_ metadata (Internal.bytesText raw)

        Http.BadUrl_ url ->
            Http.BadUrl_ url

        Http.Timeout_ ->
            Http.Timeout_

        Http.NetworkError_ ->
            Http.NetworkError_


{-| A successful answer's body read by `decode`, unless it is longer than the
transport reads: then it is dropped unread, and the call fails with
`ResponseTooLarge`.
-}
within : Transport -> String -> (() -> Result Error res) -> Result Error res
within transport raw decode =
    case Transport.readMaxBytes transport of
        Just limit ->
            case Internal.overLimit limit raw of
                Just size ->
                    Err (Error.NoAnswer (Error.ResponseTooLarge { limit = limit, size = size }))

                Nothing ->
                    decode ()

        Nothing ->
            decode ()


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


{-| The response `read` from a successful answer's body, or a `BadResponse`
keeping the answer as it came, `raw`.
-}
decodeBody : Decoder res -> Http.Metadata -> String -> String -> Result Error res
decodeBody decoder metadata raw read =
    Json.Decode.decodeString decoder read
        |> Result.mapError (\problem -> Error.BadResponse (Json.Decode.errorToString problem) (answerOf metadata raw))


{-| An answer as an error keeps it.
-}
answerOf : Http.Metadata -> String -> Response
answerOf metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.text raw
    }


{-| The error a failed answer stands for, whatever the transport: its Connect
error body, or its `google.rpc.Status` body, or its `grpc-status` and
`grpc-message` headers, or failing all of those, an `HttpStatus` error. The
answer is kept whichever it is.
-}
failure : Http.Metadata -> String -> Error
failure metadata raw =
    let
        answer =
            answerOf metadata raw
    in
    case Json.Decode.decodeString (Json.Decode.oneOf [ connectBody, statusBody ]) raw of
        Ok read ->
            Error.RpcStatus read answer

        Err _ ->
            case header "grpc-status" metadata |> Maybe.andThen (String.trim >> String.toInt) of
                Just number ->
                    Error.RpcStatus
                        { code = fromGrpc number
                        , message =
                            header "grpc-message" metadata
                                |> Maybe.map (\text -> Internal.percentDecode text |> Maybe.withDefault text)
                                |> Maybe.withDefault (Error.message (Error.HttpStatus answer))
                        , details = []
                        , source = Error.GrpcHeaders
                        }
                        answer

                Nothing ->
                    Error.HttpStatus answer


{-| A response header by name, whatever its case.
-}
header : String -> Http.Metadata -> Maybe String
header key metadata =
    metadata.headers
        |> Dict.toList
        |> List.filter (\( k, _ ) -> String.toLower k == key)
        |> List.head
        |> Maybe.map Tuple.second


fromGrpc : Int -> Code
fromGrpc number =
    Code.fromInt number |> Maybe.withDefault Code.Unknown


{-| A `google.rpc.Status` body: an integer `code`, an optional `message` and
optional `details`.
-}
statusBody : Decoder Error.StatusError
statusBody =
    Json.Decode.map3 (\number text found -> { code = fromGrpc number, message = text, details = found, source = Error.StatusBody })
        (Json.Decode.field "code" Json.Decode.int)
        (optional "message" Json.Decode.string "")
        (optional "details" detailList [])


{-| A Connect error body: a `code` the protocol names (an unknown name reads as
`unknown`), an optional `message` and optional `details`.
-}
connectBody : Decoder Error.StatusError
connectBody =
    Json.Decode.map3 (\name text found -> { code = name, message = text, details = found, source = Error.ConnectBody })
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
    Json.Decode.list (Json.Decode.maybe (Json.Decode.oneOf [ Proto.Json.any, connectDetail ]))
        |> Json.Decode.map (List.filterMap identity)


{-| A Connect error detail: the message's full name as `type`, its protobuf
binary as base64 `value`, and optionally its JSON as `debug`, which the `Any`
holds beside the binary when present. Without it the `Any` holds the binary
alone.
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
                        Proto.Internal.Any.InBoth json binary

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
