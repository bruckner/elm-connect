module Proto.Internal.Message exposing (Message(..))

{-| The `Message` type, which `Proto.Message` names by an alias. It is defined
here so that other modules of the package can reach what a message type holds
while users cannot. The descriptor is a parameter because its type, with its
readers, stays in `Proto.Message`.
-}

import Json.Decode
import Json.Encode


type Message descriptor a
    = Message
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : descriptor
        }
