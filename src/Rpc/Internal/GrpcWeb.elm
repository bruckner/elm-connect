module Rpc.Internal.GrpcWeb exposing (frame, read, timeout)

{-| gRPC-Web's unary framing, over the bytes a method's binary codecs write
and read: a request as one framed message, and an answer read from its
framed messages and its trailers frame, or from its headers when the server
sent only a status. A frame is a flag byte (`0x80` for trailers, `0x01` for
a compressed message) and a four-byte big-endian length before its bytes.

Not exposed. Only the `Rpc.Protocol.grpcWeb` value reaches this module,
through the functions it installs, so a program that never names it carries
none of it.

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
import Proto.Internal.Percent as Percent
import Rpc.Body
import Rpc.Code as Code
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (GoodBytes)
import Rpc.Response exposing (Response)


{-| A request's binary in one uncompressed message frame.
-}
frame : E.Encoder -> Bytes
frame encoder =
    let
        message =
            E.encode encoder
    in
    E.encode
        (E.sequence
            [ E.unsignedInt8 0
            , E.unsignedInt32 BE (Bytes.width message)
            , E.bytes message
            ]
        )


{-| A timeout as gRPC's `grpc-timeout` carries it: at most eight digits and a
unit, milliseconds rounded up, or a coarser unit when they need more digits.
-}
timeout : Float -> String
timeout ms =
    if ceiling ms <= 99999999 then
        String.fromInt (ceiling ms) ++ "m"

    else if ceiling (ms / 1000) <= 99999999 then
        String.fromInt (ceiling (ms / 1000)) ++ "S"

    else
        String.fromInt (min 99999999 (ceiling (ms / 3600000))) ++ "H"


{-| What a gRPC-Web answer means, with its metadata, the trailers of its body
added as the `trailer-` headers a Connect answer would carry them in. A 200
states the call's status in a trailers frame after its message frame, or in
its headers when the body is empty ("trailers-only"); a body's trailers win
over its headers. Status 0 with one message is the response's bytes, which
the method's binary codec decodes; any other status is the error it states,
with its details. Any other answer is the error `failure` reads from it as
text, as every protocol's error is.
-}
read : (Http.Response String -> Error) -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error GoodBytes )
read failure answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                ( Just metadata, Err (failure (Http.GoodStatus_ metadata (Internal.bytesText raw))) )

            else if Bytes.width raw == 0 then
                ( Just metadata, settle Error.GrpcHeaders metadata raw (lowered metadata.headers) [] )

            else
                case D.decode (frames (Bytes.width raw)) raw of
                    Just ( messages, Just trailers ) ->
                        let
                            merged =
                                { metadata | headers = Dict.foldl (\name value -> Dict.insert ("trailer-" ++ name) value) metadata.headers trailers }
                        in
                        ( Just merged
                        , settle Error.GrpcTrailers merged raw trailers messages
                        )

                    Just ( _, Nothing ) ->
                        ( Just metadata, Err (Error.BadResponse "a gRPC-Web answer without trailers" (answerOf metadata raw)) )

                    Nothing ->
                        ( Just metadata, Err (Error.BadResponse "a gRPC-Web body that is not a sequence of uncompressed frames" (answerOf metadata raw)) )

        Http.BadStatus_ metadata raw ->
            ( Just metadata, Err (failure (Http.BadStatus_ metadata (Internal.bytesText raw))) )

        Http.BadUrl_ url ->
            ( Nothing, Err (failure (Http.BadUrl_ url)) )

        Http.Timeout_ ->
            ( Nothing, Err (failure Http.Timeout_) )

        Http.NetworkError_ ->
            ( Nothing, Err (failure Http.NetworkError_) )


{-| The result a status (`status`, names lowercased) and the message frames
before it stand for.
-}
settle : Error.Source -> Http.Metadata -> Bytes -> Dict String String -> List Bytes -> Result Error GoodBytes
settle source metadata raw status messages =
    let
        answer =
            answerOf metadata raw
    in
    case ( Dict.get "grpc-status" status |> Maybe.map (String.trim >> String.toInt), messages ) of
        ( Just (Just 0), [ message ] ) ->
            Ok { metadata = metadata, raw = raw, message = message }

        ( Just (Just 0), _ ) ->
            Err (Error.BadResponse "a unary gRPC-Web answer with status 0 and not one message" answer)

        ( Just (Just number), _ ) ->
            Err
                (Error.RpcStatus
                    { code = Code.fromInt number |> Maybe.withDefault Code.Unknown
                    , message =
                        Dict.get "grpc-message" status
                            |> Maybe.map (\text -> Percent.percentDecode text |> Maybe.withDefault text)
                            |> Maybe.withDefault ""
                    , details =
                        Dict.get "grpc-status-details-bin" status
                            |> Maybe.andThen (String.trim >> Proto.Bytes.fromBase64)
                            |> Maybe.andThen (Proto.Binary.decode statusDetails)
                            |> Maybe.withDefault []
                    , source = source
                    }
                    answer
                )

        _ ->
            Err (Error.BadResponse "a gRPC-Web answer without a numeric grpc-status" answer)


{-| The `details` of a `google.rpc.Status` (field 3, repeated `Any`), its code
and message skipped: the status's own are in `grpc-status` and
`grpc-message`.
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
                            if length > left - 5 || Bitwise.and flag 0x01 /= 0 then
                                D.fail

                            else if Bitwise.and flag 0x80 /= 0 then
                                D.map (\text -> Loop ( left - 5 - length, messages, Just (trailerLines text) )) (D.string length)

                            else
                                D.map (\message -> Loop ( left - 5 - length, message :: messages, trailers )) (D.bytes length)
                        )
        )


{-| A trailers frame's text: `name: value` lines separated by CRLF, names
lowercased; a name given twice keeps its values joined with `", "`, as
elm/http joins a header's.
-}
trailerLines : String -> Dict String String
trailerLines text =
    String.lines text
        |> List.foldl
            (\line found ->
                case String.indexes ":" line of
                    at :: _ ->
                        Dict.update (String.toLower (String.trim (String.left at line)))
                            (\before ->
                                let
                                    value =
                                        String.trim (String.dropLeft (at + 1) line)
                                in
                                Just (Maybe.withDefault value (Maybe.map (\earlier -> earlier ++ ", " ++ value) before))
                            )
                            found

                    [] ->
                        found
            )
            Dict.empty


lowered : Dict String String -> Dict String String
lowered headers =
    Dict.foldl (\name value -> Dict.insert (String.toLower name) value) Dict.empty headers


answerOf : Http.Metadata -> Bytes -> Response
answerOf metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.bytes raw
    }
