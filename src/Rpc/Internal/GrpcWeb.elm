module Rpc.Internal.GrpcWeb exposing (grpcWeb, grpcWebMessage, grpcWebTimeout)

{-| gRPC-Web, unary calls: the request, its timeout header and the reading of
an answer, over the bytes a method's binary codecs write and read. A request
is one framed message, and an answer is read from its framed messages and its
trailers frame, or from its headers when the server sent only a status. A
frame is a flag byte (`0x80` for trailers, `0x01` for a compressed message)
and a four-byte big-endian length before its bytes.

Not exposed. `Rpc.Protocol.grpcWeb` installs `grpcWeb`, `grpcWebTimeout` and
`grpcWebMessage`, and nothing else reaches this module, so a program that
never names it carries none of it. A failure that is not a gRPC-Web answer,
and a 200 whose content type is not gRPC-Web's, is read as every protocol's
failure is (`Rpc.Internal.Status`).

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
import Proto.Error
import Proto.Internal.Percent as Percent
import Rpc.Body
import Rpc.Code as Code
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Connect as Connect
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (BytesMessage, GoodBytes, Options, Settings)
import Rpc.Internal.Status as Status
import Rpc.Request exposing (Request)
import Rpc.Response exposing (Response)



-- INSTALLED


{-| gRPC-Web's POST to the URL Connect uses: the request's binary in one
framed message, sent as `application/grpc-web+proto` with `X-Grpc-Web`, and
the timeout as `grpc-timeout`.
-}
grpcWeb : (Bytes -> String) -> Options -> Settings -> E.Encoder -> Request
grpcWeb _ _ settings encoder =
    { method = "POST"
    , url = Connect.connectUrl settings
    , headers =
        settings.headers
            ++ ( "X-Grpc-Web", "1" )
            :: (case settings.timeout of
                    Just ms ->
                        [ ( "grpc-timeout", timeout ms ) ]

                    Nothing ->
                        []
               )
    , body = Rpc.Body.bytesAs "application/grpc-web+proto" (frame encoder)
    , timeout = settings.timeout
    , withCredentials = settings.withCredentials
    }


{-| gRPC-Web carries a timeout in `grpc-timeout`.
-}
grpcWebTimeout : Maybe ( String, Float -> String )
grpcWebTimeout =
    Just ( "grpc-timeout", timeout )


{-| gRPC-Web's message: its framing and trailers (`read`).
-}
grpcWebMessage : (Options -> Bytes -> Maybe Error) -> Options -> String -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error BytesMessage )
grpcWebMessage overRead options _ answer =
    Internal.bytesMessage overRead options (read Status.otherFailure answer)



-- FRAMING


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
with its details. A 200 must come as `application/grpc-web` or
`application/grpc-web+proto`, or with no content type; another gRPC-Web type
(`+json`, `-text`) is a `BadEnvelope`, and a type that is not gRPC-Web's at
all makes the answer one `failure` reads (`Connect.label`). Any other answer
is the error `failure` reads from it as text, as every protocol's error is.
-}
read : (Http.Response String -> Error) -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error GoodBytes )
read failure answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                ( Just metadata, Err (failure (Http.GoodStatus_ metadata (Internal.bytesText raw))) )

            else
                case Connect.label (String.startsWith "application/grpc-web") [ "application/grpc-web", "application/grpc-web+proto" ] metadata of
                    Connect.Accepted ->
                        if Bytes.width raw == 0 then
                            ( Just metadata, settle Error.GrpcHeaders metadata raw (lowered metadata.headers) [] )

                        else
                            fromFrames metadata raw

                    Connect.Unaccepted problem ->
                        ( Just metadata, Err (Error.BadEnvelope problem (answerOf metadata raw)) )

                    Connect.Foreign ->
                        ( Just metadata, Err (failure (Http.GoodStatus_ metadata (Internal.bytesText raw))) )

        Http.BadStatus_ metadata raw ->
            ( Just metadata, Err (failure (Http.BadStatus_ metadata (Internal.bytesText raw))) )

        Http.BadUrl_ url ->
            ( Nothing, Err (failure (Http.BadUrl_ url)) )

        Http.Timeout_ ->
            ( Nothing, Err (failure Http.Timeout_) )

        Http.NetworkError_ ->
            ( Nothing, Err (failure Http.NetworkError_) )


