module Entry exposing (Entry)

{-| One message's codecs in the shape `Bench3` runs them, whichever library
generated them: each direction of each format, and `toBinary` to turn a JSON
input into its binary once, outside the timing.
-}

import Bytes exposing (Bytes)


type alias Entry =
    { decodeJson : String -> Bool
    , decodeBinary : Bytes -> Bool
    , prepareJson : String -> Maybe (() -> String)
    , prepareBinary : Bytes -> Maybe (() -> Bytes)
    , toBinary : String -> Maybe Bytes
    , binaryEcho : Bytes -> Maybe Bytes
    , jsonEcho : String -> Maybe String
    , jsonError : String -> Maybe String
    }
