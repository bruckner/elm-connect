module Rpc.Internal.GrpcWeb exposing (read, request, timeout, withTrailers)

{-| gRPC-Web's unary framing: a request as one framed message, and an answer
read from its framed messages and its trailers frame, or from its headers
when the server sent only a status. A frame is a flag byte (`0x80` for
trailers, `0x01` for a compressed message) and a four-byte big-endian length
before its bytes. Only `Rpc.Internal.Binary`, the bytes path a method with
binary codecs carries, reaches it.
-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D exposing (Step(..))
import Bytes.Encode as E
import Dict exposing (Dict)
import Http
import Proto.Any exposing (Any)
import Proto.Binary
import Proto.Bytes
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Http as Internal
import Rpc.Request exposing (Request)
import Rpc.Response exposing (Response)


{-| A call: a POST of its request in one framed message, as
`application/grpc-web+proto`, with `X-Grpc-Web` and its timeout as
`grpc-timeout` after the headers given.
-}
request : (req -> E.Encoder) -> { url : String, headers : List ( String, String ), timeout : Maybe Float, withCredentials : Bool } -> req -> Request
request encode settings value =
    { method = "POST"
    , url = settings.url
    , headers =
        settings.headers
            ++ ( "X-Grpc-Web", "1" )
            :: (case settings.timeout of
                    Just ms ->
                        [ ( "grpc-timeout", timeout ms ) ]

                    Nothing ->
                        []
               )
    , body = Rpc.Body.bytesAs "application/grpc-web+proto" (framed encode value)
    , timeout = settings.timeout
    , withCredentials = settings.withCredentials
    }


{-| A timeout as gRPC's `grpc-timeout` carries it: at most eight digits and a
unit, milliseconds rounded up, or a coarser unit when they need more digits.
-}
timeout : Float -> String
timeout ms =
    let
        whole =
            ceiling ms
    in
    if whole <= 99999999 then
        String.fromInt whole ++ "m"

    else if whole // 1000 < 99999999 then
        String.fromInt (ceiling (ms / 1000)) ++ "S"

    else
        String.fromInt (min 99999999 (ceiling (ms / 3600000))) ++ "H"


{-| The request's binary in one uncompressed message frame.
-}
framed : (req -> E.Encoder) -> req -> Bytes
framed encode value =
    let
        message =
            Proto.Binary.encode encode value
    in
    E.encode
        (E.sequence
            [ E.unsignedInt8 0
            , E.unsignedInt32 BE (Bytes.width message)
            , E.bytes message
            ]
        )


{-| What a gRPC-Web answer means. A 200 holds the call's status: in a
trailers frame after the response's message frame, or in its headers when
the body is empty ("trailers-only"); a body's trailers win over headers. Any other HTTP status is read
by `readText`, as any transport's error is, which finds `grpc-status` among
its headers or falls back to the HTTP status.
-}
read : Proto.Binary.Decoder res -> String -> Maybe Int -> (Http.Response String -> Result Error res) -> Http.Response Bytes -> Result Error res
read decoder output limit readText answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                readText (Http.GoodStatus_ metadata (Internal.bytesText raw))

            else if Bytes.width raw == 0 then
                -- Trailers-only: the status is in the headers.
                case headerIn (lowered metadata.headers) "grpc-status" of
                    Just _ ->
                        settle decoder output limit metadata raw (lowered metadata.headers) []

                    Nothing ->
                        Err (Error.BadResponse "a gRPC-Web answer without grpc-status in its trailers or headers" (answerOf metadata raw))

            else
                -- A body holds the status in its trailers frame, whatever
                -- the headers say.
                case D.decode (frames (Bytes.width raw)) raw of
                    Just ( messages, Just trailers ) ->
                        settle decoder output limit metadata raw trailers messages

                    Just ( _, Nothing ) ->
                        Err (Error.BadResponse "a gRPC-Web answer without grpc-status in its trailers or headers" (answerOf metadata raw))

                    Nothing ->
                        Err (Error.BadResponse "a gRPC-Web body that is not a sequence of uncompressed frames" (answerOf metadata raw))

        Http.BadStatus_ metadata raw ->
            readText (Http.BadStatus_ metadata (Internal.bytesText raw))

        Http.BadUrl_ url ->
            readText (Http.BadUrl_ url)

        Http.Timeout_ ->
            readText Http.Timeout_

        Http.NetworkError_ ->
            readText Http.NetworkError_


{-| An answer's metadata with the trailers frame of its body added as
`trailer-<name>` headers, as a Connect unary answer carries its trailers, so
that `Rpc.Trace` and `Rpc.splitTrailers` find them.
-}
withTrailers : Http.Response Bytes -> Maybe Http.Metadata
withTrailers answer =
    case answer of
        Http.GoodStatus_ meta raw ->
            case D.decode (frames (Bytes.width raw)) raw of
                Just ( _, Just trailers ) ->
                    Just { meta | headers = Dict.foldl (\name value -> Dict.insert ("trailer-" ++ name) value) meta.headers trailers }

                _ ->
                    Just meta

        Http.BadStatus_ meta _ ->
            Just meta

        _ ->
            Nothing


{-| The result a status (`trailers`, names lowercased) and the message frames
before it stand for: status 0 with exactly one message is the response;
any other status is the error it states, with its details.
-}
settle : Proto.Binary.Decoder res -> String -> Maybe Int -> Http.Metadata -> Bytes -> Dict String String -> List Bytes -> Result Error res
settle decoder output limit metadata raw trailers messages =
    let
        answer =
            answerOf metadata raw
    in
    case headerIn trailers "grpc-status" |> Maybe.andThen (String.trim >> String.toInt) of
        Just 0 ->
            case messages of
                [ message ] ->
                    case ( limit, Bytes.width message ) of
                        ( Just most, size ) ->
                            if size > max 0 most then
                                Err (Error.NoAnswer (Error.ResponseTooLarge { limit = most, size = size }))

                            else
                                decodeMessage decoder output answer message

                        ( Nothing, _ ) ->
                            decodeMessage decoder output answer message

                [] ->
                    Err (Error.BadResponse "a gRPC-Web answer with status 0 and no message" answer)

                _ ->
                    Err (Error.BadResponse "a unary gRPC-Web answer with more than one message" answer)

        Just number ->
            Err
                (Error.RpcStatus
                    { code = Code.fromInt number |> Maybe.withDefault Code.Unknown
                    , message =
                        headerIn trailers "grpc-message"
                            |> Maybe.map (\text -> Internal.percentDecode text |> Maybe.withDefault text)
                            |> Maybe.withDefault ""
                    , details =
                        headerIn trailers "grpc-status-details-bin"
                            |> Maybe.andThen (String.trim >> Proto.Bytes.fromBase64)
                            |> Maybe.andThen (Proto.Binary.decode statusDetails)
                            |> Maybe.withDefault []
                    , source =
                        if Bytes.width raw == 0 then
                            Error.GrpcHeaders

                        else
                            Error.GrpcTrailers
                    }
                    answer
                )

        Nothing ->
            Err (Error.BadResponse "a gRPC-Web answer whose grpc-status is not a number" answer)


decodeMessage : Proto.Binary.Decoder res -> String -> Response -> Bytes -> Result Error res
decodeMessage decoder output answer message =
    Proto.Binary.decode decoder message
        |> Result.fromMaybe (Error.BadResponse ("the message is not a " ++ output ++ " in protobuf binary") answer)


{-| The `details` of a `google.rpc.Status` in protobuf binary: field 3, each
an `Any` holding the detail's binary.
-}
statusDetails : Proto.Binary.Decoder (List Any)
statusDetails =
    Proto.Binary.merge
        (\number wire details ->
            if number == 3 then
                Proto.Binary.repeated Proto.Binary.any identity details wire details

            else
                Proto.Binary.skip wire details
        )
        List.reverse
        []


{-| The frames of a body `width` bytes long: its uncompressed messages in
order, and its trailers when a trailers frame came; `Nothing` for a
compressed message or a frame running past the end.
-}
frames : Int -> D.Decoder ( List Bytes, Maybe (Dict String String) )
frames width =
    D.loop ( width, [], Nothing )
        (\( left, messages, trailers ) ->
            if left == 0 then
                D.succeed (Done ( List.reverse messages, trailers ))

            else if left < 5 then
                D.fail

            else
                D.map2 Tuple.pair D.unsignedInt8 (D.unsignedInt32 BE)
                    |> D.andThen
                        (\( flag, length ) ->
                            if length > left - 5 then
                                D.fail

                            else if Bitwise.and flag 0x80 /= 0 then
                                D.string length
                                    |> D.map (\text -> Loop ( left - 5 - length, messages, Just (trailerLines text) ))

                            else if Bitwise.and flag 0x01 /= 0 then
                                D.fail

                            else
                                D.bytes length
                                    |> D.map (\message -> Loop ( left - 5 - length, message :: messages, trailers ))
                        )
        )


{-| A trailers frame's text: `name: value` lines, separated by CRLF, names
lowercased; a name given twice keeps its values joined with `", "`, as
elm/http joins a header's.
-}
trailerLines : String -> Dict String String
trailerLines text =
    text
        |> String.split "\n"
        |> List.filterMap
            (\line ->
                case String.indexes ":" line of
                    at :: _ ->
                        Just ( String.toLower (String.trim (String.left at line)), String.trim (String.dropLeft (at + 1) line) )

                    [] ->
                        Nothing
            )
        |> List.foldl
            (\( name, value ) found ->
                Dict.update name
                    (\before ->
                        case before of
                            Just earlier ->
                                Just (earlier ++ ", " ++ value)

                            Nothing ->
                                Just value
                    )
                    found
            )
            Dict.empty


lowered : Dict String String -> Dict String String
lowered headers =
    Dict.foldl (\name value -> Dict.insert (String.toLower name) value) Dict.empty headers


headerIn : Dict String String -> String -> Maybe String
headerIn headers name =
    Dict.get name headers


answerOf : Http.Metadata -> Bytes -> Response
answerOf metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.bytes raw
    }
