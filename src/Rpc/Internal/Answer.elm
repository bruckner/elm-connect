module Rpc.Internal.Answer exposing (toResult)

{-| Reading an answer to a call: the decoded response, or the `Rpc.Error` it
stands for, from a Connect error body, a `google.rpc.Status` body or gRPC
status headers, whatever the transport. Not exposed; it is what
`Rpc.response` stands for, kept out of `Rpc` so that the public module reads
as API.
-}

import Dict
import Http
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Internal.Any
import Proto.Method as Method
import Rpc.Code as Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Route exposing (Route(..), route)
import Rpc.Internal.Transport exposing (Transport(..))
import Rpc.Response exposing (Response)


{-| What an answer to a call over a transport means: the decoded response, or
the error.
-}
toResult : Transport -> Call req res -> Http.Response String -> Result Error res
toResult transport ((Call fields) as c) answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            case ( transport, route transport c ) of
                ( Connect _, _ ) ->
                    if metadata.statusCode == 200 then
                        decodeBody (Method.responseDecoder fields.method) metadata raw raw

                    else
                        Err (failure metadata raw)

                ( Transcode, Bound _ rule ) ->
                    decodeBody (responseDecoder rule.responseBody (Method.responseDecoder fields.method)) metadata raw (orEmptyObject raw)

                ( Transcode, Implicit ) ->
                    decodeBody (Method.responseDecoder fields.method) metadata raw (orEmptyObject raw)

        Http.BadStatus_ metadata raw ->
            Err (failure metadata raw)

        Http.BadUrl_ url ->
            Err (Error.NoAnswer (Error.BadUrl url))

        Http.Timeout_ ->
            Err (Error.NoAnswer Error.Timeout)

        Http.NetworkError_ ->
            Err (Error.NoAnswer Error.NetworkError)


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
    , body = raw
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
    Json.Decode.list (Json.Decode.maybe (Json.Decode.oneOf [ Proto.Any.jsonDecoder, connectDetail ]))
        |> Json.Decode.map (List.filterMap identity)


{-| A Connect error detail: the message's full name as `type`, its protobuf
binary as base64 `value`, and optionally its JSON as `debug`, which the `Any`
holds when present. Without it the `Any` holds the binary alone.
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
                        Proto.Internal.Any.InJson json

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
