module Proto.Internal.Method exposing (Method(..))

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that other modules of the package can reach what a method holds while
users cannot. The descriptor is a parameter because its type, with
`Idempotency` and its readers, stays in `Proto.Method`.
-}

import Json.Decode
import Json.Encode


type Method descriptor req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : descriptor
        }
