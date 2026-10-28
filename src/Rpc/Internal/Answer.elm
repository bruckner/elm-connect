module Rpc.Internal.Answer exposing
    ( badText
    , bytesFailure
    , bytesOverRead
    , connectMessage
    , connectProtoMessage
    , fieldDecoder
    , grpcWebMessage
    , otherFailure
    , textOverRead
    , transcodeMessage
    )

{-| Reading an answer to a call: the decoded response, or the `Rpc.Error` it
stands for, from a Connect error body, a `google.rpc.Status` body or gRPC
status headers or trailers, whatever the protocol. Not exposed; it is what
`Rpc.response` and `Rpc.responseBytes` stand for, kept out of `Rpc` so that
the public module reads as API.

There are two readers, one of text and one of bytes, each over its kind of
protocol. A protocol's own reading (which statuses succeed, where the status
of a failure is, how a body is framed) is a top-level function here that its
constructor puts in it; reading a failure's JSON is shared.

-}

import Bytes exposing (Bytes)
import Dict
import Http
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Internal.Any
import Proto.Internal.Percent as Percent
import Proto.Json
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Error as Error exposing (Error, Reason)
import Rpc.Internal.GrpcWeb as GrpcWeb
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (BinaryWire, BytesMessage, GoodBytes, GoodText, Options, TextWire)
import Rpc.Response exposing (Response)



-- THE TWO READERS


{-| A successful text answer, unless it is over the read limit.
-}
withinText : (Options -> String -> Maybe Reason) -> Options -> GoodText -> Result Error GoodText
withinText overRead options good =
    case overRead options good.raw of
        Just reason ->
            Err (Error.NoAnswer reason)

        Nothing ->
            Ok good


{-| The error a successful text answer stands for when the response's
decoder does not read it, keeping the answer.
-}
badText : GoodText -> Json.Decode.Error -> Error
badText good problem =
    Error.BadResponse (Json.Decode.errorToString problem) (answerOf good.metadata good.raw)


{-| A successful binary answer's message, unless it is over the read limit.
-}
bytesMessage : (Options -> Bytes -> Maybe Reason) -> Options -> String -> ( Maybe Http.Metadata, Result Error GoodBytes ) -> ( Maybe Http.Metadata, Result Error BytesMessage )
bytesMessage overRead options procedure ( metadata, read ) =
    ( metadata
    , read
        |> Result.andThen
            (\good ->
                case overRead options good.message of
                    Just reason ->
                        Err (Error.NoAnswer reason)

                    Nothing ->
                        Ok
                            { bytes = good.message
                            , bad = \() -> Error.BadResponse ("the body is not the response of " ++ procedure ++ " in protobuf binary") (bytesAnswer good.metadata good.raw)
                            }
            )
    )



-- PROTOCOLS


{-| Connect's message of a JSON answer.
-}
connectMessage : (Options -> String -> Maybe Reason) -> Options -> Maybe String -> Http.Response String -> Result Error GoodText
connectMessage overRead options _ answer =
    connectRead answer |> Result.andThen (withinText overRead options)


{-| Transcoding's message.
-}
transcodeMessage : (Options -> String -> Maybe Reason) -> Options -> Maybe String -> Http.Response String -> Result Error GoodText
transcodeMessage overRead options responseBody answer =
    transcodeRead responseBody answer |> Result.andThen (withinText overRead options)


{-| Connect's message of a protobuf binary answer.
-}
connectProtoMessage : (Options -> Bytes -> Maybe Reason) -> Options -> String -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error BytesMessage )
connectProtoMessage overRead options procedure answer =
    bytesMessage overRead options procedure (connectProtoRead answer)


{-| gRPC-Web's message: its framing and trailers (`Rpc.Internal.GrpcWeb`).
-}
grpcWebMessage : (Options -> Bytes -> Maybe Reason) -> Options -> String -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error BytesMessage )
grpcWebMessage overRead options procedure answer =
    bytesMessage overRead options procedure (GrpcWeb.read otherFailure answer)


{-| Connect's reading of a JSON answer: success is status 200.
-}
connectRead : Http.Response String -> Result Error GoodText
connectRead answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                Err (failure metadata raw)

            else
                Ok { metadata = metadata, raw = raw, text = raw, field = Nothing }

        _ ->
            Err (otherFailure answer)


{-| Transcoding's: success is any 2xx, an empty body reading as `{}`, and the
response is read from the field the route's `response_body` names.
-}
transcodeRead : Maybe String -> Http.Response String -> Result Error GoodText
transcodeRead responseBody answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            Ok
                { metadata = metadata
                , raw = raw
                , text = orEmptyObject raw
                , field = responseBody
                }

        _ ->
            Err (otherFailure answer)


{-| Connect's reading of a protobuf binary answer: a 200 must come as
`application/proto` or with no content type, and is the response's
binary; every other answer is JSON, read as under the JSON codec.
-}
connectProtoRead : Http.Response Bytes -> ( Maybe Http.Metadata, Result Error GoodBytes )
connectProtoRead answer =
    ( Internal.metadataOf answer
    , case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                Err (bytesFailure answer)

            else
                case contentType metadata of
                    Just other ->
                        if other == "application/proto" then
                            Ok { metadata = metadata, raw = raw, message = raw }

                        else
                            Err (Error.BadResponse ("content-type " ++ other ++ ", not application/proto") (bytesAnswer metadata raw))

                    Nothing ->
                        Ok { metadata = metadata, raw = raw, message = raw }

        _ ->
            Err (bytesFailure answer)
    )


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


{-| The answer's content type without its parameters, lowercased, whatever
the header name's case.
-}
contentType : Http.Metadata -> Maybe String
contentType metadata =
    header "content-type" metadata
        |> Maybe.map
            (\value ->
                String.split ";" value
                    |> List.head
                    |> Maybe.withDefault ""
                    |> String.trim
                    |> String.toLower
            )



-- LIMITS


{-| Whether a successful text answer is over the read limit: its body as
the browser decoded it, written back as UTF-8. Installed by
`withReadMaxBytes`.
-}
textOverRead : Options -> String -> Maybe Reason
textOverRead options raw =
    options.readMaxBytes
        |> Maybe.andThen
            (\limit ->
                Internal.overLimit limit raw
                    |> Maybe.map (\size -> Error.ResponseTooLarge { limit = limit, size = size })
            )


{-| Whether a successful binary answer's message is over the read limit.
-}
bytesOverRead : (Bytes -> Int) -> Options -> Bytes -> Maybe Reason
bytesOverRead width options message =
    options.readMaxBytes
        |> Maybe.andThen
            (\limit ->
                let
                    size =
                        width message
                in
                if size > max 0 limit then
                    Just (Error.ResponseTooLarge { limit = limit, size = size })

                else
                    Nothing
            )


{-| An answer of bytes as an error keeps it.
-}
bytesAnswer : Http.Metadata -> Bytes -> Response
bytesAnswer metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.bytes raw
    }


orEmptyObject : String -> String
orEmptyObject raw =
    if String.isEmpty (String.trim raw) then
        "{}"

    else
        raw


{-| The response decoder reading the answer as the field `responseBody` names,
when it names one.
-}
fieldDecoder : Maybe String -> Decoder res -> Decoder res
fieldDecoder responseBody decoder =
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