{-| A 200 body's frames as the answer: its status from the trailers frame,
and its trailers added to the metadata.
-}
fromFrames : Http.Metadata -> Bytes -> ( Maybe Http.Metadata, Result Error GoodBytes )
fromFrames metadata raw =
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
            ( Just metadata, Err (Error.BadEnvelope "a gRPC-Web answer without trailers" (answerOf metadata raw)) )

        Nothing ->
            ( Just metadata, Err (Error.BadEnvelope "a gRPC-Web body that is not a sequence of uncompressed frames" (answerOf metadata raw)) )


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

        ( Just (Just 0), [] ) ->
            Err (Error.BadMessageCount 0 answer)

        ( Just (Just 0), _ ) ->
            Err (Error.BadMessageCount (List.length messages) answer)

        ( Just (Just number), _ ) ->
            case Dict.get "grpc-status-details-bin" status |> Maybe.map (String.trim >> Proto.Bytes.fromBase64) of
                Just Nothing ->
                    -- The trailer is part of the answer's envelope, as a frame
                    -- is: text that is not base64 is a malformed answer, not
                    -- bad protobuf, and is reported as grpc-go and connect-go
                    -- report it, with no bytes to blame.
                    Err (Error.BadEnvelope "a grpc-status-details-bin trailer that is not base64" answer)

                encoded ->
                    let
                        fromTrailers =
                            ( number
                            , Dict.get "grpc-message" status
                                |> Maybe.map (\text -> Percent.percentDecode text |> Maybe.withDefault text)
                                |> Maybe.withDefault ""
                            )

                        -- The Status in the trailer is the richer form of the
                        -- same status: its message is not percent-encoded and
                        -- it holds the details. connect-go and connect-es take
                        -- the code and message from it when it decodes, and so
                        -- does this; one without a code (0, left out) is
                        -- incomplete, and the trailers stand for both.
                        ( ( codeNumber, message ), details ) =
                            case encoded of
                                Just (Just binary) ->
                                    case Proto.Binary.decode statusProto binary of
                                        Ok proto ->
                                            ( if proto.code /= 0 then
                                                ( proto.code, proto.message )

                                              else
                                                fromTrailers
                                            , List.map Ok proto.details
                                            )

                                        Err problem ->
                                            ( fromTrailers, [ Err (Proto.Error.BadBinary problem) ] )

                                _ ->
                                    ( fromTrailers, [] )
                    in
                    Err
                        (Error.RpcStatus
                            { code = Code.fromInt codeNumber |> Maybe.withDefault Code.Unknown
                            , message = message
                            , details = details
                            , source = source
                            }
                            answer
                        )

        _ ->
            Err (Error.BadEnvelope "a gRPC-Web answer without a numeric grpc-status" answer)


{-| A `google.rpc.Status`: its code (field 1), message (2) and details (3,
repeated `Any`), read from a `grpc-status-details-bin` trailer.
-}
type alias StatusProto =
    { code : Int
    , message : String
    , details : List Any
    }


statusProto : Proto.Binary.Decoder StatusProto
statusProto =
    Proto.Binary.merge "google.rpc.Status"
        (\number wire proto ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.int32 (\code -> { proto | code = code }) wire proto

                2 ->
                    Proto.Binary.field Proto.Binary.string (\message -> { proto | message = message }) wire proto

                3 ->
                    Proto.Binary.repeated Proto.Binary.any (\details -> { proto | details = details }) proto.details wire proto

                _ ->
                    Proto.Binary.skip wire proto
        )
        (\proto -> { proto | details = List.reverse proto.details })
        { code = 0, message = "", details = [] }


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
