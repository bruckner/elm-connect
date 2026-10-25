module Proto.Internal.Message exposing (Binary, Message(..))

{-| The `Message` type, defined here so that `Proto.Any` can reach the binary
codecs' base64 halves, which `Proto.Message` builds only under `withBinary`
so that a program without binary codecs carries none of that code. The
descriptor is a parameter because its type, with its readers, stays in
`Proto.Message`.
-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Internal.Binary


type Message descriptor a
    = Message
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : descriptor
        , binary : Maybe (Binary a)
        }


{-| The binary codecs, and a value's binary as base64 and back, which an
`Any` holds.
-}
type alias Binary a =
    { encode : a -> Bytes.Encode.Encoder
    , decoder : Proto.Internal.Binary.Decoder a
    , toBase64 : a -> String
    , fromBase64 : String -> Maybe a
    }
