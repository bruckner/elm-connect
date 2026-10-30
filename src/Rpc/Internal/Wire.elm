module Rpc.Internal.Wire exposing
    ( base64
    , bytesTooLarge
    , bytesUnlimited
    , jsonTooLarge
    , textUnlimited
    , timeoutMs
    , trimSlash
    , usableTimeout
    , width
    )

{-| What more than one protocol's requests share. Not exposed.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Encode exposing (Value)
import Proto.Bytes
import Rpc.Error as Error exposing (Reason)
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (Options)



-- BYTES


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
