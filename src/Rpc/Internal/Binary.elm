module Rpc.Internal.Binary exposing (binary)

{-| The bytes path of a method with binary codecs: its request written as
protobuf binary and its binary answer read. `Proto.Method.withBinary` builds
it, so only a program whose methods have binary codecs reaches this module.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Http
import Proto.Binary
import Proto.Bytes
import Proto.Internal.Method exposing (Binary, ConnectMessage)
import Rpc.Body
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Http as Internal
import Rpc.Response exposing (Response)


{-| The bytes path of a method from its binary codecs and the full name of
its response type.
-}
binary : (req -> Bytes.Encode.Encoder) -> (Int -> Bytes.Decode.Decoder res) -> String -> Binary req res
binary encode decoder output =
    { encodeRequest = encode
    , responseDecoder = decoder
    , message = message encode
    , tooLarge =
        \limit value ->
            let
                size =
                    Bytes.width (Proto.Binary.encode encode value)
            in
            if size > max 0 limit then
                Just (Error.RequestTooLarge { limit = limit, size = size })

            else
                Nothing
    , read = read decoder output
    }


message : (req -> Bytes.Encode.Encoder) -> req -> ConnectMessage
message encode value =
    let
        bytes =
            Proto.Binary.encode encode value
    in
    { body = Rpc.Body.bytes bytes
    , encoding = "base64=1&encoding=proto"
    , query = \_ -> base64Url (Proto.Bytes.toBase64 bytes)
    }


{-| Base64 in the URL-safe alphabet without padding, as Connect's GET takes
binary.
-}
base64Url : String -> String
base64Url =
    String.foldr
        (\char done ->
            case char of
                '+' ->
                    String.cons '-' done

                '/' ->
                    String.cons '_' done

                '=' ->
                    done

                _ ->
                    String.cons char done
        )
        ""


{-| A successful answer is the response's protobuf binary, which must come as
`application/proto` or with no content type; every other answer is text,
read by `readText`.
-}
read : (Int -> Bytes.Decode.Decoder res) -> String -> Maybe Int -> (Http.Response String -> Result Error res) -> Http.Response Bytes -> Result Error res
read decoder output limit readText answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                readText (Http.GoodStatus_ metadata (Internal.bytesText raw))

            else
                case header "content-type" metadata |> Maybe.map mediaType of
                    Just other ->
                        if other == "application/proto" then
                            decodeBinary decoder output limit metadata raw

                        else
                            Err (Error.BadResponse ("content-type " ++ other ++ ", not application/proto") (binaryAnswer metadata raw))

                    Nothing ->
                        decodeBinary decoder output limit metadata raw

        Http.BadStatus_ metadata raw ->
            readText (Http.BadStatus_ metadata (Internal.bytesText raw))

        Http.BadUrl_ url ->
            readText (Http.BadUrl_ url)

        Http.Timeout_ ->
            readText Http.Timeout_

        Http.NetworkError_ ->
            readText Http.NetworkError_


{-| A response header by name, whatever its case.
-}
header : String -> Http.Metadata -> Maybe String
header key metadata =
    metadata.headers
        |> Dict.toList
        |> List.filter (\( k, _ ) -> String.toLower k == key)
        |> List.head
        |> Maybe.map Tuple.second


{-| A content type without its parameters, lowercased.
-}
mediaType : String -> String
mediaType value =
    String.split ";" value
        |> List.head
        |> Maybe.withDefault ""
        |> String.trim
        |> String.toLower


decodeBinary : (Int -> Bytes.Decode.Decoder res) -> String -> Maybe Int -> Http.Metadata -> Bytes -> Result Error res
decodeBinary decoder output limit metadata raw =
    case limit of
        Just most ->
            if Bytes.width raw > max 0 most then
                Err (Error.NoAnswer (Error.ResponseTooLarge { limit = most, size = Bytes.width raw }))

            else
                readBinary decoder output metadata raw

        Nothing ->
            readBinary decoder output metadata raw


readBinary : (Int -> Bytes.Decode.Decoder res) -> String -> Http.Metadata -> Bytes -> Result Error res
readBinary decoder output metadata raw =
    Proto.Binary.decode decoder raw
        |> Result.fromMaybe (Error.BadResponse ("the body is not a " ++ output ++ " in protobuf binary") (binaryAnswer metadata raw))


binaryAnswer : Http.Metadata -> Bytes -> Response
binaryAnswer metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.bytes raw
    }
