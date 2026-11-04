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
optional `details`. Its details are proto3 JSON, which only a registry reads
([`completeDetails`](#completeDetails)), so it is read here without them.
-}
statusBody : Decoder Error.StatusError
statusBody =
    Json.Decode.map2 (\number text -> { code = fromGrpc number, message = text, details = [], source = Error.StatusBody })
        (Json.Decode.field "code" Json.Decode.int)
        (optional "message" Json.Decode.string "")


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
        (optional "details" (detailList connectDetail) [])


{-| An error's details as `read` reads each: a Connect body holds
`{"type", "value", "debug"}` objects, a `google.rpc.Status` body proto3 JSON
`Any` objects. A detail `read` cannot read is left out rather than losing the
error's code and message with it.
-}
detailList : Decoder Error.Detail -> Decoder (List Error.Detail)
detailList read =
    Json.Decode.list (Json.Decode.maybe read)
        |> Json.Decode.map (List.filterMap identity)


{-| A Connect error detail: the message's full name as `type` and its
protobuf binary as base64 `value`; its JSON, `debug`, is not read.
-}
connectDetail : Decoder Error.Detail
connectDetail =
    Json.Decode.map2
        (\name binary ->
            let
                url =
                    if String.contains "/" name then
                        name

                    else
                        "type.googleapis.com/" ++ name
            in
            Proto.Internal.Any.Any url (Proto.Internal.Any.Binary binary)
        )
        (Json.Decode.field "type" Json.Decode.string)
        (optional "value" Json.Decode.string "")


{-| An error with its details read again from its body, with the registry
reading those that arrived as proto3 JSON: a `google.rpc.Status` body's, or
a Connect body's in that form. A detail of a type the registry lacks is left
out. A status from gRPC headers or trailers carries its details as binary,
and is kept as it is.
-}
completeDetails : Registry -> Error -> Error
completeDetails registry error =
    case error of
        Error.RpcStatus status answer ->
            case status.source of
                Error.StatusBody ->
                    Error.RpcStatus { status | details = bodyDetails registry answer } answer

                Error.ConnectBody ->
                    Error.RpcStatus { status | details = bodyDetails registry answer } answer

                _ ->
                    error

        _ ->
            error


bodyDetails : Registry -> Response -> List Error.Detail
bodyDetails registry answer =
    Rpc.Body.toText answer.body
        |> Maybe.andThen
            (Json.Decode.decodeString
                (optional "details" (detailList (Json.Decode.oneOf [ Proto.Json.anyWith registry, connectDetail ])) [])
                >> Result.toMaybe
            )
        |> Maybe.withDefault []


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]
