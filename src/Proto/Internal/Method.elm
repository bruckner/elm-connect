module Proto.Internal.Method exposing (Binary, Method(..))

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that other modules of the package can reach what a method holds while
users cannot. The descriptor is a parameter because its type, with
`Idempotency` and its readers, stays in `Proto.Method`.
-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Internal.Binary


type Method descriptor req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : descriptor
        , binary : Maybe (Binary req res)
        , json : Bool
        }


{-| The protobuf binary codecs, which `Proto.Method.withBinary` and
`Proto.Method.methodBinary` give.
-}
type alias Binary req res =
    { encodeRequest : req -> Bytes.Encode.Encoder
    , responseDecoder : Proto.Internal.Binary.Decoder res
    }
