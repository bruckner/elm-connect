module Proto.Internal.Message exposing (Binary, Message(..))

{-| The `Message` type, which `Proto.Message` names by an alias. It is defined
here so that other modules of the package can reach what a message type holds
while users cannot. The descriptor is a parameter because its type, with its
readers, stays in `Proto.Message`.
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


{-| The protobuf binary codecs, which `Proto.Message.withBinary` and
`Proto.Message.messageBinary` give.
-}
type alias Binary a =
    { encode : a -> Bytes.Encode.Encoder
    , decoder : Proto.Internal.Binary.Decoder a
    }
