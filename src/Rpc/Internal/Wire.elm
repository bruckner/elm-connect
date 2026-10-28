module Rpc.Internal.Wire exposing
    ( base64
    , bytesTooLarge
    , bytesUnlimited
    , connectGet
    , connectGetBinary
    , connectPost
    , connectPostBinary
    , connectTimeout
    , connectTimeoutHeader
    , jsonTooLarge
    , textUnlimited
    , transcode
    , transcodeTimeout
    , usableTimeout
    , width
    )

{-| The requests the protocols send: Connect's POST, and its GET of a method
without side effects, as JSON or protobuf binary; transcoding's request over
a route. Not exposed; each is a top-level function a protocol constructor or
modifier puts in a protocol (`Rpc.Internal.Protocol`), so a program carries
only the builders of the protocols and options it names: a POST-only program
no percent-encoding, a Connect program no route code, a JSON program no
elm/bytes.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Encode exposing (Value)
import Proto.Bytes
import Proto.Internal.Percent as Percent
import Proto.Method exposing (Idempotency(..))
import Proto.Route exposing (Route)
import Rpc.Body as Body exposing (Body)
import Rpc.Error as Error exposing (Reason)
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (Options, Settings)
import Rpc.Request exposing (Request)



-- CONNECT


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
connectPostBinary : (Bytes -> String) -> Options -> Settings -> Bytes.Encode.Encoder -> Request
connectPostBinary _ _ settings encoder =
    connectRequest settings (Body.bytes (Bytes.Encode.encode encoder))


{-| Connect's GET under the proto codec: the binary as unpadded URL-safe
base64 in the query.
-}
connectGetBinary : (Bytes -> String) -> Options -> Settings -> Bytes.Encode.Encoder -> Request
connectGetBinary toBase64 options settings encoder =
    let
        binary =
            Bytes.Encode.encode encoder
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
                        connectUrl settings ++ "?connect=v1&" ++ getQuery ()
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
    , url = connectUrl settings
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
            [ ( "Connect-Timeout-Ms", timeoutMs ms ) ]

        Nothing ->
            []


{-| The URL Connect sends a call to: the base URL and the call's procedure
path, `/service/method`.
-}
connectUrl : Settings -> String
connectUrl settings =
    trimSlash settings.baseUrl ++ settings.procedure


{-| Bytes as standard base64, the binary protocols' writer for a GET's
query and a trace.
-}
base64 : Bytes -> String
base64 =
    Proto.Bytes.toBase64


{-| The size of bytes, the binary protocols' measure for their limits.
-}
width : Bytes -> Int
width =
    Bytes.width


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



-- TRANSCODING


{-| Transcoding's request over the call's route: the route's method, its
path and query, its body; or, for a method without routes, the request
Connect would POST (the implicit route).
-}
transcode : Options -> Settings -> Maybe Route -> (() -> Value) -> Request
transcode options settings route json =
    case route of
        Just r ->
            { method = r.method
            , url = trimSlash settings.baseUrl ++ "/" ++ r.path ++ query r.query
            , headers = settings.headers
            , body =
                case r.body of
                    Just body ->
                        Body.text (Json.Encode.encode 0 body)

                    Nothing ->
                        Body.none
            , timeout = settings.timeout
            , withCredentials = settings.withCredentials
            }

        Nothing ->
            connectPost options settings route json


query : List ( String, String ) -> String
query pairs =
    case pairs of
        [] ->
            ""

        _ ->
            "?"
                ++ String.join "&"
                    (List.map
                        (\( name, value ) ->
                            Percent.percentEncode Percent.unreserved name ++ "=" ++ Percent.percentEncode Percent.unreserved value
                        )
                        pairs
                    )



-- LIMITS


{-| Whether a request's JSON, as UTF-8, is over the write limit. Installed by
`withWriteMaxBytes`; the JSON is encoded again only then.
-}
jsonTooLarge : Options -> (() -> Value) -> Maybe Reason
jsonTooLarge options json =
    options.writeMaxBytes
        |> Maybe.andThen
            (\limit ->
                Internal.overLimit limit (Json.Encode.encode 0 (json ()))
                    |> Maybe.map (\size -> Error.RequestTooLarge { limit = limit, size = size })
            )


{-| Whether a request's protobuf binary is over the write limit.
-}
bytesTooLarge : (Bytes -> Int) -> Options -> (() -> Bytes.Encode.Encoder) -> Maybe Reason
bytesTooLarge width_ options binary =
    options.writeMaxBytes
        |> Maybe.andThen
            (\limit ->
                let
                    size =
                        width_ (Bytes.Encode.encode (binary ()))
                in
                if size > max 0 limit then
                    Just (Error.RequestTooLarge { limit = limit, size = size })

                else
                    Nothing
            )


{-| No limit: what a protocol's `tooLarge` and `overRead` are until a
modifier installs a limit.
-}
textUnlimited : Options -> a -> Maybe Reason
textUnlimited _ _ =
    Nothing


{-| No limit, for a binary protocol. Apart from `textUnlimited` only so that
each protocol's field has its own type.
-}
bytesUnlimited : a -> Options -> b -> Maybe Reason
bytesUnlimited _ _ _ =
    Nothing



-- TIMEOUTS


{-| Connect carries a timeout in `Connect-Timeout-Ms`.
-}
connectTimeout : Maybe Route -> Maybe ( String, Float -> String )
connectTimeout _ =
    Just ( "Connect-Timeout-Ms", timeoutMs )


{-| Transcoding carries none over a route, and Connect's over the implicit
route.
-}
transcodeTimeout : Maybe Route -> Maybe ( String, Float -> String )
transcodeTimeout route =
    case route of
        Just _ ->
            Nothing

        Nothing ->
            Just ( "Connect-Timeout-Ms", timeoutMs )


{-| A positive whole number of milliseconds, at most ten digits, as the
protocol requires.
-}
timeoutMs : Float -> String
timeoutMs ms =
    String.fromInt (clamp 1 9999999999 (ceiling ms))


{-| A timeout only when it is a positive number of milliseconds. elm/http hands
the value to XHR, whose unsigned conversion turns a negative one into weeks and
NaN or `0` into none, while the header would claim 1 ms or the maximum; read as
no timeout instead, the header and the client agree.
-}
usableTimeout : Maybe Float -> Maybe Float
usableTimeout timeout =
    case timeout of
        Just ms ->
            if ms > 0 && not (isInfinite ms) then
                Just ms

            else
                Nothing

        Nothing ->
            Nothing


trimSlash : String -> String
trimSlash url =
    if String.endsWith "/" url then
        String.dropRight 1 url

    else
        url
