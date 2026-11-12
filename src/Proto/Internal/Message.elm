module Proto.Internal.Message exposing (Codecs, Message(..))

{-| The `Message` type, which `Proto.Message` names by an alias. It is defined
here so that other modules of the package can reach what a message type holds
while users cannot.

A message type is its full name and both of its codecs. Its proto3 JSON codecs
take the registry an `Any` it holds converts through; a message that holds
none ignores it.

-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Error
import Proto.Internal.Binary
import Proto.Internal.Registry exposing (Registry)


type Message a
    = Message String (Codecs a)


type alias Codecs a =
    { encodeJson : Registry -> a -> Result Proto.Error.Error Json.Encode.Value
    , decodeJson : Registry -> Json.Decode.Decoder a
    , encodeBinary : a -> Bytes.Encode.Encoder
    , decodeBinary : Proto.Internal.Binary.Decoder a
    }
