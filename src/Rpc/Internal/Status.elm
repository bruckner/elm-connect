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
import Json.Decode exposing (Decoder, Value)
import Proto.Any exposing (Any)
import Proto.Bytes
import Proto.Internal.Any
import Proto.Internal.Percent as Percent
import Proto.Internal.Registry as InternalRegistry exposing (Registry)
import Proto.Json
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
optional `details`. Its details are proto3 JSON, which only the client's
registry reads ([`completeDetails`](#completeDetails)), so they are read
there.
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
        (optional "details" (Json.Decode.list (Json.Decode.map connectDetail Json.Decode.value)) [])


{-| A Connect error detail: the message's full name as `type` (a type URL
when it holds a `/`), its protobuf binary as base64 `value` in either
alphabet, with or without padding, which may be left out for an empty
message, and optionally its proto3 JSON as `debug`, which the `Any` keeps
beside the binary, as the server wrote it.
-}
connectDetail : Value -> Result Error.DetailProblem Any
connectDetail detail =
    case Json.Decode.decodeValue (Json.Decode.field "type" Json.Decode.string) detail of
        Ok name ->
            let
                url =
                    if String.contains "/" name then
                        name

                    else
                        "type.googleapis.com/" ++ name
            in
            case
                Json.Decode.decodeValue (optional "value" Json.Decode.string "") detail
                    |> Result.toMaybe
                    |> Maybe.andThen Proto.Bytes.fromBase64
            of
                Just binary ->
                    Ok
                        (Proto.Internal.Any.Any url
                            (case Json.Decode.decodeValue (optional "debug" (Json.Decode.map Just Json.Decode.value) Nothing) detail of
                                Ok (Just json) ->
                                    Proto.Internal.Any.Both (Proto.Internal.Any.blob binary) json

                                _ ->
                                    Proto.Internal.Any.Binary (Proto.Internal.Any.blob binary)
                            )
                        )

                Nothing ->
                    Err (Error.InvalidDetail (Just url) "a Connect detail whose value is not base64")

        Err _ ->
            Err (Error.InvalidDetail Nothing "a Connect detail with no type")


{-| An error with the details of a `google.rpc.Status` body read, through the
registry: they are proto3 JSON, so [`failure`](#failure), which has no
registry, leaves them out. Any other error is kept as it is.
-}
completeDetails : Registry -> Error -> Error
completeDetails registry error =
    case error of
        Error.RpcStatus status answer ->
            case status.source of
                Error.StatusBody ->
                    Error.RpcStatus { status | details = bodyDetails registry answer } answer

                _ ->
                    error

        _ ->
            error


bodyDetails : Registry -> Response -> List (Result Error.DetailProblem Any)
bodyDetails registry answer =
    Rpc.Body.toText answer.body
        |> Maybe.andThen
            (Json.Decode.decodeString
                (optional "details" (Json.Decode.list (Json.Decode.map (statusDetail registry) Json.Decode.value)) [])
                >> Result.toMaybe
            )
        |> Maybe.withDefault []


{-| A `google.rpc.Status` detail: a proto3 JSON `Any`, converted to its
message's binary through the registry.
-}
statusDetail : Registry -> Value -> Result Error.DetailProblem Any
statusDetail registry detail =
    case Json.Decode.decodeValue (Json.Decode.field "@type" Json.Decode.string) detail of
        Ok url ->
            case Json.Decode.decodeValue (Proto.Json.anyWith registry) detail of
                Ok any ->
                    Ok any

                Err problem ->
                    if InternalRegistry.member (Proto.Internal.Any.nameOf url) registry then
                        Err (Error.InvalidDetail (Just url) (Json.Decode.errorToString problem))

                    else
                        Err (Error.UnregisteredType url)

        Err _ ->
            Err (Error.InvalidDetail Nothing "a detail with no \"@type\"")


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]
