module Rpc.Internal.Connect exposing
    ( connectGet
    , connectGetBinary
    , connectMessage
    , connectPost
    , connectPostBinary
    , connectProtoMessage
    , connectTimeout
    )

{-| The Connect protocol: its POST, and its GET of a method without side
effects, as JSON or protobuf binary, and its reading of an answer under either
codec. Not exposed; `Rpc.Protocol.connect` and `connectProto` install these
functions and `withConnectGet` the GET builders (`Rpc.Internal.Protocol`), so a
program carries only the builders of the options it names: a POST-only program
no percent-encoding, a JSON program no elm/bytes. A failure is read as every
protocol's is (`Rpc.Internal.Status`), and so is a 200 whose content type is
not Connect's (`Envelope.label`).
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Json.Encode exposing (Value)
import Proto.Internal.Percent as Percent
import Proto.Method exposing (Idempotency(..))
import Proto.Route exposing (Route)
import Rpc.Body as Body exposing (Body)
import Rpc.Code as Code
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Envelope as Envelope
import Rpc.Internal.Limit as Limit
import Rpc.Internal.Protocol exposing (BytesMessage, GoodBytes, GoodText, Options, Settings, Size)
import Rpc.Internal.Status as Status
import Rpc.Request exposing (Request)



-- REQUESTS


{-| Connect's POST of a request's JSON, every call POSTed.
-}
connectPost : Options -> Settings -> Maybe Route -> (() -> Value) -> Request
connectPost _ settings _ json =
    connectRequest settings (Body.text (Json.Encode.encode 0 (json ())))


{-| Connect's GET of a call of a method without side effects, the JSON
percent-encoded in the query, unless the URL would be longer than
`maxGetUrl`; any other call is POSTed. `withConnectGet` installs it.
-}
connectGet : Options -> Settings -> Maybe Route -> (() -> Value) -> Request
connectGet options settings _ json =
    let
        text =
            Json.Encode.encode 0 (json ())
    in
    getOr options settings (Body.text text) (\() -> "encoding=json&message=" ++ Percent.percentEncode Percent.unreserved text)


{-| Connect's POST of a request's protobuf binary, as `application/proto`.
-}
connectPostBinary : (Bytes.Encode.Encoder -> Bytes) -> (Bytes -> String) -> Options -> Settings -> Bytes.Encode.Encoder -> Request
connectPostBinary encode _ _ settings encoder =
    connectRequest settings (Body.bytes (encode encoder))


{-| Connect's GET under the binary codec: the binary as unpadded URL-safe
base64 in the query.
-}
connectGetBinary : (Bytes.Encode.Encoder -> Bytes) -> (Bytes -> String) -> Options -> Settings -> Bytes.Encode.Encoder -> Request
connectGetBinary encode toBase64 options settings encoder =
    let
        binary =
            encode encoder
    in
    getOr options settings (Body.bytes binary) (\() -> "base64=1&encoding=proto&message=" ++ base64Url (toBase64 binary))


{-| A GET when the method has no side effects and the URL is within the
limit, built only then; else the POST of `body`. The query parameters are
in the order the protocol recommends, so a cache keys one request one way.
-}
getOr : Options -> Settings -> Body -> (() -> String) -> Request
getOr options settings body getQuery =
    let
        get =
            if settings.idempotency == IdempotencyNoSideEffects then
                let
                    whole =
                        Envelope.procedureUrl settings ++ "?connect=v1&" ++ getQuery ()
                in
                case options.maxGetUrl of
                    Just limit ->
                        if String.length whole <= limit then
                            Just whole

                        else
                            Nothing

                    Nothing ->
                        Just whole

            else
                Nothing
    in
    case get of
        Just url ->
            { method = "GET"
            , url = url
            , headers = settings.headers ++ connectTimeoutHeader settings.timeout
            , body = Body.none
            , timeout = settings.timeout
            , withCredentials = settings.withCredentials
            }

        Nothing ->
            connectRequest settings body


connectRequest : Settings -> Body -> Request
connectRequest settings body =
    { method = "POST"
    , url = Envelope.procedureUrl settings
    , headers = settings.headers ++ ( "Connect-Protocol-Version", "1" ) :: connectTimeoutHeader settings.timeout
    , body = body
    , timeout = settings.timeout
    , withCredentials = settings.withCredentials
    }


{-| `Connect-Timeout-Ms`, when there is a timeout.
-}
connectTimeoutHeader : Maybe Float -> List ( String, String )
connectTimeoutHeader timeout =
    case timeout of
        Just ms ->
            [ ( "Connect-Timeout-Ms", Envelope.timeoutMs ms ) ]

        Nothing ->
            []


{-| Base64 in the URL-safe alphabet without padding, as Connect's GET carries
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


{-| Connect carries a timeout in `Connect-Timeout-Ms`.
-}
connectTimeout : Bool -> Maybe ( String, Float -> String )
connectTimeout _ =
    Just ( "Connect-Timeout-Ms", Envelope.timeoutMs )



-- ANSWERS


{-| Connect's message of a JSON answer.
-}
connectMessage : (Options -> String -> Maybe Size) -> Options -> Maybe String -> Http.Response String -> Result Error GoodText
connectMessage overRead options _ answer =
    connectRead answer |> Result.andThen (Limit.withinText overRead options)


{-| Connect's message of a protobuf binary answer.
-}
connectProtoMessage : (Options -> Bytes -> Maybe Size) -> Options -> String -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error BytesMessage )
connectProtoMessage overRead options _ answer =
    Limit.bytesMessage overRead options (connectProtoRead answer)


{-| Connect's reading of a JSON answer: success is status 200, as
`application/json` or with no content type (`Envelope.label`).
-}
connectRead : Http.Response String -> Result Error GoodText
connectRead answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                Err (Status.failure metadata raw)

            else
                case Envelope.label connectType [ "application/json" ] metadata of
                    Envelope.Accepted ->
                        Ok { metadata = metadata, raw = raw, text = raw, field = Nothing }

                    Envelope.Unaccepted problem ->
                        Err (Error.badResponse Code.Internal (Envelope.envelopeText problem) (Status.answerOf metadata raw))

                    Envelope.Foreign ->
                        Err (Status.failure metadata raw)

        _ ->
            Err (Status.otherFailure answer)


{-| Connect's reading of a protobuf binary answer: a 200 as
`application/proto` or with no content type (`Envelope.label`) is the response's
binary; every other answer is JSON, read as under the JSON codec.
-}
connectProtoRead : Http.Response Bytes -> ( Maybe Http.Metadata, Result Error GoodBytes )
connectProtoRead answer =
    ( Envelope.metadataOf answer
    , case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                Err (Status.bytesFailure answer)

            else
                case Envelope.label connectType [ "application/proto" ] metadata of
                    Envelope.Accepted ->
                        Ok { metadata = metadata, raw = raw, message = raw }

                    Envelope.Unaccepted problem ->
                        Err (Error.badResponse Code.Internal (Envelope.envelopeText problem) (Envelope.bytesAnswer metadata raw))

                    Envelope.Foreign ->
                        Err (Status.bytesFailure answer)

        _ ->
            Err (Status.bytesFailure answer)
    )


{-| Whether a content type is one of Connect's: its unary codecs' and its
streaming codecs'.
-}
connectType : String -> Bool
connectType found =
    List.member found [ "application/json", "application/proto", "application/connect+json", "application/connect+proto" ]
