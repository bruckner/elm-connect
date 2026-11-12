module Rpc.Internal.Status exposing (answerOf, bytesFailure, bytesFailureBy, completeDetails, connectFailure, failure, header, otherFailure, otherFailureBy)

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
import Proto.Error
import Proto.Internal.Any
import Proto.Internal.Percent as Percent
import Proto.Internal.Registry
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
bytesFailure =
    bytesFailureBy failure


{-| `bytesFailure`, its failed answer read by `read`.
-}
bytesFailureBy : (Http.Metadata -> String -> Error) -> Http.Response Bytes -> Error
bytesFailureBy read answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            read metadata (Internal.bytesText raw)

        Http.BadStatus_ metadata raw ->
            read metadata (Internal.bytesText raw)

        Http.BadUrl_ url ->
            Error.NoAnswer (Error.BadUrl url)

        Http.Timeout_ ->
            Error.NoAnswer Error.Timeout

        Http.NetworkError_ ->
            Error.NoAnswer Error.NetworkError


{-| The error of an answer that is not a protocol's success.
-}
otherFailure : Http.Response String -> Error
otherFailure =
    otherFailureBy failure


{-| `otherFailure`, its failed answer read by `read`.
-}
otherFailureBy : (Http.Metadata -> String -> Error) -> Http.Response String -> Error
otherFailureBy read answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            read metadata raw

        Http.BadStatus_ metadata raw ->
            read metadata raw

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


{-| The error a failed Connect answer stands for: its Connect error body, or
failing that, an `HttpStatus` error. A Connect server writes no other form,
so a program that speaks only Connect reads no `google.rpc.Status` body and
no gRPC status headers.
-}
connectFailure : Http.Metadata -> String -> Error
connectFailure metadata raw =
    let
        answer =
            answerOf metadata raw
    in
    case Json.Decode.decodeString connectBody raw of
        Ok read ->
            Error.RpcStatus read answer

        Err _ ->
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
when it holds a `/`) and its protobuf binary as base64 `value`, which may
be left out for an empty message. Its JSON, `debug`, is not read. A detail
with no `type`, or whose `value` is not base64, is its `BadJson`.
-}
connectDetail : Value -> Result Proto.Error.Error Any
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
                    |> Maybe.andThen canonicalBase64
            of
                Just base64 ->
                    Ok (Proto.Internal.Any.Any url (Proto.Internal.Any.Binary base64))

                Nothing ->
                    -- elm/json's own error, at the field, holding the value.
                    Json.Decode.decodeValue (Json.Decode.field "value" (Json.Decode.fail "Expecting base64 text, standard or URL-safe")) detail
                        |> Result.map (\_ -> Proto.Internal.Any.empty)
                        |> Result.mapError Proto.Error.BadJson

        Err problem ->
            Err (Proto.Error.BadJson problem)


{-| Base64 text in the form an `Any` holds its binary in, the standard
alphabet padded with `=`, from either alphabet with or without padding;
`Nothing` for text that is not base64. It works on the text, without
decoding it, so that reading an error reaches no bytes code.
-}
canonicalBase64 : String -> Maybe String
canonicalBase64 text =
    let
        body =
            dropPadding text

        partial =
            modBy 4 (String.length body)

        padding =
            String.length text - String.length body

        standard =
            String.any (\char -> char == '+' || char == '/') body

        urlSafe =
            String.any (\char -> char == '-' || char == '_') body
    in
    if
        not (String.all base64Char body)
            || (partial == 1)
            || (padding /= 0 && (partial == 0 || padding /= 4 - partial))
            || (standard && urlSafe)
    then
        Nothing

    else
        Just (String.map standardChar body ++ String.repeat (modBy 4 (4 - partial)) "=")


{-| A character of either base64 alphabet. `String.fromChar` keeps a lone
surrogate, which `String.all` would read with its neighbour, from passing.
-}
base64Char : Char -> Bool
base64Char char =
    String.length (String.fromChar char) == 1 && (Char.isAlphaNum char || String.contains (String.fromChar char) "+/-_")


standardChar : Char -> Char
standardChar char =
    case char of
        '-' ->
            '+'

        '_' ->
            '/'

        _ ->
            char


dropPadding : String -> String
dropPadding text =
    if String.endsWith "=" text then
        dropPadding (String.dropRight 1 text)

    else
        text


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


bodyDetails : Registry -> Response -> List (Result Proto.Error.Error Any)
bodyDetails registry answer =
    Rpc.Body.toText answer.body
        |> Maybe.andThen
            (Json.Decode.decodeString
                (optional "details" (Json.Decode.list (Json.Decode.map (statusDetail registry) Json.Decode.value)) [])
                >> Result.toMaybe
            )
        |> Maybe.withDefault []


{-| A `google.rpc.Status` detail: a proto3 JSON `Any`, converted to its
message's binary through the registry. A type the registry lacks is
`UnregisteredType`, read from the failure (`Proto.Internal.Registry.unregistered`);
any other failure, a detail with no `"@type"` among them, is its `BadJson`.
-}
statusDetail : Registry -> Value -> Result Proto.Error.Error Any
statusDetail registry detail =
    case Json.Decode.decodeValue (Json.Decode.field "@type" Json.Decode.string |> Json.Decode.andThen (\_ -> Proto.Json.anyWith registry)) detail of
        Ok any ->
            Ok any

        Err problem ->
            case Proto.Internal.Registry.unregistered registry problem of
                Just url ->
                    Err (Proto.Error.UnregisteredType url)

                Nothing ->
                    Err (Proto.Error.BadJson problem)


optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Json.Decode.oneOf
        [ Json.Decode.field key (Json.Decode.nullable decoder)
            |> Json.Decode.map (Maybe.withDefault default)
        , Json.Decode.succeed default
        ]
