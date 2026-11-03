module Rpc.Internal.Status exposing (answerOf, bytesFailure, completeDetails, failure, header, otherFailure)

{-| A failure's status as an `Rpc.Error`, from a Connect error body, a
`google.rpc.Status` body, or gRPC status headers and trailers, whatever the
protocol. Not exposed. Every protocol module (`Rpc.Internal.Connect`,
`Rpc.Internal.Transcode`, `Rpc.Internal.GrpcWeb`) reaches it for an answer
that is not its success, and `Rpc.response` and `Rpc.responseBytes` reach
`otherFailure` and `bytesFailure` for the arm a call's codec rules out.
-}

import Bytes exposing (Bytes)
import Dict
import Http
import Json.Decode exposing (Decoder)
import Proto.Any
import Proto.Internal.Any
import Proto.Internal.Percent as Percent
import Proto.Json
import Proto.Registry exposing (Registry)
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Http as Internal
import Rpc.Response exposing (Response)


{-| The error of a binary answer read as a failure: its body as UTF-8 text,
which a failure's JSON is.
-}
bytesFailure : Http.Response Bytes -> Error
bytesFailure answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            failure metadata (Internal.bytesText raw)

        Http.BadStatus_ metadata raw ->
            failure metadata (Internal.bytesText raw)

        Http.BadUrl_ url ->
            Error.NoAnswer (Error.BadUrl url)

        Http.Timeout_ ->
            Error.NoAnswer Error.Timeout

        Http.NetworkError_ ->
            Error.NoAnswer Error.NetworkError


{-| The error of an answer that is not a protocol's success.
-}
otherFailure : Http.Response String -> Error
otherFailure answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            failure metadata raw

        Http.BadStatus_ metadata raw ->
            failure metadata raw

        Http.BadUrl_ url ->
            Error.NoAnswer (Error.BadUrl url)

        Http.Timeout_ ->
            Error.NoAnswer Error.Timeout

        Http.NetworkError_ ->
            Error.NoAnswer Error.NetworkError


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


{-| The error a failed answer stands for, whatever the protocol: its Connect
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
                                |> Maybe.map (\text -> Percent.percentDecode text |> Maybe.withDefault text)
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


{-| An error's details, each in the form its body holds it: a
`google.rpc.Status` body holds proto3 JSON `Any` objects, a Connect body
`{"type", "value", "debug"}` objects. A detail in neither form is left out
rather than losing the error's code and message with it.
-}
detailList : Decoder (List Error.Detail)
detailList =
    Json.Decode.list
        (Json.Decode.maybe
            (Json.Decode.oneOf
                [ Proto.Json.any |> Json.Decode.map (\any -> { proto = Nothing, json = Just any })
                , connectDetail
                ]
            )
        )
        |> Json.Decode.map (List.filterMap identity)


{-| A Connect error detail: the message's full name as `type`, its protobuf
binary as base64 `value`, and optionally its JSON as `debug`.
-}
connectDetail : Decoder Error.Detail
connectDetail =
    Json.Decode.map3
        (\name binary debug ->
            let
                url =
                    if String.contains "/" name then
                        name

                    else
                        "type.googleapis.com/" ++ name
            in
            { proto = Just (Proto.Internal.Any.Any url (Proto.Internal.Any.InProto binary))
            , json = Maybe.map (\json -> Proto.Internal.Any.Any url (Proto.Internal.Any.InJson json)) debug
            }
        )
        (Json.Decode.field "type" Json.Decode.string)
        (optional "value" Json.Decode.string "")
        (optional "debug" (Json.Decode.map Just Json.Decode.value) Nothing)


{-| An error with each of its details' missing form filled in, where the
registry has the detail's type.
-}
completeDetails : Registry -> Error -> Error
completeDetails registry error =
    case error of
        Error.RpcStatus status answer ->
            Error.RpcStatus { status | details = List.map (completeDetail registry) status.details } answer

        _ ->
            error


completeDetail : Registry -> Error.Detail -> Error.Detail
completeDetail registry detail =
    case ( detail.proto, detail.json ) of
        ( Just proto, Nothing ) ->
            { detail | json = Proto.Any.toJson registry proto }

        ( Nothing, Just json ) ->
            { detail | proto = Proto.Any.toProto registry json }

        _ ->
            detail


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]
